@echo off
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/KevinBaptiste/windows-washing/refs/heads/main/washing.ps1' -OutFile '%USERPROFILE%\Desktop\wash.ps1'"
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\Desktop\wash.ps1"