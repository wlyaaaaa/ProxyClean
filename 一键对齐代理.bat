@echo off
REM Align user-level HTTP_PROXY/HTTPS_PROXY environment variables to the currently running airport.
REM No administrator privileges required. The window will stay open to show the result.
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Set-AirportProxy.ps1"
