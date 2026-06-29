@echo off
REM Force restore DIRECT connection (close system proxy + clear dead-port proxy env + clear orphan TUN routes). Needs admin.
REM ASCII-only on purpose so cmd never mis-parses it. Elevated window stays open (-NoExit) to show results.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0ProxyClean.ps1','-Direct'"
