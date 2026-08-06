@echo off
REM Dynamically discover system proxy endpoints, proxy-owned listeners, TUN routes, and exit paths.
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0ProxyStatus.ps1"
