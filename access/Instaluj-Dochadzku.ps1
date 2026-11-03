<#
.SYNOPSIS
    Inštalátor dochádzkového systému (Microsoft Access + VBA moduly).

.DESCRIPTION
    - Overí, či je dostupný Microsoft Access (inak oznámi a skončí).
    - Vytvorí novú databázu (.accdb) alebo aktualizuje existujúcu (so zálohou).
    - Importuje verzionované VBA moduly z priečinka "moduly" (podľa manifest.json; pri aktualizácii len zmenené).
    - Skompiluje projekt, inicializuje tabuľky, voliteľne naimportuje dáta zo staršej verzie databázy.
    - Vytvorí makro AutoExec, uloží a otvorí databázu.

.PARAMETER Cesta
    Cieľový súbor databázy. Predvolene sa pracuje v priečinku inštalátora: nájdu sa existujúce databázy
    a nová sa vytvorí ako dochadzka-<verzia balíka>.accdb. Ak zadaný súbor existuje, ide o aktualizáciu.
.PARAMETER ZdrojovaDatabaza
    Staršia databáza dochádzky, z ktorej sa doplnia dáta (zamestnanci, razenia, číselníky).
.PARAMETER Tiho
    Bez otázok (použijú sa predvolené odpovede a zadané parametre).
.PARAMETER BezKompilacie
    Preskočí kompiláciu VBA projektu po importe modulov.
.PARAMETER BezDoveryhodnejLokality
    Nepridá priečinok databázy medzi dôveryhodné umiestnenia Accessu (makra/VBA môžu byť potom blokované).
.PARAMETER NeOtvarat
    Po inštalácii databázu neotvorí.
.PARAMETER VsetkyModuly
    Pri aktualizácii preinštaluje všetky moduly (nielen zmenené).
.PARAMETER IbaOtestuj
    Iba skontroluje prostredie a balík (Access, integritu súborov, kódovú stránku). Nič nemení.
#>
[CmdletBinding()]
param(
    [string]$Cesta,
    [string]$ZdrojovaDatabaza,
    [switch]$Tiho,
    [switch]$BezKompilacie,
    [switch]$BezDoveryhodnejLokality,
    [switch]$NeOtvarat,
    [switch]$VsetkyModuly,
    [switch]$IbaOtestuj
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Koren   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogFile = $null
$script:Varovania = New-Object System.Collections.ArrayList

# --------------------------------------------------------------------------------------------
# Pomocné funkcie
# --------------------------------------------------------------------------------------------
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

function Read-Odpoved {
    param([string]$Otazka, [string]$Predvolene = '')
    if ($Tiho) { return $Predvolene }
    $t = if ($Predvolene) { '{0} [{1}]' -f $Otazka, $Predvolene } else { $Otazka }
    $o = Read-Host $t
    if ([string]::IsNullOrWhiteSpace($o)) { return $Predvolene }
    return $o.Trim()
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

# --- Prostredie (oddelené do funkcií, aby sa dali v testoch nahradiť) -------------------------
function Test-AccessNainstalovany {
    try { return ($null -ne [type]::GetTypeFromProgID('Access.Application')) } catch { return $false }
}

function Get-OfficeVerzia {
    # Vráti napr. "16.0" podľa registrov (CurVer), inak najnovšiu nájdenú vetvu v HKCU.
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

function Add-DoveryhodnaLokalita {
    param([string]$OfficeVerzia, [string]$Priecinok)
    $zaklad = 'HKCU:\Software\Microsoft\Office\{0}\Access\Security\Trusted Locations' -f $OfficeVerzia
    $kluc = Join-Path $zaklad 'Dochadzka'
    if (-not (Test-Path -LiteralPath $kluc)) { New-Item -Path $kluc -Force | Out-Null }
    $cesta = $Priecinok.TrimEnd('\') + '\'
    New-ItemProperty -LiteralPath $kluc -Name 'Path' -Value $cesta -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $kluc -Name 'AllowSubfolders' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $kluc -Name 'Description' -Value 'Dochadzkovy system (instalator)' -PropertyType String -Force | Out-Null
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
    # Vloží/prepíše štandardný modul. Vráti $true, ak išlo o nahradenie existujúceho.
    param($Projekt, [string]$Nazov, [string]$Kod)
    $k = Get-VbKomponent $Projekt $Nazov
    $nahradil = $false
    if ($null -ne $k) {
        if ($k.Type -ne 1) { throw "Komponent '$Nazov' existuje, ale nie je štandardný modul (typ $($k.Type))." }
        $cm = $k.CodeModule
        if ($cm.CountOfLines -gt 0) { $cm.DeleteLines(1, $cm.CountOfLines) }
        $nahradil = $true
    } else {
        $k = $Projekt.VBComponents.Add(1)
        $k.Name = $Nazov
        $cm = $k.CodeModule
        if ($cm.CountOfLines -gt 0) { $cm.DeleteLines(1, $cm.CountOfLines) }
    }
    $cm.AddFromString($Kod)
    return $nahradil
}

function Export-VbModul {
    param($Projekt, [string]$Nazov, [string]$Priecinok)
    $k = Get-VbKomponent $Projekt $Nazov
    if ($null -eq $k) { return }
    if (-not (Test-Path -LiteralPath $Priecinok)) { New-Item -ItemType Directory -Path $Priecinok -Force | Out-Null }
    $ext = switch ($k.Type) { 1 { '.bas' } 2 { '.cls' } default { '.frm' } }
    try { $k.Export((Join-Path $Priecinok ($Nazov + $ext))) } catch { Write-Log "Zálohu modulu $Nazov sa nepodarilo vytvoriť: $($_.Exception.Message)" 'WARN' }
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
    param($Acc)
    if (Test-MakroExistuje $Acc 'AutoExec') {
        $t = Get-MakroText $Acc 'AutoExec'
        if ($t -match 'AutoExecStart') { Write-Log 'Makro AutoExec už existuje (volá AutoExecStart) - ponechané.'; return $true }
        Write-Log 'Existujúce makro AutoExec nevolá AutoExecStart - nahrádzam ho (pôvodné ukladám ako AutoExec_old).' 'WARN'
        try { $Acc.DoCmd.Rename('AutoExec_old', 4, 'AutoExec') } catch { try { $Acc.DoCmd.DeleteObject(4, 'AutoExec') } catch { } }
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('autoexec_{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    $enc = New-Object System.Text.UTF8Encoding($false)
    $varianty = @(
        # klasický formát makra
        ("Version =196611`r`nColumnsShown =8`r`nBegin`r`n    Action =""RunCode""`r`n    Argument =""AutoExecStart()""`r`nEnd`r`n"),
        # Access 2010+ (XML makro)
        ("Version =196611`r`nColumnsShown =0`r`nBegin`r`n    Comment =""_AXL:<?xml version=\""1.0\"" encoding=\""UTF-16\"" standalone=\""no\""?>\015\012<UserInterfaceMacros xmlns=\""http://schemas.microsoft.com/office/accessservices/2009/11/application\""><Statements><Action Name=\""RunCode\""><Argument Name=\""FunctionName\"">AutoExecStart()</Argument></Action></Statements></UserInterfaceMacros>""`r`nEnd`r`n")
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
                if ($t -match 'AutoExecStart') { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue; return $true }
                Write-Log ('Makro AutoExec (variant {0}) neobsahuje volanie AutoExecStart - skúšam ďalší formát.' -f $cislo) 'WARN'
                try { $Acc.DoCmd.DeleteObject(4, 'AutoExec') } catch { }
            }
        } catch {
            Write-Log ('Vytvorenie makra AutoExec (variant {0}) zlyhalo: {1}' -f $cislo, $_.Exception.Message)
        }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    return $false
}

function Close-VsetkyFormulare {
    param($Acc)
    try {
        while ($Acc.Forms.Count -gt 0) { $Acc.DoCmd.Close(2, $Acc.Forms.Item(0).Name, 2) }   # acForm=2, acSaveNo=2
    } catch { }
}

function Invoke-KompilaciaVba {
    # Ladenie > Kompilovať projekt (príkaz editora VBA, Id 578). Po úspešnej kompilácii je príkaz neaktívny (Enabled = False).
    # Pri chybe Access zobrazí okno a príkaz ostane aktívny. Vráti $true, ak je projekt skompilovaný.
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
        2 { return $Acc.Run($Nazov, $r[0], $r[1]) }
        default { throw 'Invoke-AccessRun: podporované sú najviac 2 argumenty.' }
    }
}

function ConvertFrom-ManifestText {
    # "modul|verzia|hash;modul|verzia|hash" -> hashtable
    param([string]$Text)
    $h = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $h }
    foreach ($d in ($Text -split ';')) {
        $p = $d -split '\|'
        if ($p.Count -ge 2 -and $p[0]) { $h[$p[0]] = [pscustomobject]@{ Verzia = $p[1]; Hash = $(if ($p.Count -ge 3) { $p[2] } else { '' }) } }
    }
    return $h
}

# --- Rozpoznanie databáz v priečinku --------------------------------------------------------
function Open-DbIbaNaCitanie {
    # DBEngine.OpenDatabase(cesta, Options=False, ReadOnly=True); pri chybe väzby skúsi odovzdať argumenty cez [ref]
    param($Acc, [string]$Subor)
    try { return $Acc.DBEngine.OpenDatabase($Subor, $false, $true) }
    catch {
        if ($_.Exception.Message -match 'PSReference') {
            $a = New-Referencia $false; $b = New-Referencia $true
            return $Acc.DBEngine.OpenDatabase($Subor, $a, $b)
        }
        throw
    }
}

function Get-InfoDatabazy {
    # Zistí typ databázy: VERZIONOVANA (inštalátor 2.6+, tabuľka VerzieModulov), STARSIA (dochádzka bez verzionovania),
    # INA (nie je databáza dochádzky), NECITATELNA. Doplní verziu balíka a počet razení.
    param($Acc, [System.IO.FileInfo]$Subor)
    $info = [pscustomobject]@{ Cesta = $Subor.FullName; Nazov = $Subor.Name; Zmenene = $Subor.LastWriteTime; Typ = 'NECITATELNA'; VerziaBalika = ''; Razeni = -1; Chyba = '' }
    $db = $null
    try {
        $db = Open-DbIbaNaCitanie $Acc $Subor.FullName
        $tab = @{}
        foreach ($t in $db.TableDefs) { $tab[[string]$t.Name] = $true }
        if ($tab.ContainsKey('VerzieModulov')) { $info.Typ = 'VERZIONOVANA' }
        elseif ($tab.ContainsKey('DochadzkaImport') -or $tab.ContainsKey('Zamestnanci')) { $info.Typ = 'STARSIA' }
        else { $info.Typ = 'INA' }
        if ($tab.ContainsKey('DochadzkaImport')) {
            try { $rs = $db.OpenRecordset('SELECT Count(*) AS N FROM DochadzkaImport'); $info.Razeni = [long]$rs.Fields.Item(0).Value; $rs.Close() } catch { }
        }
        if ($tab.ContainsKey('NastaveniaSystemu')) {
            try {
                $rs = $db.OpenRecordset("SELECT Hodnota FROM NastaveniaSystemu WHERE Kluc='VerziaBalika'")
                if (-not $rs.EOF) { $info.VerziaBalika = [string]$rs.Fields.Item(0).Value }
                $rs.Close()
            } catch { }
        }
    } catch {
        $info.Chyba = $_.Exception.Message
    } finally {
        if ($null -ne $db) { try { $db.Close() } catch { } }
    }
    return $info
}

function Get-DatabazyVPriecinku {
    # Databázy (.accdb/.mdb) v priečinku okrem záloh inštalátora; najnovšie prvé, iba databázy dochádzky.
    param($Acc, [string]$Priecinok)
    $subory = @(Get-ChildItem -LiteralPath $Priecinok -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.accdb', '.mdb') -and $_.Name -notmatch '\.zaloha_\d' -and $_.Name -notlike '~*' } |
        Sort-Object LastWriteTime -Descending)
    $vysledok = @()
    foreach ($f in $subory) {
        $i = Get-InfoDatabazy $Acc $f
        if ($i.Typ -in @('VERZIONOVANA', 'STARSIA')) { $vysledok += $i }
        elseif ($i.Typ -eq 'NECITATELNA') { Write-Log ('Databázu {0} sa nepodarilo prečítať: {1}' -f $f.Name, $i.Chyba) 'WARN' }
    }
    return $vysledok
}

function Format-Kandidat {
    param($K)
    $typ = if ($K.Typ -eq 'VERZIONOVANA') { 'z inštalátora' + $(if ($K.VerziaBalika) { ' v' + $K.VerziaBalika } else { '' }) } else { 'staršia verzia (bez verzionovania)' }
    $raz = if ($K.Razeni -ge 0) { ', razení: ' + $K.Razeni } else { '' }
    return ('{0}  ({1}{2}, zmenená {3:dd.MM.yyyy HH:mm})' -f $K.Nazov, $typ, $raz, $K.Zmenene)
}

function Get-VolnyNazov {
    param([string]$Priecinok, [string]$Meno)
    $cesta = Join-Path $Priecinok $Meno
    if (-not (Test-Path -LiteralPath $cesta)) { return $cesta }
    $zaklad = [System.IO.Path]::GetFileNameWithoutExtension($Meno)
    for ($n = 2; $n -lt 100; $n++) {
        $c = Join-Path $Priecinok ('{0}-{1}.accdb' -f $zaklad, $n)
        if (-not (Test-Path -LiteralPath $c)) { return $c }
    }
    return $cesta
}

function Get-PredvolenyPlan {
    # Režimy: N = nová prázdna, I = nová + import dát zo staršej DB, K = kópia verzionovanej DB + aktualizácia modulov,
    #         A = aktualizácia existujúcej databázy na mieste.
    param($Kandidati, [string]$Priecinok, [string]$MenoNovej, [string]$CestaParam, [string]$ZdrojParam)
    $ciel = Join-Path $Priecinok $MenoNovej
    if ($CestaParam) {
        $ciel = [System.IO.Path]::GetFullPath($CestaParam)
        if ([System.IO.Path]::GetExtension($ciel) -ne '.accdb') { $ciel = $ciel + '.accdb' }
        if (Test-Path -LiteralPath $ciel) { return [pscustomobject]@{ Rezim = 'A'; Ciel = $ciel; Zdroj = ''; Kopia = '' } }
        if ($ZdrojParam) { return [pscustomobject]@{ Rezim = 'I'; Ciel = $ciel; Zdroj = [System.IO.Path]::GetFullPath($ZdrojParam); Kopia = '' } }
        return [pscustomobject]@{ Rezim = 'N'; Ciel = $ciel; Zdroj = ''; Kopia = '' }
    }
    if ($ZdrojParam) { return [pscustomobject]@{ Rezim = 'I'; Ciel = (Get-VolnyNazov $Priecinok $MenoNovej); Zdroj = [System.IO.Path]::GetFullPath($ZdrojParam); Kopia = '' } }
    if (Test-Path -LiteralPath $ciel) { return [pscustomobject]@{ Rezim = 'A'; Ciel = $ciel; Zdroj = ''; Kopia = '' } }
    $najnovsia = $Kandidati | Select-Object -First 1
    if ($null -eq $najnovsia) { return [pscustomobject]@{ Rezim = 'N'; Ciel = $ciel; Zdroj = ''; Kopia = '' } }
    if ($najnovsia.Typ -eq 'VERZIONOVANA') { return [pscustomobject]@{ Rezim = 'K'; Ciel = $ciel; Zdroj = ''; Kopia = $najnovsia.Cesta } }
    return [pscustomobject]@{ Rezim = 'I'; Ciel = $ciel; Zdroj = $najnovsia.Cesta; Kopia = '' }
}

function Format-Plan {
    param($P)
    $meno = Split-Path -Leaf $P.Ciel
    switch ($P.Rezim) {
        'N' { return ('nová prázdna databáza {0}' -f $meno) }
        'I' { return ('nová databáza {0} + import dát z {1}' -f $meno, (Split-Path -Leaf $P.Zdroj)) }
        'K' { return ('kópia {0} -> {1} a aktualizácia modulov (dáta sa prenesú celé)' -f (Split-Path -Leaf $P.Kopia), $meno) }
        'A' { return ('aktualizácia modulov v existujúcej databáze {0} (so zálohou)' -f $meno) }
    }
}

function Read-Plan {
    # Ponúkne predvolený postup; Enter = potvrdiť, alebo zmeniť zdroj / režim / názov.
    param($Plan, $Kandidati, [string]$Priecinok, [string]$MenoNovej)
    Write-Host ''
    Write-Host ('Predvolený postup: {0}' -f (Format-Plan $Plan)) -ForegroundColor Cyan
    if (Read-AnoNie 'Použiť predvolený postup?' $true) { return $Plan }

    Write-Host ''
    Write-Host '  N = nová prázdna databáza'
    if ($Kandidati.Count -gt 0) {
        Write-Host '  I = nová databáza + import dát zo staršej databázy (zdroj sa iba číta)'
        Write-Host '  K = kópia databázy z inštalátora + aktualizácia modulov (prenesie všetko vrátane výpočtov)'
        Write-Host '  A = aktualizovať existujúcu databázu na mieste (so zálohou)'
    }
    $rezim = (Read-Odpoved 'Postup (N/I/K/A)' $Plan.Rezim).ToUpper()
    if ($rezim -notin @('N', 'I', 'K', 'A')) { $rezim = $Plan.Rezim }
    if ($Kandidati.Count -eq 0) { $rezim = 'N' }

    $vybrana = $null
    if ($rezim -in @('I', 'K', 'A')) {
        $pred = 1
        $povodna = if ($Plan.Zdroj) { $Plan.Zdroj } elseif ($Plan.Kopia) { $Plan.Kopia } else { $Plan.Ciel }
        for ($i = 0; $i -lt $Kandidati.Count; $i++) { if ($Kandidati[$i].Cesta -eq $povodna) { $pred = $i + 1 } }
        $o = Read-Odpoved ('Databáza (číslo zo zoznamu 1-{0})' -f $Kandidati.Count) ([string]$pred)
        $n = 0
        if (-not [int]::TryParse($o, [ref]$n) -or $n -lt 1 -or $n -gt $Kandidati.Count) { $n = $pred }
        $vybrana = $Kandidati[$n - 1]
    }
    if ($rezim -eq 'A') { return [pscustomobject]@{ Rezim = 'A'; Ciel = $vybrana.Cesta; Zdroj = ''; Kopia = '' } }

    $navrh = Split-Path -Leaf (Get-VolnyNazov $Priecinok $MenoNovej)
    $meno = Read-Odpoved 'Názov novej databázy' $navrh
    if ([System.IO.Path]::GetExtension($meno) -ne '.accdb') { $meno = $meno + '.accdb' }
    $ciel = Join-Path $Priecinok $meno
    if (Test-Path -LiteralPath $ciel) {
        Write-Log ('Súbor {0} už existuje - použije sa {1}.' -f $meno, (Split-Path -Leaf (Get-VolnyNazov $Priecinok $meno))) 'WARN'
        $ciel = Get-VolnyNazov $Priecinok $meno
    }
    switch ($rezim) {
        'N' { return [pscustomobject]@{ Rezim = 'N'; Ciel = $ciel; Zdroj = ''; Kopia = '' } }
        'I' { return [pscustomobject]@{ Rezim = 'I'; Ciel = $ciel; Zdroj = $vybrana.Cesta; Kopia = '' } }
        'K' { return [pscustomobject]@{ Rezim = 'K'; Ciel = $ciel; Zdroj = ''; Kopia = $vybrana.Cesta } }
    }
}

# --------------------------------------------------------------------------------------------
# Hlavný priebeh
# --------------------------------------------------------------------------------------------
function Invoke-Instalacia {
    $kod = 0
    $vbomStav = $null
    $acc = $null
    $nechajOtvorene = $false
    try {
        try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
        Write-Host ''
        Write-Host '=============================================================' -ForegroundColor Cyan
        Write-Host '  Inštalátor dochádzkového systému (Access + VBA)' -ForegroundColor Cyan
        Write-Host '=============================================================' -ForegroundColor Cyan

        # 1) Prostredie ---------------------------------------------------------------------
        if (-not (Test-JeWindows)) {
            Write-Log 'Inštalátor funguje iba vo Windows s nainštalovaným Microsoft Access.' 'ERR'
            return 2
        }
        if (-not (Test-AccessNainstalovany)) {
            Write-Log 'Microsoft Access nie je v tomto počítači dostupný (nenájdený COM objekt Access.Application).' 'ERR'
            Write-Log 'Nainštalujte plnú verziu Microsoft Access (Access Runtime nestačí, nemá editor VBA) a spustite inštalátor znova.' 'ERR'
            return 2
        }
        $ofVer = Get-OfficeVerzia
        Write-Log ('Microsoft Access nájdený (Office {0}).' -f $ofVer) 'OK'

        # 2) Balík --------------------------------------------------------------------------
        $manifest = Get-Manifest
        $moduly = @($manifest.moduly.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Nazov = $_.Name; Info = $_.Value } })
        Write-Log ('Balík {0}: {1} modulov.' -f $manifest.balik, $moduly.Count)
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
            Write-Log 'Texty v rozhraní môžu mať poškodené znaky. Nastavte Región -> Správa -> Jazyk pre programy bez Unicode = slovenčina a inštaláciu zopakujte.' 'WARN'
            if (-not $Tiho -and -not (Read-AnoNie 'Pokračovať napriek tomu?' $false)) { return 4 }
        }

        if ($IbaOtestuj) {
            Write-Log 'Režim -IbaOtestuj: prostredie a balík sú v poriadku, nič sa nezmenilo.' 'OK'
            return 0
        }

        # 3) Priečinok, protokol, dôveryhodné umiestnenie --------------------------------------
        #    Bez -Cesta sa pracuje v priečinku inštalátora: tam sa hľadajú existujúce databázy a vytvorí sa nová.
        if ($Cesta) { $priecinok = Split-Path -Parent ([System.IO.Path]::GetFullPath($Cesta)) } else { $priecinok = $script:Koren }
        if (-not (Test-Path -LiteralPath $priecinok)) { New-Item -ItemType Directory -Path $priecinok -Force | Out-Null }
        $script:LogFile = Join-Path $priecinok ('instalacia_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Write-Log ('Protokol inštalácie: {0}' -f $script:LogFile)
        Write-Log ('Pracovný priečinok: {0}' -f $priecinok)

        $trusted = -not $BezDoveryhodnejLokality
        if ($trusted -and -not $Tiho) {
            $trusted = Read-AnoNie ('Pridať priečinok "{0}" medzi dôveryhodné umiestnenia Accessu (inak Access zablokuje VBA a makrá)?' -f $priecinok) $true
        }
        if ($trusted) {
            try { Add-DoveryhodnaLokalita $ofVer $priecinok; Write-Log 'Priečinok pridaný medzi dôveryhodné umiestnenia.' 'OK' }
            catch { Write-Log ('Dôveryhodné umiestnenie sa nepodarilo nastaviť: {0}' -f $_.Exception.Message) 'WARN' }
        }
        Write-Log 'Inštalátor dočasne zapne v Accesse "Dôverovať prístupu k objektovému modelu projektu VBA" (po skončení sa vráti pôvodná hodnota).'
        try { $vbomStav = Enable-VbomPristup $ofVer }
        catch { Write-Log ('Nepodarilo sa zapnúť prístup k VBA projektu v registroch: {0}' -f $_.Exception.Message) 'WARN' }

        # 4) Access (zatiaľ skrytý - slúži aj na rozpoznanie existujúcich databáz) -----------------
        Write-Log 'Spúšťam Microsoft Access...' 'STEP'
        $acc = New-AccessAplikacia
        try { $acc.AutomationSecurity = 1 } catch { }   # msoAutomationSecurityLow: bez výziev na makrá počas inštalácie

        # 5) Rozpoznanie databáz v priečinku a predvolený postup ----------------------------------
        $menoNovej = 'dochadzka-{0}.accdb' -f $manifest.balik
        $kandidati = @(Get-DatabazyVPriecinku $acc $priecinok)
        if ($kandidati.Count -gt 0) {
            Write-Log ('Nájdené databázy v priečinku ({0}):' -f $kandidati.Count) 'STEP'
            $i = 0
            foreach ($k in $kandidati) { $i++; Write-Log ('  [{0}] {1}' -f $i, (Format-Kandidat $k)) }
        } else {
            Write-Log 'V priečinku nie je žiadna databáza dochádzky - vytvorí sa nová prázdna.'
        }

        $plan = Get-PredvolenyPlan $kandidati $priecinok $menoNovej $Cesta $ZdrojovaDatabaza
        if (-not $Tiho) { $plan = Read-Plan $plan $kandidati $priecinok $menoNovej }
        if ($null -eq $plan) { Write-Log 'Inštalácia zrušená používateľom.' 'WARN'; return 4 }

        $Cesta = $plan.Ciel
        $ZdrojovaDatabaza = $plan.Zdroj
        $aktualizacia = ($plan.Rezim -in @('A', 'K'))
        if ($ZdrojovaDatabaza) {
            if (-not (Test-Path -LiteralPath $ZdrojovaDatabaza)) { Write-Log ('Zdrojová databáza neexistuje: {0}' -f $ZdrojovaDatabaza) 'ERR'; return 1 }
            if ([string]::Equals($ZdrojovaDatabaza, $Cesta, [System.StringComparison]::OrdinalIgnoreCase)) { Write-Log 'Zdrojová a cieľová databáza je ten istý súbor.' 'ERR'; return 1 }
        }
        Write-Log ('Postup: {0}' -f (Format-Plan $plan)) 'STEP'
        if (-not (Read-AnoNie 'Spustiť inštaláciu?' $true)) { Write-Log 'Inštalácia zrušená používateľom.' 'WARN'; return 4 }

        # 6) Príprava súboru databázy (záloha / kópia) -------------------------------------------
        $zalohaModulov = Join-Path $priecinok ('zaloha_moduly_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        if ($plan.Rezim -eq 'A') {
            $zaloha = Join-Path $priecinok ('{0}.zaloha_{1}.accdb' -f [System.IO.Path]::GetFileNameWithoutExtension($Cesta), (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $Cesta -Destination $zaloha
            Write-Log ('Záloha databázy: {0}' -f $zaloha) 'OK'
        } elseif ($plan.Rezim -eq 'K') {
            Copy-Item -LiteralPath $plan.Kopia -Destination $Cesta
            Write-Log ('Databáza skopírovaná: {0} -> {1} (pôvodná ostáva nezmenená)' -f $plan.Kopia, $Cesta) 'OK'
        }

        try { $acc.Visible = $true } catch { }
        if ($aktualizacia) {
            $acc.OpenCurrentDatabase($Cesta)
            Close-VsetkyFormulare $acc
        } else {
            $acc.NewCurrentDatabase($Cesta)
        }
        Write-Log ('Databáza otvorená: {0}' -f $Cesta) 'OK'

        try { $vbp = Get-VbProjekt $acc $Cesta }
        catch {
            Write-Log ('Nie je možné pracovať s VBA projektom: {0}' -f $_.Exception.Message) 'ERR'
            Write-Log 'V Accesse zapnite: Súbor > Možnosti > Centrum zabezpečenia > Nastavenia > Nastavenia makier > "Dôverovať prístupu k objektovému modelu projektu VBA" a spustite inštalátor znova.' 'ERR'
            return 1
        }

        # 7) Moduly -------------------------------------------------------------------------
        $nainst = @{}
        if ($aktualizacia -and -not $VsetkyModuly) {
            try { $nainst = ConvertFrom-ManifestText ([string](Invoke-AccessRun $acc 'VerzieModulovText')) } catch { Write-Log 'Evidencia verzií modulov v databáze nie je k dispozícii - nainštalujú sa všetky moduly.' }
        }
        # zrušené / zastarané moduly
        foreach ($z in @($manifest.zrusene)) {
            if ($z -and (Get-VbKomponent $vbp $z)) {
                Export-VbModul $vbp $z $zalohaModulov
                $vbp.VBComponents.Remove((Get-VbKomponent $vbp $z))
                Write-Log ('Odstránený zastaraný modul {0} (záloha v {1}).' -f $z, $zalohaModulov) 'OK'
            }
        }
        $zapisManifest = New-Object System.Collections.ArrayList
        $pocetNovych = 0; $pocetNahrad = 0; $pocetPreskocenych = 0
        foreach ($m in $moduly) {
            $n = $m.Nazov; $info = $m.Info
            $jeVProjekte = $null -ne (Get-VbKomponent $vbp $n)
            $aktualny = $nainst.ContainsKey($n) -and $nainst[$n].Verzia -eq $info.verzia -and $nainst[$n].Hash -eq $info.sha256
            if ($aktualny -and $jeVProjekte -and -not $VsetkyModuly) { $pocetPreskocenych++; continue }
            if ($jeVProjekte) { Export-VbModul $vbp $n $zalohaModulov }
            $nahradil = Set-VbModul $vbp $n $kody[$n]
            try { $acc.DoCmd.Save(5, $n) } catch { }   # acModule = 5
            if ($nahradil) { $pocetNahrad++ } else { $pocetNovych++ }
            [void]$zapisManifest.Add(('{0}|{1}|{2}' -f $n, $info.verzia, $info.sha256))
            Write-Log ('  {0} {1}  v{2}' -f $(if ($nahradil) { 'aktualizovaný' } else { 'nový         ' }), $n, $info.verzia)
        }
        Write-Log ('Moduly: nových {0}, aktualizovaných {1}, nezmenených {2}.' -f $pocetNovych, $pocetNahrad, $pocetPreskocenych) 'OK'

        $zname = @()
        foreach ($c in $vbp.VBComponents) {
            if ($c.Type -eq 1 -and -not ($moduly | Where-Object { $_.Nazov -eq $c.Name })) { $zname += $c.Name }
        }
        if ($zname.Count -gt 0) {
            Write-Log ('V databáze sú moduly mimo balíka: {0}. Ak ide o staré verzie našich modulov, môžu spôsobiť chybu kompilácie (duplicitné názvy) - odstráňte ich ručne.' -f ($zname -join ', ')) 'WARN'
        }

        # 8) Kompilácia (pred spustením akéhokoľvek VBA) ------------------------------------
        if (-not $BezKompilacie) {
            Write-Log 'Kompilujem VBA projekt (ak sa zobrazí chybové okno, poznačte si text a riadok)...' 'STEP'
            if (Invoke-KompilaciaVba $acc) {
                Write-Log 'Kompilácia prebehla bez chyby.' 'OK'
            } else {
                Write-Log 'Kompilácia hlásila chybu (pozri okno Accessu / editor VBA so zvýrazneným riadkom).' 'ERR'
                Write-Log 'Access ostáva otvorený na zvýraznenom riadku. Pošlite názov modulu, riadok a text chyby - inštalácia sa preruší.' 'ERR'
                $nechajOtvorene = $true
                return 5
            }
        }

        # 9) Inicializácia dát --------------------------------------------------------------
        Write-Log 'Inicializujem tabuľky a predvolenú konfiguráciu...' 'STEP'
        $sprava = Invoke-AccessRun $acc 'InstalacnaInicializacia' @([string]$ZdrojovaDatabaza, 1)
        $sprava -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Log ('  ' + $_) }
        if ([string]$sprava -match '^CHYBA') { Write-Log 'Inicializácia databázy skončila chybou.' 'ERR'; $kod = 1 }

        if ($zapisManifest.Count -gt 0) {
            $r = Invoke-AccessRun $acc 'ZapisManifestModulov' @(($zapisManifest -join ';'))
            Write-Log ('Evidencia verzií modulov zapísaná ({0}).' -f $r)
        }
        try { [void](Invoke-AccessRun $acc 'NastavVerziuBalika' @([string]$manifest.balik)) } catch { Write-Log ('Verziu balíka sa nepodarilo zapísať: {0}' -f $_.Exception.Message) }

        # 10) AutoExec ----------------------------------------------------------------------
        if (New-AutoExecMakro $acc) { Write-Log 'Makro AutoExec vytvorené (volá AutoExecStart).' 'OK' }
        else {
            Write-Log 'Makro AutoExec sa nepodarilo vytvoriť automaticky.' 'WARN'
            Write-Log 'Ručne: Vytvoriť > Makro > akcia SpustiťKód (RunCode) > funkcia  AutoExecStart()  > uložiť ako "AutoExec".' 'WARN'
        }

        # 11) Skúšobný štart aplikácie (to isté, čo urobí makro AutoExec pri otvorení)
        Write-Log 'Skúšobne spúšťam AutoExecStart()...' 'STEP'
        try {
            $diag = [string](Invoke-AccessRun $acc 'InstalacnyTestStartu')
            $diag -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Log ('  ' + $_) }
            if ($diag -match 'zlyhal|VBA chyba') { Write-Log 'Skúšobný štart aplikácie zlyhal - pozri riadky vyššie (a tabuľku LogImportu v databáze).' 'WARN' }
        } catch { Write-Log ('Skúšobný štart aplikácie zlyhal: {0}' -f $_.Exception.Message) 'WARN' }
        Close-VsetkyFormulare $acc
        Write-Log 'Databáza uložená.' 'OK'
    }
    catch {
        Write-Log ('Nečakaná chyba: {0}' -f $_.Exception.Message) 'ERR'
        if ($_.InvocationInfo) { Write-Log $_.InvocationInfo.PositionMessage 'ERR' }
        Write-Log 'Databáza mohla ostať rozpracovaná. Ak ide o novú databázu, zmažte ju a spustite inštalátor znova (alebo ho spustite znova nad ňou - vykoná sa aktualizácia a dokončí inicializáciu).' 'WARN'
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

    if ($kod -eq 0 -and -not $nechajOtvorene) {
        Write-Host ''
        if ($script:Varovania.Count -gt 0) { Write-Log ('Inštalácia dokončená s upozorneniami ({0}).' -f $script:Varovania.Count) 'WARN' }
        else { Write-Log 'Inštalácia dokončená.' 'OK' }
        if (-not $NeOtvarat) {
            Start-Sleep -Seconds 2
            Write-Log 'Otváram databázu...' 'STEP'
            try { Start-Process -FilePath $Cesta } catch { Write-Log ('Databázu sa nepodarilo otvoriť: {0}' -f $_.Exception.Message) 'WARN' }
        }
    }
    return $kod
}

if ($env:DOCH_INSTALATOR_TEST -ne '1') {
    $navrat = Invoke-Instalacia
    exit ([int]($navrat | Select-Object -Last 1))
}
