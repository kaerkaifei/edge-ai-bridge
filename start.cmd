@echo off
setlocal enabledelayedexpansion
set "ROOT=%~dp0"

rem 没装 python 时，退一步找 uv 管理的 CPython（很多机器上只有这个）
where python >nul 2>nul
if errorlevel 1 (
  set "PYDIR="
  for /d %%D in ("%USERPROFILE%\AppData\Roaming\uv\python\cpython-*") do (
    if exist "%%D\pythonw.exe" if not defined PYDIR set "PYDIR=%%D"
  )
  if not defined PYDIR (
    for /d %%D in ("%USERPROFILE%\AppData\Roaming\uv\python\cpython-*") do (
      if exist "%%D\python.exe" if not defined PYDIR set "PYDIR=%%D"
    )
  )
  if defined PYDIR set "PATH=!PYDIR!;%PATH%"
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%launcher\launch_hidden.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
