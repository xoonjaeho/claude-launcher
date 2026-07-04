@echo off
del "%TEMP%\claude_launch.bat" 2>NUL
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0claude-launcher.ps1" -FromBat
if exist "%TEMP%\claude_launch.bat" (
    call "%TEMP%\claude_launch.bat"
    del "%TEMP%\claude_launch.bat" 2>NUL
)
