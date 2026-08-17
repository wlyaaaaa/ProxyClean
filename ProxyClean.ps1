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

    本工具不杀进程、不改任何机场的配置、不碰 TUN 开关。
    【安全版原则 —— 绝不把"持久设置"焊到一个会消失的端口上】
      1) 环境变量 HTTP_PROXY/HTTPS_PROXY 与 git 代理:只会被【清成直连】,永不指向某端口
         (这是"机场一关,命令行/Claude Code/git 全断"的根因,旧版恰恰会主动制造它)。
      2) 系统代理(WinINET):机场在跑时由机场自己维护,本工具不抢;仅当它指向的
         【本地端口已死】(断网元凶)或加 -Direct 时,才关掉它恢复直连。
      3) 清孤儿路由带硬保护:若当前没有任何健康的物理默认路由,则【不删除任何路由】,
         绝不会再像旧版那样误删 WLAN/以太网,把你彻底搞断网。

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

# ── C++/Win32 PInvoke 声明(用于快速非阻塞广播环境变量变更) ───────────────────────
$User32Sig = @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd,
    uint Msg,
    System.IntPtr wParam,
    string lParam,
    uint fuFlags,
    uint uTimeout,
    out System.IntPtr lpdwResult
);
'@

if (-not ([System.Management.Automation.PSTypeName]'User32.NativeMethods').Type) {
    Add-Type -Namespace User32 -Name NativeMethods -MemberDefinition $User32Sig
}

function Set-UserEnvFast([string]$name, [string]$value){
    $regPath = "HKCU:\Environment"
    if ($value -eq $null -or $value -eq "") {
        if (Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty -Path $regPath -Name $name -Value $value -Type String
    }
}

function Broadcast-EnvChange(){
    $result = [IntPtr]::Zero
    # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x001A, SMTO_ABORTIFHUNG = 0x0002, timeout = 200ms
    [User32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, "Environment", 2, 200, [ref]$result) | Out-Null
}

function Test-PortAlive([int]$p){
    try {
        # 只把本机回环/通配地址上的监听视为本地代理。仅端口相同但绑定在其他网卡上，
        # 并不代表 127.0.0.1:<port> 可用。
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return [bool]($listeners | Where-Object {
            $_.Port -eq $p -and (
                [Net.IPAddress]::IsLoopback($_.Address) -or
                $_.Address.Equals([Net.IPAddress]::Any) -or
                $_.Address.Equals([Net.IPAddress]::IPv6Any)
            )
        })
    } catch {
        return [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::') })
    }
}

function Get-ProxyEndpoints([string]$value){
    if([string]::IsNullOrWhiteSpace($value)){ return @() }

    @(
        foreach($rawPart in ($value -split ';')){
            $part = $rawPart.Trim()
            if(-not $part){ continue }

            # WinINET 可使用 http=host:port;https=host:port，环境变量通常是 URI。
            $endpoint = if($part -match '^[a-z][a-z0-9+.-]*=(.*)$'){
                $Matches[1].Trim()
            } else {
                $part
            }
            if(-not $endpoint){
                [pscustomobject]@{ parsed=$false; local=$false; host=$null; port=$null }
                continue
            }

            $candidate = if($endpoint -match '^[a-z][a-z0-9+.-]*://'){
                $endpoint
            } else {
                'http://' + $endpoint
            }
            [Uri]$uri = $null
            if([Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -and
               -not [string]::IsNullOrWhiteSpace($uri.Host) -and
               $uri.Port -ge 1 -and $uri.Port -le 65535){
                $endpointHost = ([string]$uri.Host).Trim([char[]]@('[', ']'))
                [Net.IPAddress]$endpointAddress = $null
                $isLocal = $endpointHost -ieq 'localhost'
                if([Net.IPAddress]::TryParse($endpointHost, [ref]$endpointAddress)){
                    $isLocal = $endpointAddress.Equals([Net.IPAddress]::Loopback) -or
                        $endpointAddress.Equals([Net.IPAddress]::IPv6Loopback)
                }
                [pscustomobject]@{ parsed=$true; local=$isLocal; host=$endpointHost; port=[int]$uri.Port }
            } else {
                [pscustomobject]@{ parsed=$false; local=$false; host=$null; port=$null }
            }
        }
    )
}

function Get-LocalProxyPorts([string]$value){
    @(Get-ProxyEndpoints $value |
        Where-Object { $_.parsed -and $_.local } |
        Select-Object -ExpandProperty port -Unique)
}

function Get-ListenerOwnerName([int]$port){
    $connections = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    $names = @($connections | ForEach-Object {
        (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
    } | Where-Object { $_ } | Select-Object -Unique)
    if($names.Count -gt 0){ return ($names -join ' / ') }
    return "local-proxy:$port"
}

Write-Host "==================== ProxyClean ====================" -ForegroundColor White

# ── 1) 判定目标:直连 / 当前系统代理 / 活动 TUN ───────────────────────────
# 不维护任何客户端固定端口表。普通代理模式以客户端当前发布的 WinINET
# 端点为准；TUN 模式以仍然 Up 的 fake-ip 默认路由为准。
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$pp = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
$adMap = @{}
foreach($ad in $adapters){
    if($null -ne $ad.InterfaceIndex){ $adMap[$ad.InterfaceIndex] = $ad }
}
$allDef = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$activeTunRoutes = @($allDef | Where-Object {
    $_.NextHop -match '^198\.1[89]\.' -and
    $adMap[$_.ifIndex] -and
    $adMap[$_.ifIndex].Status -eq 'Up'
})
$publishedPorts = if($pp -and [int]$pp.ProxyEnable -eq 1){
    @(Get-LocalProxyPorts ([string]$pp.ProxyServer))
} else { @() }
$livePublishedPorts = @($publishedPorts | Where-Object { Test-PortAlive $_ })

$targetName = $null; $targetPort = $null; $targetActive = $false
if($Direct){
    Info "模式:强制直连"
} else {
    if($livePublishedPorts.Count -gt 0){
        $targetPort = [int]$livePublishedPorts[0]
        $targetName = Get-ListenerOwnerName $targetPort
        $targetActive = $true
        Info "检测到活动系统代理:$targetName (127.0.0.1:$targetPort)"
    }
    if($activeTunRoutes.Count -gt 0){
        $tunNames = @($activeTunRoutes.InterfaceAlias | Select-Object -Unique)
        $targetActive = $true
        if($targetName){
            Warn ("同时存在系统代理和活动 TUN({0});本工具只清死端口,不会替你选择或关闭客户端。" -f ($tunNames -join ' / '))
        }
        else {
            $targetName = 'TUN:' + ($tunNames -join ' / ')
            Info "检测到活动 TUN:$($tunNames -join ' / ')"
        }
    }
    if(-not $targetActive){ Info "没有活动系统代理或 TUN -> 目标:直连" }
}

Write-Host "-------------------- 结论 --------------------" -ForegroundColor White
if($Direct){
    Write-Host "本次将强制恢复直连:关闭系统代理、清空代理环境变量,并清理残留路由/DNS。" -ForegroundColor Yellow
} elseif($targetActive){
    $endpointText = if($targetPort){ " (127.0.0.1:$targetPort)" } else { '' }
    Write-Host "本次目标:保留正在运行的 $targetName$endpointText,只清理死端口和残留项。" -ForegroundColor Green
} else {
    Write-Host "本次目标:没有检测到活机场,将按直连状态清理死端口和残留项。" -ForegroundColor Yellow
}
Write-Host "-------------------- 详细输出 --------------------" -ForegroundColor White

# ── 2) 清理孤儿 TUN 默认路由 ─────────────────────────────────────────────
# 安全规则(只删黑洞,绝不把你弄断网):
#   • 只删"黑洞"默认路由:NextHop 是 fake-ip(198.18/198.19)、或所在网卡已 Down/已消失。
#   • 绝不碰"健康的物理默认路由"(网卡 Up + 真实网关,如 WLAN/以太网)。
#   • 正在用、网卡 Up 的机场 TUN 路由(fake-ip)会被保留 —— 仅在"直连模式"下才清它。
#   • 【硬保护】若当前一条健康物理默认路由都没有,则本次【不删任何路由】并告警 ——
#     此时删任何东西都可能让你彻底断网(这正是旧版误删 WLAN 路由、要重置网络的根因)。
# 网卡和默认路由已在目标判定阶段读取一次，避免重复 WMI/CIM 查询。

function Test-HealthyPhysRoute($r){
    $ad = $adMap[$r.ifIndex]
    return ($ad -and $ad.Status -eq 'Up') -and ($r.NextHop -ne '0.0.0.0') -and ($r.NextHop -notmatch '^198\.1[89]\.')
}
$healthy = @($allDef | Where-Object { Test-HealthyPhysRoute $_ })
$removed = 0
if($healthy.Count -lt 1){
    Warn "未找到任何健康的物理默认路由 —— 为避免把你彻底搞断网,本次不删除任何路由。"
    Warn "请先确认 WLAN/以太网已连上,再重跑本工具。"
} else {
    foreach($r in $allDef){
        if(Test-HealthyPhysRoute $r){ continue }   # 健康物理路由:绝不碰
        $ad = $adMap[$r.ifIndex]
        $isFakeip = ($r.NextHop -match '^198\.1[89]\.')
        $kill = $false; $why = ''
        if(-not $ad)                { $kill = $true; $why = "网卡已消失(残留路由)" }
        elseif($ad.Status -ne 'Up') { $kill = $true; $why = "网卡已 Down(黑洞)" }
        elseif($isFakeip -and (-not $targetActive)){ $kill = $true; $why = "直连模式下残留的 fake-ip TUN 路由($($r.NextHop))" }
        if($kill){
            try { Remove-NetRoute -InputObject $r -Confirm:$false -ErrorAction Stop
                  Ok "移除孤儿默认路由 via $($r.NextHop) ($($r.InterfaceAlias)) —— $why"; $removed++ }
            catch { Warn "无法移除 via $($r.NextHop):$($_.Exception.Message)(需要管理员权限?)" }
        }
    }
    if($removed -eq 0){ Info "没有需要清理的孤儿路由" }
}

# ── 健全性检查:确保还有物理默认路由 ─────────────────────────────────────
$phys = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' -and ($adMap[$_.ifIndex] -and $adMap[$_.ifIndex].Status -eq 'Up') }
if(-not $phys){ Warn "当前没有可用的默认路由!请检查物理网络(WLAN/以太网)是否已连接。" }

# ── 3) 修正持久代理:env / 系统代理(绝不焊死端口) ────────────────────────────────
$envVars = 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'

# 判定"一个代理串是否 = 已死的本地端口"。本工具铁律:只在代理指向【死掉的本地端口】
# (机场一关就全断的元凶)时才清它;指向活端口或远程代理一律不动;且【永不主动设置代理】。
function Test-LocalProxyDead([string]$s){
    $endpoints = @(Get-ProxyEndpoints $s)
    if($endpoints.Count -eq 0){ return $false }
    # 混合了远程端点或无法安全解析时，不能为了清本地死端口而删除整项配置。
    if(@($endpoints | Where-Object { -not $_.parsed -or -not $_.local }).Count -gt 0){ return $false }
    foreach($endpoint in $endpoints){
        if(Test-PortAlive $endpoint.port){ return $false }
    }
    return $true
}

function Clear-GitProxySettings([switch]$ForceDirect){
    $git = Get-Command git -ErrorAction SilentlyContinue
    if(-not $git){ return }

    $found = $false
    $kept = $false
    foreach($key in 'http.proxy','https.proxy'){
        $values = @((& git config --global --get-all $key) 2>$null |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if($values.Count -eq 0){ continue }
        $found = $true
        $deadValues = @($values | Where-Object { Test-LocalProxyDead ([string]$_) })

        if($ForceDirect -or $deadValues.Count -eq $values.Count){
            & git config --global --unset-all $key 2>$null
            if($LASTEXITCODE -eq 0){
                if($ForceDirect){ Ok "已按直连模式清除 git $key" }
                else { Ok "已清掉指向死端口的 git $key (改成直连)" }
            } else {
                Warn "无法清理 git $key;请检查全局 git 配置是否可写"
            }
        } elseif($deadValues.Count -gt 0){
            $kept = $true
            Warn "git $key 同时含远程/可用项与死本地项;为避免误删远程代理，保持不动"
        } else {
            $kept = $true
        }
    }

    if(-not $found){ Info "git 代理本来就没设(直连)" }
    elseif($kept){ Info "其余 git 代理端点仍可用/是远程代理 —— 保持不动" }
}

# 3a) 环境变量(命令行 / Claude Code / curl / Node 读它):只清掉"指向死本地端口"的;
#     活的或远程的保留;-Direct 则全部清空。绝不主动给它设端口。
$envCleared=$false; $envKept=$false
foreach($v in $envVars){
    $val=[Environment]::GetEnvironmentVariable($v,'User')
    if(-not $val){ continue }
    if($Direct -or (Test-LocalProxyDead $val)){ Set-UserEnvFast $v $null; $envCleared=$true }
    else { $envKept=$true }
}
if($envCleared){
    Broadcast-EnvChange
    Ok "已清掉指向死端口的代理环境变量(改成直连;NO_PROXY 白名单不动)"
}
elseif($envKept){ Info "代理环境变量指向的端口还活着/是远程代理 —— 保持不动" }
else { Info "代理环境变量本来就是空的(直连)" }

# 3c) 系统代理(WinINET,浏览器/Electron 读它):机场在跑时由机场自己维护,本工具不抢。
#     仅当 -Direct,或它开着却指向【已死的本地端口】时,才关掉它恢复直连;其余保持原样。
$pp = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
$curEnable = [int]$pp.ProxyEnable
$curServer = [string]$pp.ProxyServer
if($Direct){
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Ok "系统代理:已强制关闭(直连)"
} elseif($curEnable -eq 1 -and (Test-LocalProxyDead $curServer)){
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Ok "系统代理指向的本地端口已死($curServer)—— 已关掉它(断网元凶),恢复直连"
} elseif($curEnable -eq 1){
    Info "系统代理开着且端口可用($curServer)—— 交给机场客户端维护,保持不动"
} else {
    Info "系统代理本来就是关的(直连),保持不动"
}
# 注:NO_PROXY 始终不动(里面有 aliyun 等白名单)。本工具永不主动开启/指定系统代理端口。

# ── 3b) git 代理:逐项只清死端口(git 有独立的 http.proxy / https.proxy)──────────
Clear-GitProxySettings -ForceDirect:$Direct

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

