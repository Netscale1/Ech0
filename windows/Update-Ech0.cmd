@echo off
setlocal

set "SOURCE=%~dp0Ech0Windows.exe"
set "INSTALL_DIR=%LOCALAPPDATA%\Ech0"
set "TARGET=%INSTALL_DIR%\Ech0Windows.exe"

if not exist "%SOURCE%" (
  echo Ech0Windows.exe was not found next to this updater.
  pause
  exit /b 1
)

taskkill /IM Ech0Windows.exe /F >nul 2>&1
timeout /t 2 /nobreak >nul

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
copy /Y "%SOURCE%" "%TARGET%" >nul
if errorlevel 1 (
  echo Ech0 could not be updated.
  pause
  exit /b 1
)

start "" "%TARGET%"
echo Ech0 was updated and restarted.
timeout /t 3 /nobreak >nul
