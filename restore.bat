@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unlock.ps1" -Action Restore
if errorlevel 1 pause
