@echo off
rem ===========================================================================================
rem Vytvor-Odkaz.cmd - vytvori odkaz na Spusti-Dochadzku.cmd na ploche a v priecinku Po spusteni.
rem   Spusta sa raz na pocitaci zamestnanca (netreba prava spravcu), zo servera <zaklad>\klient\.
rem   Ak je PowerShell zablokovany, vypise postup na rucne vytvorenie odkazu.
rem ===========================================================================================
setlocal
chcp 65001 >nul 2>&1
title Dochadzka - vytvorenie odkazu

set "CIEL=%~dp0Spusti-Dochadzku.cmd"
if not exist "%CIEL%" (
    echo Subor Spusti-Dochadzku.cmd sa nenasiel vedla tohto suboru.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $s = New-Object -ComObject WScript.Shell; foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) { $l = $s.CreateShortcut((Join-Path $d 'Dochadzka.lnk')); $l.TargetPath = $env:CIEL; $l.WorkingDirectory = $env:USERPROFILE; $l.WindowStyle = 7; $l.Description = 'Dochadzka - razenie'; $l.Save(); Write-Host ('Vytvoreny odkaz: ' + (Join-Path $d 'Dochadzka.lnk')) } } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :Rucne
echo.
echo Hotovo. Odkaz na ploche spusta Dochadzku; kopia v priecinku Po spusteni ju spusti po prihlaseni.
pause
exit /b 0

:Rucne
echo.
echo Odkaz sa nepodarilo vytvorit automaticky. Vytvorte ho rucne:
echo   1. Pravym tlacidlom na plochu - Novy - Odkaz.
echo   2. Ako umiestnenie zadajte: %CIEL%
echo   3. Pomenujte ho Dochadzka.
echo   4. Kopiu odkazu vlozte do priecinka Po spusteni (Win+R, napiste shell:startup).
pause
exit /b 1
