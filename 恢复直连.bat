@echo off
chcp 65001 >nul
REM 强制恢复成直连(关系统代理 + 清代理环境变量 + 清孤儿 TUN 路由)。需要管理员权限。
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File','%~dp0ProxyClean.ps1','-Direct'"
