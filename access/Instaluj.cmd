@echo off
chcp 65001 >nul
title Instalator dochadzkoveho systemu
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instaluj-Dochadzku.ps1" %*
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Instalacia skoncila s kodom %RC% (pozri protokol instalacia_*.log v priecinku databazy).
pause
exit /b %RC%
