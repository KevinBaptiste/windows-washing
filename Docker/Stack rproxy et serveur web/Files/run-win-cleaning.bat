@echo off
set "SCRIPT=%USERPROFILE%\Desktop\win-wash.ps1"
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/KevinBaptiste/windows-washing/refs/heads/main/win-cleaning.ps1' -OutFile '%SCRIPT%'"
powershell -ExecutionPolicy Bypass -File "%SCRIPT%"