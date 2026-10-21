@echo off
setlocal
set "ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%launcher\stop.ps1" -StopBridge %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
