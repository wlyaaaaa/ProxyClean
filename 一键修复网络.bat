@echo off
REM Auto-fix network: align to the running airport, or restore direct if none. Needs admin (route changes).
REM ASCII-only on purpose so cmd never mis-parses it. Elevated window stays open (-NoExit) to show results.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0ProxyClean.ps1'"
