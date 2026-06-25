@echo off
chcp 65001 >nul
echo ============ 兜底层 7899 当前状态 ============
echo.
echo [当前实际出口 now]  feiniao=飞鸟  tag=TAG  DIRECT=直连没走机场
curl -s -m 5 http://127.0.0.1:9899/proxies/AUTO
echo.
echo.
echo [经 7899 真实出口 IP]  海外节点IP=在翻墙  本地ISP IP=直连裸奔
curl -s -m 12 -x http://127.0.0.1:7899 https://api.ip.sb/geoip
echo.
echo ============================================
pause
