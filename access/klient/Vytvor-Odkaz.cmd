@echo off
rem ===========================================================================================
rem Vytvor-Odkaz.cmd - pripravi spustanie klienta na tomto pocitaci: skopiruje Spusti-Dochadzku.cmd do
rem   %LOCALAPPDATA%\DochadzkaKlient\, zapise tam cestu k serveru (zaklad.txt) a vytvori odkaz na ploche
rem   a v priecinku Po spusteni, ktory mieri na LOKALNU kopiu. Vdaka tomu sa klient otvori aj vtedy, ked
rem   je server nedostupny (razenia sa ulozia lokalne a odoslu neskor).
rem   Spusta sa raz na pocitaci zamestnanca (netreba prava spravcu), zo servera <zaklad>\klient\.
rem   Ak sa spustac na serveri zmeni, spustite subor znova. Ak je PowerShell zablokovany, vypise postup
rem   na rucne vytvorenie odkazu.
rem ===========================================================================================
setlocal
chcp 65001 >nul 2>&1
title Dochadzka - vytvorenie odkazu

set "ZDROJ=%~dp0Spusti-Dochadzku.cmd"
if exist "%ZDROJ%" goto :MaZdroj
echo Subor Spusti-Dochadzku.cmd sa nenasiel vedla tohto suboru.
pause
exit /b 1

:MaZdroj
if defined LOCALAPPDATA goto :MaLokalny
echo Nepodarilo sa zistit lokalny priecinok pouzivatela. Obratte sa na IT.
pause
exit /b 1

:MaLokalny
set "LOK=%LOCALAPPDATA%\DochadzkaKlient"
if not exist "%LOK%\" mkdir "%LOK%" >nul 2>&1
if exist "%LOK%\" goto :LokalnyOk
echo Nepodarilo sa vytvorit lokalny priecinok klienta. Obratte sa na IT.
pause
exit /b 1

:LokalnyOk
if /i "%~dp0"=="%LOK%\" goto :ZLokalneho
set "CIEL=%LOK%\Spusti-Dochadzku.cmd"
rem zaklad = rodic priecinka tohto suboru (priecinok klient na serveri)
for %%I in ("%~dp0..") do set "ZAKLAD=%%~fI"
if "%ZAKLAD:~-1%"=="\" if not "%ZAKLAD:~1%"==":\" set "ZAKLAD=%ZAKLAD:~0,-1%"
copy /y "%ZDROJ%" "%CIEL%" >nul 2>&1
if not errorlevel 1 goto :Skopirovane
echo Nepodarilo sa skopirovat spustac do lokalneho priecinka. Obratte sa na IT.
pause
exit /b 1

:ZLokalneho
echo Spustite Vytvor-Odkaz.cmd z priecinka klient na serveri, nie z lokalneho priecinka.
pause
exit /b 1

:Skopirovane
>"%LOK%\zaklad.txt" echo(%ZAKLAD%

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $s = New-Object -ComObject WScript.Shell; foreach ($d in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup'))) { $l = $s.CreateShortcut((Join-Path $d 'Dochadzka.lnk')); $l.TargetPath = $env:CIEL; $l.WorkingDirectory = $env:USERPROFILE; $l.WindowStyle = 7; $l.Description = 'Dochadzka - razenie'; $l.Save(); Write-Host ('Vytvoreny odkaz: ' + (Join-Path $d 'Dochadzka.lnk')) } } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 goto :Rucne
echo.
echo Hotovo. Odkaz na ploche spusta Dochadzku; kopia v priecinku Po spusteni ju spusti po prihlaseni.
echo Odkaz mieri na lokalnu kopiu spustaca, takze funguje aj pri vypadku servera.
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
