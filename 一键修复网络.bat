@echo off
chcp 65001 >nul
REM 自动对齐到当前在跑的机场;没有机场则恢复直连。需要管理员权限(改路由)。
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0ProxyClean.ps1'"
