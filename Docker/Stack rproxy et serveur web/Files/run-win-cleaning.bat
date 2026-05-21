@REM CE SCRIPT .BAT PERMET LE DL DU PS1 ET SON LANCEMENT AVEC POWERSHELL
@echo off
set "SCRIPT=%USERPROFILE%\Desktop\win-cleaning.ps1"
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/KevinBaptiste/windows-washing/refs/heads/main/win-cleaning.ps1' -OutFile '%SCRIPT%'"
powershell -ExecutionPolicy Bypass -File "%SCRIPT%"