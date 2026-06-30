@echo off
REM Show 7892/7897 listener, proxy settings, routes, and exit IP comparison.
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0ProxyStatus.ps1"
