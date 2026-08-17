<#
.SYNOPSIS
    Discover active local proxy endpoints and TUN routes without a fixed port table.
#>
[CmdletBinding()]
param(
    [switch] $SkipExitProbe,
    [switch] $Json
)

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$systemProxy = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue

function Get-LocalProxyPorts([string]$value){
    if([string]::IsNullOrWhiteSpace($value)){ return @() }
    @([regex]::Matches($value, '(?i)(?<![a-z0-9_.-])(?:127\.0\.0\.1|localhost|\[::1\])\s*:\s*(?<port>\d{1,5})(?!\d)') |
        ForEach-Object { [int]$_.Groups['port'].Value } |
        Where-Object { $_ -ge 1 -and $_ -le 65535 } |
        Select-Object -Unique)
}

function Get-ProxyClientFamily([string]$processName){
    if($processName -match '(?i)flyingbird'){ return 'FlyingBird' }
    if($processName -match '(?i)clash-verge|verge-mihomo|clashverge'){ return 'ClashVerge' }
    if($processName -match '(?i)^tag(?:$|[-_])'){ return 'TAG' }
    return $processName
}

function Get-DockerProxySnapshot {
    $path = Join-Path $env:APPDATA 'Docker\settings-store.json'
    if(-not (Test-Path -LiteralPath $path -PathType Leaf)){
        return [pscustomobject][ordered]@{ exists=$false; path=$path; local_manual_pin_present=$false }
    }
    try {
        $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $localOverrides = @(
            foreach($name in 'OverrideProxyHTTP','OverrideProxyHTTPS','ContainersOverrideProxyHTTP','ContainersOverrideProxyHTTPS'){
                $property = $settings.PSObject.Properties[$name]
                if($property -and [string]$property.Value -match '(?i)(?<![a-z0-9_.-])(?:127\.0\.0\.1|localhost|\[::1\])\s*:\s*\d{1,5}(?!\d)'){
                    [pscustomobject][ordered]@{ setting=$name; endpoint=[string]$property.Value }
                }
            }
        )
        $runtimeMode = $null
        $runtimeLocalEndpoint = $null
        $runtimeEvidenceCurrent = $false
        $logPath = Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'
        $dockerRunning = @(Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue).Count -gt 0
        if($dockerRunning -and (Test-Path -LiteralPath $logPath -PathType Leaf)){
            $log = Get-Item -LiteralPath $logPath
            $runtimeEvidenceCurrent = $log.LastWriteTime -ge (Get-Date).AddMinutes(-10)
            if($runtimeEvidenceCurrent){
                $line = @(Get-Content -LiteralPath $logPath -Tail 300 -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match 'host will use proxy:' } |
                    Select-Object -Last 1)
                if($line -match 'host will use proxy:\s+app settings'){ $runtimeMode = 'manual' }
                elseif($line -match 'host will use proxy:\s+static system'){ $runtimeMode = 'system' }
                elseif($line -match 'host will use proxy:\s+disabled'){ $runtimeMode = 'disabled' }
                $endpointMatch = [regex]::Match([string]$line, '(?i)(?<![a-z0-9_.-])(?:127\.0\.0\.1|localhost|\[::1\])\s*:\s*\d{1,5}(?!\d)')
                if($endpointMatch.Success){ $runtimeLocalEndpoint = $endpointMatch.Value }
            }
        }
        $configuredLocalPin = $localOverrides.Count -gt 0 -and
            ($settings.ProxyHTTPMode -eq 'manual' -or $settings.ContainersProxyHTTPMode -eq 'manual')
        $runtimeLocalPin = $runtimeEvidenceCurrent -and $runtimeMode -eq 'manual' -and $null -ne $runtimeLocalEndpoint
        return [pscustomobject][ordered]@{
            exists = $true
            path = $path
            desktop_mode = [string]$settings.ProxyHTTPMode
            containers_mode = [string]$settings.ContainersProxyHTTPMode
            local_overrides = $localOverrides
            runtime_mode = $runtimeMode
            runtime_local_endpoint = $runtimeLocalEndpoint
            runtime_evidence_current = $runtimeEvidenceCurrent
            pending_apply = $runtimeLocalPin -and
                $settings.ProxyHTTPMode -eq 'system' -and $settings.ContainersProxyHTTPMode -eq 'system'
            local_manual_pin_present = $configuredLocalPin -or $runtimeLocalPin
        }
    }
    catch {
        return [pscustomobject][ordered]@{ exists=$true; path=$path; local_manual_pin_present=$null; error=$_.Exception.Message }
    }
}

$publishedPorts = @(
    if($systemProxy -and [int]$systemProxy.ProxyEnable -eq 1){
        Get-LocalProxyPorts ([string]$systemProxy.ProxyServer)
    }
)
$proxyProcessPattern = '(?i)clash|mihomo|sing-box|xray|v2ray|flyingbird|\btag\b|hysteria|tuic|naive|trojan|shadowsocks|sslocal'
$allListeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
$candidateListenerRows = @(
    foreach($item in $allListeners){
        $proc = Get-Process -Id $item.OwningProcess -ErrorAction SilentlyContinue
        $procName = if($proc){ [string]$proc.ProcessName } else { '' }
        $isPublished = $publishedPorts -contains [int]$item.LocalPort
        $isProxyOwner = $procName -match $proxyProcessPattern
        $isLocalEndpoint = $item.LocalAddress -in @('127.0.0.1','::1','0.0.0.0','::')
        if($isPublished -or ($isProxyOwner -and $isLocalEndpoint)){
            [pscustomobject][ordered]@{
                port = [int]$item.LocalPort
                address = [string]$item.LocalAddress
                pid = [int]$item.OwningProcess
                process = $procName
                published_by_system_proxy = $isPublished
            }
        }
    }
)
$listenerRows = @($candidateListenerRows | Sort-Object port,pid -Unique)
$livePorts = @($listenerRows | Where-Object published_by_system_proxy | Select-Object -ExpandProperty port -Unique)
$clientFamilies = @($listenerRows | ForEach-Object { Get-ProxyClientFamily $_.process } | Where-Object { $_ } | Select-Object -Unique)

$envRows = @(
    foreach($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'){
        [pscustomobject][ordered]@{
            name = $name
            user = [Environment]::GetEnvironmentVariable($name, 'User')
            machine = [Environment]::GetEnvironmentVariable($name, 'Machine')
            process = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
)
$routeRows = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Select-Object @{N='interface';E={$_.InterfaceAlias}},@{N='next_hop';E={$_.NextHop}},@{N='metric';E={$_.RouteMetric}})
$tunRows = @($routeRows | Where-Object next_hop -Match '^198\.1[89]\.')
$dockerProxy = Get-DockerProxySnapshot

function Get-IpLine([string]$name, [string]$proxy){
    $ip = $null
    foreach($url in 'https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com'){
        $args = @('-s','-m','8')
        if($proxy){ $args += @('-x', $proxy) }
        $args += $url
        $result = (& curl.exe @args) 2>$null
        if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($result)){
            $ip = ([string]$result).Trim()
            break
        }
    }
    if([string]::IsNullOrWhiteSpace($ip)){ $ip = '<failed>' }
    [pscustomobject][ordered]@{ path = $name; exit_ip = $ip }
}

$ipRows = @()
if(-not $SkipExitProbe){
    $ipRows = @(
        Get-IpLine 'current-default' $null
        foreach($port in $livePorts){
            Get-IpLine "force-local-$port" "http://127.0.0.1:$port"
        }
    )
}
$routeHint = if($SkipExitProbe){
    'not_probed'
}
elseif($ipRows.Count -eq 0 -or $ipRows[0].exit_ip -eq '<failed>'){
    'unknown'
}
else {
    $matches = @($ipRows | Select-Object -Skip 1 | Where-Object exit_ip -EQ $ipRows[0].exit_ip | Select-Object -ExpandProperty path)
    if($matches.Count -gt 0){ $matches -join ' / ' } else { 'direct/tun/other' }
}

$result = [pscustomobject][ordered]@{
    schema = 'proxyclean.dynamic-status.v1'
    discovery = 'wininet_endpoint_plus_live_proxy_owned_listeners_and_active_routes'
    conclusion = [ordered]@{
        current_default = $routeHint
        simultaneous_routing_paths = ($livePorts.Count + $tunRows.Count) -gt 1
        multiple_proxy_process_families = $clientFamilies.Count -gt 1
        proxy_process_families = $clientFamilies
        consumer_local_proxy_pin_present = $dockerProxy.local_manual_pin_present -eq $true
    }
    system_proxy = [ordered]@{
        enabled = $systemProxy -and [int]$systemProxy.ProxyEnable -eq 1
        server = if($systemProxy){ [string]$systemProxy.ProxyServer } else { $null }
        published_local_ports = $publishedPorts
    }
    listeners = $listenerRows
    tun_routes = $tunRows
    environment = $envRows
    docker_proxy = $dockerProxy
    default_routes = $routeRows
    exit_probes = $ipRows
}

if($Json){
    $result | ConvertTo-Json -Depth 8 -Compress
    return
}

Write-Host "==================== Proxy Status ====================" -ForegroundColor White
Write-Host "Conclusion:" -ForegroundColor White
Write-Host ("  Current default exit looks like: {0}" -f $routeHint) -ForegroundColor Green
Write-Host ("  WinINET-published live local proxy ports: {0}" -f $(if($livePorts.Count){$livePorts -join ' / '}else{'none'})) -ForegroundColor Cyan
Write-Host ("  Active fake-ip TUN routes: {0}" -f $tunRows.Count) -ForegroundColor Cyan
if($result.system_proxy.enabled){
    Write-Host ("  System proxy is ON: {0}" -f $result.system_proxy.server) -ForegroundColor Yellow
} else {
    Write-Host "  System proxy is OFF." -ForegroundColor Gray
}
if($result.conclusion.simultaneous_routing_paths -or $result.conclusion.multiple_proxy_process_families){
    Write-Host "  Multiple proxy paths are active; keep only the intended client." -ForegroundColor Yellow
}
if($result.conclusion.consumer_local_proxy_pin_present){
    if($dockerProxy.pending_apply){
        Write-Host "  Docker config is System, but the running backend still needs Docker Settings > Apply." -ForegroundColor Yellow
    }
    else {
        Write-Host "  Docker Desktop has a manual local proxy pin; switch both proxy modes to System." -ForegroundColor Yellow
    }
}
Write-Host ""
Write-Host "Proxy-owned listener candidates (only WinINET-published ports are treated as HTTP proxy endpoints):" -ForegroundColor White
if($listenerRows.Count){ $listenerRows | Format-Table -AutoSize } else { Write-Host "  none" -ForegroundColor Gray }
Write-Host "System proxy:" -ForegroundColor White
[pscustomobject]$result.system_proxy | Format-List
Write-Host "Environment proxy:" -ForegroundColor White
$envRows | Format-Table -AutoSize
Write-Host "Docker Desktop proxy:" -ForegroundColor White
$dockerProxy | Format-List
Write-Host "Default routes:" -ForegroundColor White
$routeRows | Format-Table -AutoSize
if(-not $SkipExitProbe){
    Write-Host "Exit IP comparison:" -ForegroundColor White
    $ipRows | Format-Table -AutoSize
}
Write-Host "======================================================" -ForegroundColor White
