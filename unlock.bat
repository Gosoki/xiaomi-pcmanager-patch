@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0unlock.ps1" %*
if errorlevel 1 pause
