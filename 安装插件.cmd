@echo off
chcp 65001 >nul
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher\install_extension.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (
  echo [DONE] Extension is loaded and connected. AI can drive this browser now.
) else if "%RC%"=="3" (
  echo [CANCELLED] Nothing was changed.
) else (
  echo [EXIT %RC%] See the messages above, or run check_extension.ps1 to re-check.
)
echo.
pause
endlocal & exit /b %RC%
