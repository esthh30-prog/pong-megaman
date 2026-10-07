@echo off
cd /d "%~dp0"
call build.bat || exit /b 1
start "" "%~dp0tools\Mesen\Mesen.exe" "%~dp0nesball.nes"
