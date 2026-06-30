@echo off
REM Force-stop the process listening on 127.0.0.1:7897 and clean proxy leftovers.
REM Needs admin because route cleanup may require it.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0Stop-ProxyPort.ps1','-Port','7897','-Label','ClashVerge-7897'"
