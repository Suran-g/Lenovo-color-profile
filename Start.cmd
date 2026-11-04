@echo off
setlocal
cd /d "%~dp0"

rem Launch the GUI without an extra console window hanging around.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0LenovoColorProfileGUI.ps1"

endlocal
