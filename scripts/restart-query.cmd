@echo off
setlocal

cd /d "%~dp0.."
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0restart-query.ps1"
exit /b %errorlevel%

endlocal
