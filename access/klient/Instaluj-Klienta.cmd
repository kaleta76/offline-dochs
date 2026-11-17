@echo off
chcp 65001 >nul
title Zostavovac klienta na razenie
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instaluj-Klienta.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Zostavenie skoncilo s kodom %RC% (pozri protokol instalacia_klient_*.log vo vystupnom priecinku).
pause
exit /b %RC%
