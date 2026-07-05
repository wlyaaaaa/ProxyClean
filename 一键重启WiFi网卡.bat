@echo off
chcp 65001 >nul
title 一键重启 WiFi 网卡
echo.
echo 正在请求管理员权限，准备重启 WiFi 网卡...
echo 这个动作最接近“切到手机热点，再切回 WiFi”。
echo 会短暂断开 WiFi，然后自动连回。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0WifiRebind.ps1','-Mode','AdapterReset'"
