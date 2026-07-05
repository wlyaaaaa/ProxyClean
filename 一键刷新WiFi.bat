@echo off
chcp 65001 >nul
title 一键刷新 WiFi 网络
echo.
echo 正在轻量刷新 WiFi 网络...
echo 会执行: 清空 DNS 缓存、释放并重新获取 WiFi 地址。
echo 不会修改代理、不会改 DNS、不会删除路由。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0WifiRebind.ps1" -Mode SoftReset
