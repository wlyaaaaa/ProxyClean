[CmdletBinding()]
param(
    [ValidateSet("Diagnose", "SoftReset", "AdapterReset")]
    [string]$Mode = "Diagnose",

    [string]$InterfaceAlias,

    [int]$WaitSeconds = 5,

    [switch]$SkipConnectivityChecks
)

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$modeNames = @{
    Diagnose = "诊断"
    SoftReset = "轻量刷新"
    AdapterReset = "重启WiFi网卡"
}

$logMode = $modeNames[$Mode]
$logPath = Join-Path $env:USERPROFILE "Desktop\WiFi网络-$logMode-$stamp.txt"

function Write-Log {
    param([string]$Text = "")
    Add-Content -LiteralPath $logPath -Value $Text
    Write-Host $Text
}

function Add-Section {
    param(
        [string]$Title,
        [scriptblock]$Body
    )

    Write-Log ""
    Write-Log "===== $Title ====="
    try {
        $result = & $Body 2>&1 | Out-String
        Write-Log $result.TrimEnd()
    } catch {
        Write-Log ("ERROR: " + $_.Exception.Message)
    }
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetWifiConfig {
    param([string]$Alias)

    $configs = Get-NetIPConfiguration |
        Where-Object {
            $isConnected = $_.NetAdapter.Status -eq "Up"
            $hasIpv4 = [bool]$_.IPv4Address
            $looksLikeWifi = $_.InterfaceAlias -match "WLAN|Wi-Fi|Wireless" -or $_.NetAdapter.InterfaceDescription -match "Wi-Fi|Wireless|802\.11|FastConnect"
            $isConnected -and $hasIpv4 -and $looksLikeWifi
        }

    if ($Alias) {
        $configs = $configs | Where-Object { $_.InterfaceAlias -eq $Alias }
    }

    return $configs | Select-Object -First 1
}

function Get-ConfigValue {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    return ($Value | ForEach-Object { $_.ToString() }) -join ", "
}

function Add-NetworkSnapshot {
    param(
        [string]$Label,
        [string]$WifiIp
    )

    Add-Section "$Label - 网络连接概况" {
        Get-NetConnectionProfile |
            Format-Table -AutoSize Name,InterfaceAlias,NetworkCategory,IPv4Connectivity,IPv6Connectivity
    }

    Add-Section "$Label - 当前网卡" {
        Get-NetAdapter |
            Where-Object {
                $_.Status -eq "Up" -or
                $_.Name -match "Flying|Tailscale|Clash|Mihomo|WLAN|Wi-Fi|Wireless|natpierce" -or
                $_.InterfaceDescription -match "Wintun|TAP|WireGuard|Tailscale|Flying|Mihomo|Clash"
            } |
            Sort-Object ifIndex |
            Format-Table -AutoSize ifIndex,Name,Status,InterfaceDescription,LinkSpeed
    }

    Add-Section "$Label - IP 配置" {
        Get-NetIPConfiguration |
            Format-List InterfaceAlias,IPv4Address,IPv6Address,IPv4DefaultGateway,IPv6DefaultGateway,DNSServer
    }

    Add-Section "$Label - DNS 服务器" {
        Get-DnsClientServerAddress |
            Sort-Object InterfaceAlias,AddressFamily |
            Format-Table -AutoSize InterfaceAlias,AddressFamily,ServerAddresses
    }

    Add-Section "$Label - IPv4 默认路由" {
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" |
            Sort-Object RouteMetric |
            Format-Table -AutoSize ifIndex,InterfaceAlias,NextHop,RouteMetric,InterfaceMetric,PolicyStore
    }

    Add-Section "$Label - 系统代理设置" {
        Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" |
            Select-Object ProxyEnable,ProxyServer,AutoConfigURL |
            Format-List
    }

    Add-Section "$Label - WinHTTP 代理" {
        netsh winhttp show proxy
    }

    if (-not $SkipConnectivityChecks) {
        Add-Section "$Label - B 站默认 DNS 解析" {
            Resolve-DnsName www.bilibili.com -ErrorAction Continue |
                Select-Object Name,Type,IPAddress,NameHost |
                Format-Table -AutoSize
        }

        Add-Section "$Label - B 站指定 223.5.5.5 解析" {
            Resolve-DnsName www.bilibili.com -Server 223.5.5.5 -ErrorAction Continue |
                Select-Object Name,Type,IPAddress,NameHost |
                Format-Table -AutoSize
        }

        Add-Section "$Label - B 站直连测试" {
            curl.exe --noproxy "*" -4 -I https://www.bilibili.com --connect-timeout 8 --max-time 15
        }

        if ($WifiIp) {
            Add-Section "$Label - 绑定 WiFi 的阿里 DNS 测试" {
                curl.exe --noproxy "*" --interface $wifiIp --resolve dns.alidns.com:443:223.5.5.5 "https://dns.alidns.com/resolve?name=www.bilibili.com&type=A" --connect-timeout 8 --max-time 15
            }

            Add-Section "$Label - 绑定 WiFi 的 B 站真实 IP 测试" {
                curl.exe --noproxy "*" --interface $wifiIp --resolve www.bilibili.com:443:223.111.252.67 -I https://www.bilibili.com --connect-timeout 8 --max-time 15
            }
        }
    }
}

"WiFi 网络处理开始: $(Get-Date -Format o)" | Set-Content -LiteralPath $logPath
Write-Log "模式: $logMode"

$wifiConfig = Get-TargetWifiConfig -Alias $InterfaceAlias
if (-not $wifiConfig) {
    Write-Log "没有找到已经连接并且有 IPv4 地址的 WiFi 网卡。"
    Write-Log "如果你的 WiFi 网卡名字比较特殊，可以用 -InterfaceAlias 指定。"
    Write-Log "日志: $logPath"
    exit 2
}

$wifiAlias = $wifiConfig.InterfaceAlias
$wifiIp = $wifiConfig.IPv4Address.IPAddress
Write-Log "检测到 WiFi 网卡: $wifiAlias"
Write-Log "检测到 WiFi IPv4: $wifiIp"
Write-Log "管理员权限: $(Test-IsAdmin)"

Add-NetworkSnapshot -Label "处理前" -WifiIp $wifiIp

if ($Mode -eq "SoftReset") {
    Add-Section "轻量刷新 - 清空 DNS 缓存" {
        ipconfig /flushdns
    }

    Add-Section "轻量刷新 - 释放 WiFi 地址租约" {
        ipconfig /release $wifiAlias
    }

    Start-Sleep -Seconds 2

    Add-Section "轻量刷新 - 重新获取 WiFi 地址租约" {
        ipconfig /renew $wifiAlias
    }

    Start-Sleep -Seconds $WaitSeconds
}

if ($Mode -eq "AdapterReset") {
    if (-not (Test-IsAdmin)) {
        Write-Log ""
        Write-Log "重启 WiFi 网卡需要管理员 PowerShell。"
        Write-Log "请右键用管理员身份运行，或者直接双击 一键重启WiFi网卡.bat。"
        Write-Log "日志: $logPath"
        exit 3
    }

    Add-Section "重启 WiFi 网卡 - 禁用网卡" {
        Disable-NetAdapter -Name $wifiAlias -Confirm:$false
    }

    Start-Sleep -Seconds 3

    Add-Section "重启 WiFi 网卡 - 启用网卡" {
        Enable-NetAdapter -Name $wifiAlias -Confirm:$false
    }

    Start-Sleep -Seconds $WaitSeconds
}

if ($Mode -ne "Diagnose") {
    $afterConfig = Get-TargetWifiConfig -Alias $wifiAlias
    if ($afterConfig -and $afterConfig.IPv4Address) {
        $wifiIp = $afterConfig.IPv4Address.IPAddress
    }

    Add-NetworkSnapshot -Label "处理后" -WifiIp $wifiIp
}

Write-Log ""
Write-Log "WiFi 网络处理结束: $(Get-Date -Format o)"
Write-Log "日志: $logPath"
