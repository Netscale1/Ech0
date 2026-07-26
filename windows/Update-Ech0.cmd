@echo off
setlocal

powershell.exe -NoLogo -NoProfile -ExecutionPolicy AllSigned -File "%~dp0Update-Ech0.ps1"
if errorlevel 1 (
  echo Ech0 was not updated.
  pause
  exit /b 1
)

echo Ech0 was updated and restarted.
exit /b 0
