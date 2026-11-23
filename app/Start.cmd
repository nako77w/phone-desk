@echo off
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0PhoneDesk.ps1"
if errorlevel 1 pause
