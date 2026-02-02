@echo off
setlocal

REM Runs stop-all.ps1 + run-all.ps1 without loading PSReadLine.
cd /d "%~dp0.."

powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0stop-all.ps1"
if errorlevel 1 exit /b %errorlevel%

powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0run-all.ps1"
if errorlevel 1 exit /b %errorlevel%

echo.
echo Latest run id:
type "%~dp0logs\latest-run.txt"
echo.
endlocal
