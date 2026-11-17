@echo off
rem ===========================================================================================
rem Spusti-Dochadzku.cmd - spustac klienta na razenie (bezi na pocitaci zamestnanca, bez prav spravcu).
rem   Umiestnenie: <zaklad>\klient\ na serveri. Pouzitie: Spusti-Dochadzku.cmd [zakladny priecinok]
rem   Bez argumentu je zaklad rodic priecinka tohto suboru. S argumentom (napr. C:\dochadzka-test)
rem   sa klient berie z <argument>\klient\ - sluzi na skusku bez servera.
rem   Postup: 1. zapise cestu zakladu do zaklad.txt (UTF-8), 2. ak je na serveri nova verzia,
rem   skopiruje ju najprv pod docasnym nazvom a az potom vymeni, 3. prida lokalny priecinok medzi
rem   doveryhodne umiestnenia Accessu (HKCU), 4. otvori klienta. Cesta zakladu nesmie obsahovat
rem   znaky & ^ ! (bezne sa v cestach nevyskytuju).
rem ===========================================================================================
setlocal
chcp 65001 >nul 2>&1
title Dochadzka - spustanie

if not defined LOCALAPPDATA (
    echo Nepodarilo sa zistit lokalny priecinok pouzivatela. Obratte sa na IT.
    pause
    exit /b 1
)
set "LOK=%LOCALAPPDATA%\DochadzkaKlient"
set "ACC=DochadzkaKlient.accdb"

rem --- 1. zaklad a priecinok klienta na serveri -----------------------------------------------
if not "%~1"=="" (
    for %%I in ("%~f1") do set "ZAKLAD=%%~fI"
) else (
    for %%I in ("%~dp0..") do set "ZAKLAD=%%~fI"
)
if "%ZAKLAD:~-1%"=="\" if not "%ZAKLAD:~1%"==":\" set "ZAKLAD=%ZAKLAD:~0,-1%"
set "SRC=%ZAKLAD%\klient"
if "%~1"=="" for %%I in ("%~dp0.") do set "SRC=%%~fI"

pushd "%~dp0" >nul 2>&1

if not exist "%LOK%\" mkdir "%LOK%" >nul 2>&1
if not exist "%LOK%\" (
    echo Nepodarilo sa vytvorit priecinok %LOK%. Obratte sa na IT.
    pause
    exit /b 1
)
call :Log "spustenie, zaklad %ZAKLAD%"

rem --- 2. zaklad.txt (len ak sa lisi) ---------------------------------------------------------
set "AKT="
if exist "%LOK%\zaklad.txt" set /p AKT=<"%LOK%\zaklad.txt"
if /i not "%AKT%"=="%ZAKLAD%" (
    >"%LOK%\zaklad.txt" echo(%ZAKLAD%
    call :Log "zaklad.txt zapisany"
)

rem --- 3. aktualizacia klienta zo servera -----------------------------------------------------
if not exist "%SRC%\%ACC%" (
    call :Log "server nedostupny alebo bez klienta"
    goto :Doveryhodne
)
set "TREBA="
if not exist "%LOK%\%ACC%" set "TREBA=1"
fc /b "%SRC%\verzia.txt" "%LOK%\verzia.txt" >nul 2>&1
if errorlevel 1 set "TREBA=1"
if not defined TREBA goto :Doveryhodne

del /q "%LOK%\%ACC%.new" >nul 2>&1
copy /y "%SRC%\%ACC%" "%LOK%\%ACC%.new" >nul 2>&1
if errorlevel 1 (
    call :Log "kopirovanie klienta zlyhalo, ostava stara verzia"
    del /q "%LOK%\%ACC%.new" >nul 2>&1
    goto :Doveryhodne
)
move /y "%LOK%\%ACC%.new" "%LOK%\%ACC%" >nul 2>&1
if errorlevel 1 (
    call :Log "vymena klienta zlyhala (subor je otvoreny), ostava stara verzia"
    del /q "%LOK%\%ACC%.new" >nul 2>&1
    goto :Doveryhodne
)
copy /y "%SRC%\verzia.txt" "%LOK%\verzia.txt" >nul 2>&1
call :Log "klient aktualizovany"

rem --- 4. doveryhodne umiestnenie pre Access (bez prav spravcu, len HKCU) --------------------
:Doveryhodne
for %%V in (14.0 15.0 16.0) do call :Umiestnenie %%V

rem --- 5. otvorenie klienta -------------------------------------------------------------------
if exist "%LOK%\%ACC%" (
    start "" "%LOK%\%ACC%"
    popd >nul 2>&1
    exit /b 0
)
echo.
echo Klient nie je nainstalovany a server je nedostupny. Obratte sa na IT.
call :Log "klient chyba a server je nedostupny"
pause
popd >nul 2>&1
exit /b 1

:Umiestnenie
reg query "HKCU\Software\Microsoft\Office\%1\Access" >nul 2>&1
if errorlevel 1 exit /b 0
set "KLUC=HKCU\Software\Microsoft\Office\%1\Access\Security\Trusted Locations\DochadzkaKlient"
reg query "%KLUC%" /v Path >nul 2>&1
if not errorlevel 1 exit /b 0
reg add "%KLUC%" /v Path /t REG_SZ /d "%LOK%\\" /f >nul 2>&1
reg add "%KLUC%" /v AllowSubfolders /t REG_DWORD /d 1 /f >nul 2>&1
reg add "%KLUC%" /v Description /t REG_SZ /d "Dochadzka klient" /f >nul 2>&1
call :Log "doveryhodne umiestnenie pridane (Office %1)"
exit /b 0

:Log
>>"%LOK%\spustac.log" echo %date% %time% %~1
exit /b 0
