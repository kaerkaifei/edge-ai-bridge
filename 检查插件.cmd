@echo off
chcp 65001 >nul
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\check_extension.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="2"  echo [MISSING] Extension is NOT loaded in the target browser. Run the install script in this folder.
if "%RC%"=="1"  echo [ERROR]   Environment problem, see hints above.
if "%RC%"=="0"  echo [READY]   Extension loaded and bridge connected.
echo.
pause
endlocal & exit /b %RC%
