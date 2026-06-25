<#
.SYNOPSIS
    ProxyClean —— 机场(代理)断开/切换后的网络状态清理与对齐工具
    Clean up and re-align Windows network state after a TUN-based proxy
    (clash/mihomo/sing-box style) disconnects or is switched.

.DESCRIPTION
    很多基于 TUN 的代理客户端(飞鸟 / TAG / Clash Verge 等)在退出或切换时
    "断开不干净",会留下四类残留,任何一类没清网络就废:
      1) 孤儿 TUN 默认路由   —— 指向已消失的 fake-ip 网关(198.18.x.x),流量被黑洞
      2) 系统代理指向死端口 —— WinINET ProxyServer 还指着已关闭的代理端口
      3) 环境变量指向死端口 —— HTTP_PROXY/HTTPS_PROXY 还指着死端口(Qoder/ollama 等会断网)
      4) fake-ip DNS 缓存   —— 解析结果还是 198.18.x.x

    本工具不杀进程、不改任何机场的配置、不碰 TUN 开关。它只做一件事:
    **读取当前真正在监听的机场,把系统代理 / 路由 / DNS 全部对齐到它;
    若没有任何机场在跑,则干净地恢复成直连。**

.PARAMETER Direct
    强制清理成"直连"(关闭系统代理 + 清空代理环境变量),即使有机场在监听。

.PARAMETER Quiet
    精简输出。

.EXAMPLE
    .\ProxyClean.ps1            # 自动对齐到当前在跑的机场;没有则恢复直连
    .\ProxyClean.ps1 -Direct    # 强制恢复直连
#>
[CmdletBinding()]
param(
    [switch]$Direct,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

function Info($m){ if(-not $Quiet){ Write-Host "[*] $m" -ForegroundColor Cyan } }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

# ── 机场定义:名字 -> 混合端口(mixed-port) ────────────────────────────────
# 想新增机场,在这里加一行 端口 即可(按优先级从上到下)。
$Airports = [ordered]@{
    'FlyingBird(飞鸟)' = 7892
    'TAG'              = 7890
}

function Test-PortAlive([int]$p){
    [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
}

Write-Host "==================== ProxyClean ====================" -ForegroundColor White

# ── 1) 判定目标:直连 / 某个在跑的机场 ───────────────────────────────────
$targetName = $null; $targetPort = $null
if($Direct){
    Info "模式:强制直连"
} else {
    foreach($name in $Airports.Keys){
        if(Test-PortAlive $Airports[$name]){ $targetName=$name; $targetPort=$Airports[$name]; break }
    }
    if($targetPort){ Info "检测到在跑的机场:$targetName (127.0.0.1:$targetPort)" }
    else { Info "没有任何机场在监听 -> 目标:直连" }
}

# ── 2) 清理孤儿 TUN 默认路由 ─────────────────────────────────────────────
# 规则:删掉 [所在网卡已 Down] 或 [直连模式下指向 fake-ip(198.18/198.19) 的网关] 的 0.0.0.0/0。
# 正在使用、且网卡 Up 的机场 TUN 路由会被保留(TUN 都要,不动它)。
$removed = 0
foreach($r in (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)){
    $ad = Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction SilentlyContinue
    $adapterDown = ($ad -and $ad.Status -ne 'Up')
    $isFakeip    = ($r.NextHop -match '^198\.1[89]\.')
    $kill = $false
    if($adapterDown){ $kill = $true; $why = "网卡已 Down(黑洞)" }
    elseif($isFakeip -and ($targetPort -eq $null)){ $kill = $true; $why = "直连模式下残留的 fake-ip TUN 路由" }
    if($kill){
        try { Remove-NetRoute -InputObject $r -Confirm:$false -ErrorAction Stop
              Ok "移除默认路由 via $($r.NextHop) ($($r.InterfaceAlias)) —— $why"; $removed++ }
        catch { Warn "无法移除 via $($r.NextHop):$($_.Exception.Message)(需要管理员权限?)" }
    }
}
if($removed -eq 0){ Info "没有需要清理的孤儿路由" }

# ── 健全性检查:确保还有物理默认路由 ─────────────────────────────────────
$phys = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and ((Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).Status -eq 'Up') }
if(-not $phys){ Warn "当前没有可用的默认路由!请检查物理网络(WLAN/以太网)是否已连接。" }

# ── 3) 对齐系统代理(WinINET) + 环境变量 ────────────────────────────────
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$envVars = 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy'
if($targetPort){
    $proxy = "127.0.0.1:$targetPort"
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $reg -Name ProxyServer -Value $proxy -ErrorAction SilentlyContinue
    foreach($v in $envVars){ [Environment]::SetEnvironmentVariable($v, "http://$proxy", 'User') }
    Ok "系统代理 + 环境变量 -> http://$proxy"
} else {
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    foreach($v in $envVars){ [Environment]::SetEnvironmentVariable($v, $null, 'User') }
    Ok "已关闭系统代理 + 清空代理环境变量(直连)"
}
# 注:NO_PROXY 保持不变(里面有 aliyun 等白名单),不动。

# ── 3b) 对齐 git 代理(git 不读环境变量,有自己的 http.proxy 配置)──────────
$git = Get-Command git -ErrorAction SilentlyContinue
if($git){
    if($targetPort){
        & git config --global http.proxy  "http://127.0.0.1:$targetPort" 2>$null
        & git config --global https.proxy "http://127.0.0.1:$targetPort" 2>$null
        Ok "git 代理 -> http://127.0.0.1:$targetPort"
    } else {
        & git config --global --unset http.proxy  2>$null
        & git config --global --unset https.proxy 2>$null
        Ok "已清除 git 代理(直连)"
    }
}

# ── 4) 刷新 DNS + 通知 WinINET 设置已变 ──────────────────────────────────
try { ipconfig /flushdns | Out-Null; Ok "已刷新 DNS 缓存" } catch {}
try {
    if(-not ([System.Management.Automation.PSTypeName]'WinINet.NativeMethods').Type){
        Add-Type -Namespace WinINet -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(System.IntPtr h, int opt, System.IntPtr buf, int len);
"@
    }
    [WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null # SETTINGS_CHANGED
    [WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null # REFRESH
    Info "已通知系统刷新代理设置"
} catch {}

# ── 5) 验证连通性 + 打印最终状态 ─────────────────────────────────────────
Start-Sleep -Seconds 2
Write-Host "-------------------- 验证 --------------------" -ForegroundColor White
$testUrl = 'https://www.google.com/generate_204'
try {
    if($targetPort){ $r = Invoke-WebRequest $testUrl -Proxy "http://127.0.0.1:$targetPort" -UseBasicParsing -TimeoutSec 12 }
    else           { $r = Invoke-WebRequest 'https://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 12 }
    Ok ("连通性测试通过 (HTTP {0}) {1}" -f $r.StatusCode, $(if($targetPort){"via 127.0.0.1:$targetPort"}else{"直连"}))
} catch {
    Warn ("连通性测试失败:{0}" -f $_.Exception.Message)
    if($targetPort){ Warn "机场端口在监听但出口不通 —— 可能是该机场额度满/节点挂了,换一个机场再跑本工具。" }
}
Write-Host "当前默认路由:" -ForegroundColor White
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Format-Table @{N='接口';E={$_.InterfaceAlias}}, @{N='网关';E={$_.NextHop}}, RouteMetric -AutoSize
Write-Host "====================================================" -ForegroundColor White
