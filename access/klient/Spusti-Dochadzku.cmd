@echo off
rem ===========================================================================================
rem Spusti-Dochadzku.cmd - spustac klienta na razenie (bezi na pocitaci zamestnanca, bez prav spravcu).
rem   Dva miesta, odkial sa spusta:
rem   a) lokalna kopia %LOCALAPPDATA%\DochadzkaKlient\Spusti-Dochadzku.cmd (robi ju Vytvor-Odkaz.cmd, mieri
rem      na nu odkaz na ploche aj v Po spusteni): zaklad cita zo zaklad.txt, takze klient sa otvori aj
rem      ked je server nedostupny (razenia sa ulozia lokalne a odoslu neskor);
rem   b) priamo zo servera <zaklad>\klient\ (zaklad je rodic priecinka tohto suboru) - na skusku alebo
rem      pri prvom spusteni.
rem   S argumentom (napr. C:\dochadzka-test) sa klient berie z <argument>\klient\ - sluzi na skusku bez servera.
rem   Postup: 1. urci zaklad, 2. zapise cestu zakladu do zaklad.txt (UTF-8), 3. ak je na serveri nova
rem   verzia, skopiruje ju najprv pod docasnym nazvom a az potom vymeni, 4. prida lokalny priecinok medzi
rem   doveryhodne umiestnenia Accessu (HKCU), 5. otvori klienta. Cesta zakladu nesmie obsahovat
rem   znaky & ^ ! (bezne sa v cestach nevyskytuju); zatvorky v ceste su dovolene.
rem ===========================================================================================
setlocal
chcp 65001 >nul 2>&1
title Dochadzka - spustanie

if not defined LOCALAPPDATA goto :BezLokalneho
set "LOK=%LOCALAPPDATA%\DochadzkaKlient"
set "ACC=DochadzkaKlient.accdb"

rem --- 1. zaklad a priecinok klienta na serveri -----------------------------------------------
set "ZAKLAD="
set "SRC="
set "LOKALNY="
if /i "%~dp0"=="%LOK%\" set "LOKALNY=1"
if not "%~1"=="" goto :ZakladZArgumentu
if defined LOKALNY goto :ZakladZoSuboru
for %%I in ("%~dp0..") do set "ZAKLAD=%%~fI"
for %%I in ("%~dp0.") do set "SRC=%%~fI"
goto :ZakladHotovy

:ZakladZArgumentu
for %%I in ("%~f1") do set "ZAKLAD=%%~fI"
goto :ZakladHotovy

:ZakladZoSuboru
if not exist "%LOK%\zaklad.txt" goto :BezZakladu
set /p ZAKLAD=<"%LOK%\zaklad.txt"
if not defined ZAKLAD goto :BezZakladu

:ZakladHotovy
if "%ZAKLAD:~-1%"=="\" if not "%ZAKLAD:~1%"==":\" set "ZAKLAD=%ZAKLAD:~0,-1%"
if not defined SRC set "SRC=%ZAKLAD%\klient"

pushd "%~dp0" >nul 2>&1

if not exist "%LOK%\" mkdir "%LOK%" >nul 2>&1
if exist "%LOK%\" goto :LokalnyOk
echo Nepodarilo sa vytvorit lokalny priecinok klienta. Obratte sa na IT.
pause
exit /b 1

:LokalnyOk
rem spustac.log sa pri velkosti nad 200 kB odlozi do spustac.old (stary .old sa prepise)
if exist "%LOK%\spustac.log" for %%F in ("%LOK%\spustac.log") do if %%~zF GTR 200000 move /y "%LOK%\spustac.log" "%LOK%\spustac.old" >nul 2>&1
call :Log "spustenie, zaklad %ZAKLAD%"

rem --- 2. zaklad.txt (len ak sa lisi) ---------------------------------------------------------
set "AKT="
if exist "%LOK%\zaklad.txt" set /p AKT=<"%LOK%\zaklad.txt"
if /i "%AKT%"=="%ZAKLAD%" goto :Aktualizacia
>"%LOK%\zaklad.txt" echo(%ZAKLAD%
call :Log "zaklad.txt zapisany"

rem --- 3. aktualizacia klienta zo servera -----------------------------------------------------
:Aktualizacia
if exist "%SRC%\%ACC%" goto :ServerMaKlienta
call :Log "server nedostupny alebo bez klienta"
goto :Doveryhodne

:ServerMaKlienta
if not exist "%LOK%\%ACC%" goto :Kopiruj
rem bez verzia.txt na serveri nie je s cim porovnat: lokalny klient sa nechava
if not exist "%SRC%\verzia.txt" goto :Doveryhodne
fc /b "%SRC%\verzia.txt" "%LOK%\verzia.txt" >nul 2>&1
if errorlevel 1 goto :Kopiruj
goto :Doveryhodne

:Kopiruj
del /q "%LOK%\%ACC%.new" >nul 2>&1
copy /y "%SRC%\%ACC%" "%LOK%\%ACC%.new" >nul 2>&1
if not errorlevel 1 goto :Vymen
call :Log "kopirovanie klienta zlyhalo, ostava stara verzia"
del /q "%LOK%\%ACC%.new" >nul 2>&1
goto :Doveryhodne

:Vymen
move /y "%LOK%\%ACC%.new" "%LOK%\%ACC%" >nul 2>&1
if not errorlevel 1 goto :Vymenene
call :Log "vymena klienta zlyhala (subor je otvoreny), ostava stara verzia"
del /q "%LOK%\%ACC%.new" >nul 2>&1
goto :Doveryhodne

:Vymenene
copy /y "%SRC%\verzia.txt" "%LOK%\verzia.txt" >nul 2>&1
call :Log "klient aktualizovany"

rem --- 4. doveryhodne umiestnenie pre Access (bez prav spravcu, len HKCU) --------------------
:Doveryhodne
set "NASLO="
for %%V in (14.0 15.0 16.0) do call :Umiestnenie %%V
rem cisty profil bez spusteneho Accessu nema kluc v HKCU: ak sa nenasla ziadna verzia, pouzije sa 16.0
if not defined NASLO call :Pridaj 16.0

rem --- 5. otvorenie klienta -------------------------------------------------------------------
if not exist "%LOK%\%ACC%" goto :BezKlienta
start "" "%LOK%\%ACC%"
popd >nul 2>&1
exit /b 0

:BezKlienta
echo.
echo Klient nie je nainstalovany a server je nedostupny. Obratte sa na IT.
call :Log "klient chyba a server je nedostupny"
pause
popd >nul 2>&1
exit /b 1

:BezLokalneho
echo Nepodarilo sa zistit lokalny priecinok pouzivatela. Obratte sa na IT.
pause
exit /b 1

:BezZakladu
echo.
echo Nie je znama cesta k serveru. Spustite raz subor Vytvor-Odkaz.cmd
echo z priecinka klient na serveri a potom pouzite novy odkaz Dochadzka.
pause
exit /b 1

rem Kluc Accessu danej verzie Office: v HKCU (Access uz bezal) alebo v HKLM (Access je nainstalovany; aj 32-bitovy na 64-bitovom).
:Umiestnenie
set "MA="
reg query "HKCU\Software\Microsoft\Office\%1\Access" >nul 2>&1
if not errorlevel 1 set "MA=1"
reg query "HKLM\SOFTWARE\Microsoft\Office\%1\Access\InstallRoot" >nul 2>&1
if not errorlevel 1 set "MA=1"
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Office\%1\Access\InstallRoot" >nul 2>&1
if not errorlevel 1 set "MA=1"
if not defined MA exit /b 0
set "NASLO=1"
call :Pridaj %1
exit /b 0

:Pridaj
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
