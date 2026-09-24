@echo off
setlocal
set "PS1=%~dp0script.ps1"
if not exist "%PS1%" (
    echo Fix-MSIX.ps1 not found next to this .bat file.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS1%\"'"
endlocal