@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Launch-ProxyClean.ps1" -Action StopPort -Port 18091 -ExpectedClient ClashVerge
