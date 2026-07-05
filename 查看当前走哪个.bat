@echo off
REM Show 18090/7892/18091 listener, proxy settings, routes, and exit IP comparison.
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0ProxyStatus.ps1"
