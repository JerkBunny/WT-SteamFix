@echo off
chcp 65001 >nul
title War Thunder Steam Fix Tool
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WT-SteamFix.ps1" %*
set RC=%ERRORLEVEL%
popd
if not "%RC%"=="0" (
  echo.
  echo [tool exited with code %RC%] see the logs folder for details.
  pause
)
