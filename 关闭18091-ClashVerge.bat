@echo off
powershell.exe -NoLogo -NoProfile -File "%~dp0Launch-ProxyClean.ps1" -Action StopPort -Port 18091 -ExpectedClient ClashVerge
