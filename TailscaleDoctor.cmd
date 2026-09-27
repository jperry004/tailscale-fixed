@echo off
rem Tailscale Doctor launcher: double-click this file.
rem Uses the built-in 64-bit Windows PowerShell; asks for Administrator rights.
setlocal
title Tailscale Doctor
cd /d "%~dp0"

if not exist "%~dp0TailscaleDoctor.ps1" (
  echo TailscaleDoctor.ps1 is missing. Extract the whole folder, not just this file.
  pause
  exit /b 1
)
if not exist "%~dp0web\app.js" (
  echo The "web" folder is missing. Extract the whole folder, not just this file.
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0TailscaleDoctor.ps1" %*
if errorlevel 1 (
  echo.
  echo Tailscale Doctor exited with an error. See the messages above.
  pause
)
