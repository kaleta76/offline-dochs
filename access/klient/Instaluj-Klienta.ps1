<#
.SYNOPSIS
    Zostavovač klienta na razenie (DochadzkaKlient.accdb). Spúšťa ho správca raz na jednom počítači s Microsoft Access.

.DESCRIPTION
    - Overí Microsoft Access a integritu balíka (manifest.json, SHA-256 modulov), kódovú stránku.
    - Vytvorí NOVÝ súbor DochadzkaKlient.accdb (žiadna aktualizácia existujúceho: starý súbor sa len premenuje).
    - Importuje moduly kl_*.bas, skompiluje projekt, vytvorí formulár frmKlient (PripravKlienta) a makro AutoExec (Spusti()).
    - Spustí samotest (SamoTestKlienta); pri akomkoľvek ZLE zostavenie skončí chybou.
    - Zapíše verzia.txt (klient=<verzia> a sha256=<SHA-256 súboru .accdb>) a skopíruje spúšťače do výstupného priečinka.
    - Pri -Publikuj skopíruje výsledok do priečinka klient\ na serveri (najprv .accdb, verzia.txt až nakoniec).
    Zamestnanecké počítače tento zostavovač nepoužívajú; klienta si berú cez Spusti-Dochadzku.cmd.

.PARAMETER Vystup
    Výstupný priečinok (predvolene .\vystup vedľa tohto skriptu). Vznikne DochadzkaKlient.accdb, verzia.txt a spúšťače.
.PARAMETER Publikuj
    Priečinok klient\ na serveri (napr. \\server\dochadzka\klient). Nepovinné.
.PARAMETER Tiho
    Bez otázok.
.PARAMETER IbaOtestuj
    Iba skontroluje prostredie a balík (Access, integritu súborov, kódovú stránku). Nič nemení.
#>
[CmdletBinding()]
param(
    [string]$Vystup,
    [string]$Publikuj,
    [switch]$Tiho,
    [switch]$IbaOtestuj
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Koren = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = $null
$script:Varovania = New-Object System.Collections.ArrayList
$script:NazovDb = 'DochadzkaKlient.accdb'

# --------------------------------------------------------------------------------------------
# Pomocné funkcie
# --------------------------------------------------------------------------------------------
function Format-Cesta {
    # Do protokolu sa nezapisuje používateľské meno z cesty profilu.
    param([string]$Cesta)
    if ($env:USERPROFILE -and $Cesta) { return $Cesta.Replace($env:USERPROFILE, '%USERPROFILE%') }
    return $Cesta
}

function Write-Log {
    param([string]$Sprava, [string]$Uroven = 'INFO')
    $farba = switch ($Uroven) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    $riadok = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Uroven, $Sprava
    Write-Host $riadok -ForegroundColor $farba
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $riadok -Encoding UTF8 } catch { }
    }
    if ($Uroven -eq 'WARN') { [void]$script:Varovania.Add($Sprava) }
}

function Read-AnoNie {
    param([string]$Otazka, [bool]$Predvolene = $true)
    if ($Tiho) { return $Predvolene }
    $sufix = if ($Predvolene) { 'A/n' } else { 'a/N' }
    $o = Read-Host ('{0} ({1})' -f $Otazka, $sufix)
    if ([string]::IsNullOrWhiteSpace($o)) { return $Predvolene }
    return ($o.Trim().ToLower() -in @('a', 'ano', 'áno', 'y', 'yes'))
}

function Test-JeWindows {
    return ($env:OS -eq 'Windows_NT')
}

# --- Prostredie -----------------------------------------------------------------------------
function Test-AccessNainstalovany {
    try { return ($null -ne [type]::GetTypeFromProgID('Access.Application')) } catch { return $false }
}

function Get-OfficeVerzia {
    try {
        $cv = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\Access.Application\CurVer' -ErrorAction Stop).'(default)'
        if ($cv -match '\.(\d+)$') { return ('{0}.0' -f $Matches[1]) }
    } catch { }
    foreach ($v in '16.0', '15.0', '14.0', '12.0') {
        if (Test-Path -LiteralPath ('HKCU:\Software\Microsoft\Office\{0}\Access' -f $v)) { return $v }
    }
    return '16.0'
}

function Get-AnsiKodovaStranka {
    try { return [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop).ACP } catch { return 1250 }
}

function Enable-VbomPristup {
    # Dočasne povolí "Dôverovať prístupu k objektovému modelu projektu VBA". Vráti objekt na obnovenie pôvodného stavu.
    param([string]$OfficeVerzia)
    $kluc = 'HKCU:\Software\Microsoft\Office\{0}\Access\Security' -f $OfficeVerzia
    $stav = [pscustomobject]@{ Kluc = $kluc; Existoval = $false; Povodna = $null }
    if (-not (Test-Path -LiteralPath $kluc)) { New-Item -Path $kluc -Force | Out-Null }
    $p = Get-ItemProperty -LiteralPath $kluc -Name 'AccessVBOM' -ErrorAction SilentlyContinue
    if ($null -ne $p -and ($p.PSObject.Properties.Name -contains 'AccessVBOM')) { $stav.Existoval = $true; $stav.Povodna = $p.AccessVBOM }
    New-ItemProperty -LiteralPath $kluc -Name 'AccessVBOM' -Value 1 -PropertyType DWord -Force | Out-Null
    return $stav
}

function Restore-VbomPristup {
    param($Stav)
    if ($null -eq $Stav) { return }
    try {
        if ($Stav.Existoval) { Set-ItemProperty -LiteralPath $Stav.Kluc -Name 'AccessVBOM' -Value $Stav.Povodna }
        else { Remove-ItemProperty -LiteralPath $Stav.Kluc -Name 'AccessVBOM' -ErrorAction SilentlyContinue }
    } catch { Write-Log ('Nepodarilo sa obnoviť pôvodné nastavenie AccessVBOM: {0}' -f $_.Exception.Message) 'WARN' }
}

function New-AccessAplikacia {
    return (New-Object -ComObject 'Access.Application')
}

# --- Balík ----------------------------------------------------------------------------------
function Get-Manifest {
    $m = Join-Path $script:Koren 'manifest.json'
    if (-not (Test-Path -LiteralPath $m)) { throw "Chýba súbor manifest.json v $script:Koren" }
    return (Get-Content -LiteralPath $m -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-IntegritaBalika {
    param($Manifest)
    $chyby = @()
    foreach ($p in $Manifest.moduly.PSObject.Properties) {
        $nazov = $p.Name; $info = $p.Value
        $f = Join-Path $script:Koren ($info.subor -replace '/', '\')
        if (-not (Test-Path -LiteralPath $f)) { $chyby += "chýba súbor $($info.subor)"; continue }
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower()
        if ($h -ne $info.sha256) { $chyby += "${nazov}: kontrolný súčet nesedí (súbor bol zmenený alebo poškodený)" }
    }
    foreach ($s in @('Spusti-Dochadzku.cmd', 'Vytvor-Odkaz.cmd')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:Koren $s))) { $chyby += "chýba súbor $s" }
    }
    return $chyby
}

function Get-KodModulu {
    # Načíta modul (UTF-8), odstráni úvodné riadky Attribute VB_*, normalizuje konce riadkov na CRLF.
    param([string]$Subor)
    $txt = [System.IO.File]::ReadAllText($Subor, (New-Object System.Text.UTF8Encoding($false)))
    $txt = $txt.TrimStart([char]0xFEFF)
    $riadky = @($txt -split "\r?\n")
    $i = 0
    while ($i -lt $riadky.Count -and $riadky[$i] -match "^\s*'?Attribute\s+VB_") { $i++ }
    $telo = @($riadky[$i..($riadky.Count - 1)])
    while ($telo.Count -gt 0 -and [string]::IsNullOrWhiteSpace($telo[$telo.Count - 1])) { $telo = @($telo[0..($telo.Count - 2)]) }
    return (($telo -join "`r`n") + "`r`n")
}

function Test-ZnakyVKodovejStranke {
    param([string]$Kod, [int]$Stranka)
    try {
        $enc = [System.Text.Encoding]::GetEncoding($Stranka, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
        [void]$enc.GetBytes($Kod)
        return $true
    } catch { return $false }
}

# --- VBE ------------------------------------------------------------------------------------
function Get-VbProjekt {
    param($Acc, [string]$CestaDb)
    $vbe = $Acc.VBE
    foreach ($p in $vbe.VBProjects) {
        try { if ([string]::Equals($p.FileName, $CestaDb, [System.StringComparison]::OrdinalIgnoreCase)) { return $p } } catch { }
    }
    try { $ap = $vbe.ActiveVBProject; if ($null -ne $ap) { return $ap } } catch { }
    return $vbe.VBProjects.Item(1)
}

function Get-VbKomponent {
    param($Projekt, [string]$Nazov)
    foreach ($c in $Projekt.VBComponents) { if ($c.Name -eq $Nazov) { return $c } }
    return $null
}

function Set-VbModul {
    # Vloží štandardný modul (v novej databáze neexistuje, pre istotu sa existujúci prepíše).
    param($Projekt, [string]$Nazov, [string]$Kod)
    $k = Get-VbKomponent $Projekt $Nazov
    if ($null -ne $k) {
        if ($k.Type -ne 1) { throw "Komponent '$Nazov' existuje, ale nie je štandardný modul (typ $($k.Type))." }
        $cm = $k.CodeModule
        if ($cm.CountOfLines -gt 0) { $cm.DeleteLines(1, $cm.CountOfLines) }
    } else {
        $k = $Projekt.VBComponents.Add(1)
        $k.Name = $Nazov
        $cm = $k.CodeModule
        if ($cm.CountOfLines -gt 0) { $cm.DeleteLines(1, $cm.CountOfLines) }
    }
    $cm.AddFromString($Kod)
}

function Invoke-KompilaciaVba {
    # Ladenie > Kompilovať projekt (príkaz editora VBA, Id 578). Po úspešnej kompilácii je príkaz neaktívny (Enabled = False).
    param($Acc)
    try {
        $ctl = $Acc.VBE.CommandBars.FindControl(1, 578)
        if ($null -ne $ctl) {
            if ($ctl.Enabled) { $ctl.Execute() }
            return (-not $ctl.Enabled)
        }
    } catch { Write-Log ('Kompilácia cez editor VBA zlyhala, skúšam RunCommand: {0}' -f $_.Exception.Message) }
    try { $Acc.RunCommand(126); return $true } catch { return $false }
}

function Close-VsetkyFormulare {
    param($Acc)
    try {
        while ($Acc.Forms.Count -gt 0) { $Acc.DoCmd.Close(2, $Acc.Forms.Item(0).Name, 2) }   # acForm=2, acSaveNo=2
    } catch { }
}

function New-Referencia {
    param($Hodnota)
    $v = $Hodnota
    return [ref]$v
}

function Invoke-AccessRun {
    # Application.Run má parametre ByRef Variant - z PowerShellu ich treba odovzdať cez [ref].
    param($Acc, [string]$Nazov, [object[]]$Argumenty = @())
    $r = @()
    foreach ($a in $Argumenty) { $r += , (New-Referencia $a) }
    switch ($r.Count) {
        0 { return $Acc.Run($Nazov) }
        1 { return $Acc.Run($Nazov, $r[0]) }
        default { throw 'Invoke-AccessRun: podporovaný je najviac 1 argument.' }
    }
}

# --- Makro AutoExec -------------------------------------------------------------------------
function Test-MakroExistuje {
    param($Acc, [string]$Nazov)
    foreach ($m in $Acc.CurrentProject.AllMacros) { if ($m.Name -eq $Nazov) { return $true } }
    return $false
}

function Get-MakroText {
    # Exportuje makro do textu (SaveAsText) a vráti jeho obsah (ASCII, bez nulových bajtov - súbor môže byť UTF-16).
    param($Acc, [string]$Nazov)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('makro_{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    try {
        $Acc.SaveAsText(4, $Nazov, $tmp)   # acMacro = 4
        $b = [System.IO.File]::ReadAllBytes($tmp)
        return (([System.Text.Encoding]::ASCII.GetString($b)) -replace "`0", '')
    } catch { return '' }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function New-AutoExecMakro {
    # Vytvorí makro AutoExec s akciou RunCode a funkciou Spusti() (dva formáty makra ako v inštalátore HR).
    param($Acc)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('autoexec_{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    $enc = New-Object System.Text.UTF8Encoding($false)
    $varianty = @(
        ("Version =196611`r`nColumnsShown =8`r`nBegin`r`n    Action =""RunCode""`r`n    Argument =""Spusti()""`r`nEnd`r`n"),
        ("Version =196611`r`nColumnsShown =0`r`nBegin`r`n    Comment =""_AXL:<?xml version=\""1.0\"" encoding=\""UTF-16\"" standalone=\""no\""?>\015\012<UserInterfaceMacros xmlns=\""http://schemas.microsoft.com/office/accessservices/2009/11/application\""><Statements><Action Name=\""RunCode\""><Argument Name=\""FunctionName\"">Spusti()</Argument></Action></Statements></UserInterfaceMacros>""`r`nEnd`r`n")
    )
    $cislo = 0
    foreach ($v in $varianty) {
        $cislo++
        try {
            [System.IO.File]::WriteAllText($tmp, $v, $enc)
            $Acc.LoadFromText(4, 'AutoExec', $tmp)   # acMacro = 4
            if (Test-MakroExistuje $Acc 'AutoExec') {
                $t = Get-MakroText $Acc 'AutoExec'
                $kratky = ($t -replace '\s+', ' ')
                if ($kratky.Length -gt 350) { $kratky = $kratky.Substring(0, 350) }
                Write-Log ('Makro AutoExec (variant {0}) po uložení: {1}' -f $cislo, $kratky)
                if ($t -match 'Spusti') { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; return $true }
                Write-Log ('Makro AutoExec (variant {0}) neobsahuje volanie Spusti - skúšam ďalší formát.' -f $cislo) 'WARN'
                try { $Acc.DoCmd.DeleteObject(4, 'AutoExec') } catch { }
            }
        } catch {
            Write-Log ('Vytvorenie makra AutoExec (variant {0}) zlyhalo: {1}' -f $cislo, $_.Exception.Message)
        }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $false
}

# --- Výstup a publikovanie ------------------------------------------------------------------
function Write-VerziaTxt {
    # verzia.txt: dva riadky, ASCII, CRLF. Spúšťač porovnáva celý súbor bajt po bajte.
    param([string]$Cesta, [string]$Verzia, [string]$Sha256)
    $text = ('klient={0}' -f $Verzia) + "`r`n" + ('sha256={0}' -f $Sha256) + "`r`n"
    [System.IO.File]::WriteAllBytes($Cesta, [System.Text.Encoding]::ASCII.GetBytes($text))
}

function Publish-Klient {
    # Poradie je dôležité: klienti porovnávajú verzia.txt, preto sa ten zapíše AŽ po úplnom skopírovaní .accdb.
    param([string]$Vystup, [string]$CielPriecinok, [string]$Sha256)
    if (-not (Test-Path -LiteralPath $CielPriecinok)) { New-Item -ItemType Directory -Path $CielPriecinok -Force | Out-Null }
    $novy = Join-Path $CielPriecinok ($script:NazovDb + '.new')
    Copy-Item -LiteralPath (Join-Path $Vystup $script:NazovDb) -Destination $novy -Force
    $h = (Get-FileHash -LiteralPath $novy -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $Sha256) { Remove-Item -LiteralPath $novy -ErrorAction SilentlyContinue; throw 'Skopírovaný súbor na serveri má iný kontrolný súčet než pôvodný (kopírovanie zlyhalo).' }
    Move-Item -LiteralPath $novy -Destination (Join-Path $CielPriecinok $script:NazovDb) -Force
    foreach ($s in @('Spusti-Dochadzku.cmd', 'Vytvor-Odkaz.cmd')) {
        Copy-Item -LiteralPath (Join-Path $Vystup $s) -Destination (Join-Path $CielPriecinok $s) -Force
    }
    Copy-Item -LiteralPath (Join-Path $Vystup 'verzia.txt') -Destination (Join-Path $CielPriecinok 'verzia.txt') -Force
}

# --------------------------------------------------------------------------------------------
# Hlavný priebeh
# --------------------------------------------------------------------------------------------
function Invoke-Zostavenie {
    $kod = 0
    $vbomStav = $null
    $acc = $null
    $nechajOtvorene = $false
    $cestaDb = $null
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        Write-Host ''
        Write-Host '=============================================================' -ForegroundColor Cyan
        Write-Host '  Zostavovač klienta na razenie (Access + VBA)' -ForegroundColor Cyan
        Write-Host '=============================================================' -ForegroundColor Cyan

        # 1) Prostredie ---------------------------------------------------------------------
        if (-not (Test-JeWindows)) {
            Write-Log 'Zostavovač funguje iba vo Windows s nainštalovaným Microsoft Access.' 'ERR'
            return 2
        }
        if (-not (Test-AccessNainstalovany)) {
            Write-Log 'Microsoft Access nie je v tomto počítači dostupný (nenájdený COM objekt Access.Application).' 'ERR'
            Write-Log 'Nainštalujte plnú verziu Microsoft Access (Access Runtime nestačí, nemá editor VBA) a spustite zostavovač znova.' 'ERR'
            return 2
        }
        $ofVer = Get-OfficeVerzia
        Write-Log ('Microsoft Access nájdený (Office {0}).' -f $ofVer) 'OK'

        # 2) Balík --------------------------------------------------------------------------
        $manifest = Get-Manifest
        $moduly = @($manifest.moduly.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Nazov = $_.Name; Info = $_.Value } })
        Write-Log ('Balík klienta {0}: {1} modulov.' -f $manifest.balik, $moduly.Count)
        $chyby = @(Test-IntegritaBalika $manifest)
        if ($chyby.Count -gt 0) {
            $chyby | ForEach-Object { Write-Log $_ 'ERR' }
            Write-Log 'Balík je poškodený alebo neúplný - rozbaľte ho znova.' 'ERR'
            return 3
        }
        Write-Log 'Kontrola integrity súborov balíka: v poriadku.' 'OK'

        $kodovaStranka = Get-AnsiKodovaStranka
        $kody = @{}
        $nevhodne = @()
        foreach ($m in $moduly) {
            $kody[$m.Nazov] = Get-KodModulu (Join-Path $script:Koren ($m.Info.subor -replace '/', '\'))
            if (-not (Test-ZnakyVKodovejStranke $kody[$m.Nazov] $kodovaStranka)) { $nevhodne += $m.Nazov }
        }
        if ($nevhodne.Count -gt 0) {
            Write-Log ('Systémová kódová stránka {0} neobsahuje všetky slovenské znaky použité v moduloch ({1} modulov, napr. {2}).' -f $kodovaStranka, $nevhodne.Count, $nevhodne[0]) 'WARN'
            Write-Log 'Texty v rozhraní klienta môžu mať poškodené znaky. Nastavte Región -> Správa -> Jazyk pre programy bez Unicode = slovenčina a zostavenie zopakujte.' 'WARN'
            if (-not $Tiho -and -not (Read-AnoNie 'Pokračovať napriek tomu?' $false)) { return 4 }
        }

        if ($IbaOtestuj) {
            Write-Log 'Režim -IbaOtestuj: prostredie a balík sú v poriadku, nič sa nezmenilo.' 'OK'
            return 0
        }

        # 3) Výstupný priečinok a protokol --------------------------------------------------
        if (-not $Vystup) { $Vystup = Join-Path $script:Koren 'vystup' }
        $Vystup = [System.IO.Path]::GetFullPath($Vystup)
        if (-not (Test-Path -LiteralPath $Vystup)) { New-Item -ItemType Directory -Path $Vystup -Force | Out-Null }
        $script:LogFile = Join-Path $Vystup ('instalacia_klient_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Write-Log ('Protokol zostavenia: {0}' -f (Format-Cesta $script:LogFile))
        Write-Log ('Výstupný priečinok: {0}' -f (Format-Cesta $Vystup))

        $cestaDb = Join-Path $Vystup $script:NazovDb
        if (Test-Path -LiteralPath $cestaDb) {
            $stary = Join-Path $Vystup ('DochadzkaKlient_stary_{0}.accdb' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Move-Item -LiteralPath $cestaDb -Destination $stary
            Write-Log ('Doterajší súbor sa premenoval na {0} (zostavuje sa vždy nový).' -f (Split-Path -Leaf $stary)) 'WARN'
        }
        if (-not (Read-AnoNie 'Zostaviť klienta?' $true)) { Write-Log 'Zostavenie zrušené používateľom.' 'WARN'; return 4 }

        Write-Log 'Zostavovač dočasne zapne v Accesse "Dôverovať prístupu k objektovému modelu projektu VBA" (po skončení sa vráti pôvodná hodnota).'
        try { $vbomStav = Enable-VbomPristup $ofVer }
        catch { Write-Log ('Nepodarilo sa zapnúť prístup k VBA projektu v registroch: {0}' -f $_.Exception.Message) 'WARN' }

        # 4) Nová databáza a moduly ---------------------------------------------------------
        Write-Log 'Spúšťam Microsoft Access...' 'STEP'
        $acc = New-AccessAplikacia
        try { $acc.AutomationSecurity = 1 } catch { }   # msoAutomationSecurityLow: bez výziev na makrá počas zostavovania
        try { $acc.Visible = $true } catch { }
        $acc.NewCurrentDatabase($cestaDb)
        Write-Log 'Nová databáza vytvorená.' 'OK'

        try { $vbp = Get-VbProjekt $acc $cestaDb }
        catch {
            Write-Log ('Nie je možné pracovať s VBA projektom: {0}' -f $_.Exception.Message) 'ERR'
            Write-Log 'V Accesse zapnite: Súbor > Možnosti > Centrum zabezpečenia > Nastavenia > Nastavenia makier > "Dôverovať prístupu k objektovému modelu projektu VBA" a spustite zostavovač znova.' 'ERR'
            return 1
        }

        foreach ($m in $moduly) {
            Set-VbModul $vbp $m.Nazov $kody[$m.Nazov]
            try { $acc.DoCmd.Save(5, $m.Nazov) } catch { }   # acModule = 5
            Write-Log ('  modul {0}  v{1}' -f $m.Nazov, $m.Info.verzia)
        }
        Write-Log ('Moduly naimportované: {0}.' -f $moduly.Count) 'OK'

        # 5) Kompilácia ---------------------------------------------------------------------
        Write-Log 'Kompilujem VBA projekt (ak sa zobrazí chybové okno, poznačte si text a riadok)...' 'STEP'
        if (Invoke-KompilaciaVba $acc) {
            Write-Log 'Kompilácia prebehla bez chyby.' 'OK'
        } else {
            Write-Log 'Kompilácia hlásila chybu (pozri okno Accessu / editor VBA so zvýrazneným riadkom).' 'ERR'
            Write-Log 'Access ostáva otvorený na zvýraznenom riadku. Pošlite názov modulu, riadok a text chyby - zostavenie sa preruší.' 'ERR'
            $nechajOtvorene = $true
            return 5
        }

        # 6) Formulár, vlastnosti aplikácie -------------------------------------------------
        Write-Log 'Vytváram formulár frmKlient a nastavujem aplikáciu...' 'STEP'
        $chybaPripravy = [string](Invoke-AccessRun $acc 'PripravKlienta')
        if ($chybaPripravy) { Write-Log ('PripravKlienta: {0}' -f $chybaPripravy) 'ERR'; return 1 }
        Write-Log 'Formulár frmKlient vytvorený.' 'OK'

        # 7) Samotest (nezapisuje na server, len do lokálneho priečinka klienta) -------------
        Write-Log 'Spúšťam samotest klienta...' 'STEP'
        $zle = [int](Invoke-AccessRun $acc 'SamoTestKlienta')
        $vypis = [string](Invoke-AccessRun $acc 'VypisSamotestu')
        $vypis -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Log ('  ' + $_) }
        if ($zle -ne 0) {
            Write-Log ('Samotest klienta: ZLE {0}. Zostavenie sa preruší (podrobnosti v riadkoch vyššie).' -f $zle) 'ERR'
            return 6
        }
        Write-Log 'Samotest klienta: ZLE 0.' 'OK'

        # 8) AutoExec -----------------------------------------------------------------------
        if (New-AutoExecMakro $acc) { Write-Log 'Makro AutoExec vytvorené (volá Spusti).' 'OK' }
        else {
            Write-Log 'Makro AutoExec sa nepodarilo vytvoriť automaticky - klient by sa po otvorení nespustil.' 'ERR'
            Write-Log 'Ručne: Vytvoriť > Makro > akcia SpustiťKód (RunCode) > funkcia  Spusti()  > uložiť ako "AutoExec". Potom pokračujte ručne podľa README.' 'ERR'
            $nechajOtvorene = $true
            return 7
        }
        Close-VsetkyFormulare $acc
    }
    catch {
        Write-Log ('Nečakaná chyba: {0}' -f $_.Exception.Message) 'ERR'
        if ($_.InvocationInfo) { Write-Log $_.InvocationInfo.PositionMessage 'ERR' }
        Write-Log 'Rozpracovaný súbor DochadzkaKlient.accdb nepoužívajte; spustite zostavovač znova.' 'WARN'
        $kod = 1
    }
    finally {
        if ($null -ne $acc) {
            if ($nechajOtvorene) {
                try { $acc.UserControl = $true } catch { }
            } else {
                try { $acc.CloseCurrentDatabase() } catch { }
                try { $acc.Quit(1) } catch { }
            }
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($acc) } catch { }
            $acc = $null
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        }
        Restore-VbomPristup $vbomStav
    }

    if ($kod -ne 0 -and $null -ne $cestaDb) { return $kod }

    # 9) verzia.txt, spúšťače, publikovanie ------------------------------------------------------
    if ($kod -eq 0 -and -not $nechajOtvorene -and $null -ne $cestaDb) {
        try {
            $sha = (Get-FileHash -LiteralPath $cestaDb -Algorithm SHA256).Hash.ToLower()
            Write-VerziaTxt (Join-Path $Vystup 'verzia.txt') ([string]$manifest.balik) $sha
            foreach ($s in @('Spusti-Dochadzku.cmd', 'Vytvor-Odkaz.cmd')) {
                if ($script:Koren -ne $Vystup) { Copy-Item -LiteralPath (Join-Path $script:Koren $s) -Destination (Join-Path $Vystup $s) -Force }
            }
            Write-Log ('Zapísané: {0}, verzia.txt (klient={1}, sha256={2}...), spúšťače.' -f $script:NazovDb, $manifest.balik, $sha.Substring(0, 12)) 'OK'
            if ($Publikuj) {
                Write-Log ('Publikujem do {0}...' -f $Publikuj) 'STEP'
                Publish-Klient $Vystup $Publikuj $sha
                Write-Log 'Publikované (najprv .accdb a spúšťače, verzia.txt nakoniec).' 'OK'
            }
        } catch {
            Write-Log ('Dokončenie zlyhalo: {0}' -f $_.Exception.Message) 'ERR'
            return 1
        }
        Write-Host ''
        if ($script:Varovania.Count -gt 0) { Write-Log ('Zostavenie dokončené s upozorneniami ({0}).' -f $script:Varovania.Count) 'WARN' }
        else { Write-Log 'Zostavenie dokončené.' 'OK' }
        Write-Log ('Výsledok: {0}' -f (Format-Cesta $Vystup))
    }
    return $kod
}

if ($env:DOCH_KLIENT_ZOSTAVOVAC_TEST -ne '1') {
    $navrat = Invoke-Zostavenie
    exit ([int]($navrat | Select-Object -Last 1))
}
