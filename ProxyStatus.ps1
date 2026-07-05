<#
.SYNOPSIS
    Show which local proxy ports are alive and compare their observed exit IPs.
#>
[CmdletBinding()]
param()

$ports = 18090,7892,18091

Write-Host "==================== Proxy Status ====================" -ForegroundColor White

$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue)
$listenerRows = @(
    foreach($item in $listeners | Sort-Object LocalPort){
        $proc = Get-Process -Id $item.OwningProcess -ErrorAction SilentlyContinue
        $procName = ''
        if($proc){ $procName = $proc.ProcessName }
        [pscustomobject]@{
            Port = $item.LocalPort
            PID = $item.OwningProcess
            Process = $procName
        }
    }
)

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$systemProxy = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
$envRows = @(
    foreach($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'){
        [pscustomobject]@{
            Name = $name
            User = [Environment]::GetEnvironmentVariable($name, 'User')
            Process = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
)
$routeRows = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Select-Object InterfaceAlias,NextHop,RouteMetric)

function Get-IpLine([string]$name, [string]$proxy){
    $ip = $null
    foreach($url in 'https://api.ipify.org','https://ifconfig.me/ip','https://icanhazip.com'){
        $args = @('-s','-m','8')
        if($proxy){ $args += @('-x', $proxy) }
        $args += $url
        $result = (& curl.exe @args) 2>$null
        if($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($result)){
            $ip = $result.Trim()
            break
        }
    }
    if([string]::IsNullOrWhiteSpace($ip)){ $ip = '<failed>' }
    [pscustomobject]@{ Path = $name; ExitIP = $ip.Trim() }
}
$ipRows = @(
    Get-IpLine 'current-default' $null
    Get-IpLine 'force-18090' 'http://127.0.0.1:18090'
    Get-IpLine 'force-7892' 'http://127.0.0.1:7892'
    Get-IpLine 'force-18091' 'http://127.0.0.1:18091'
)

$defaultIp = ($ipRows | Where-Object Path -eq 'current-default').ExitIP
$ip18090 = ($ipRows | Where-Object Path -eq 'force-18090').ExitIP
$ip7892 = ($ipRows | Where-Object Path -eq 'force-7892').ExitIP
$ip18091 = ($ipRows | Where-Object Path -eq 'force-18091').ExitIP
$alivePorts = @($listenerRows | Select-Object -ExpandProperty Port)
$aliveText = if($alivePorts.Count -gt 0){ ($alivePorts -join ' / ') } else { 'none' }
$routeHint = 'unknown'
if($defaultIp -ne '<failed>' -and $defaultIp -eq $ip18090){ $routeHint = '18090' }
elseif($defaultIp -ne '<failed>' -and $defaultIp -eq $ip7892){ $routeHint = '7892' }
elseif($defaultIp -ne '<failed>' -and $defaultIp -eq $ip18091){ $routeHint = '18091' }
elseif($defaultIp -ne '<failed>'){ $routeHint = 'direct/other' }

Write-Host "Conclusion:" -ForegroundColor White
Write-Host ("  Current default exit looks like: {0}" -f $routeHint) -ForegroundColor Green
Write-Host ("  Listening proxy ports: {0}" -f $aliveText) -ForegroundColor Cyan
if($systemProxy -and [int]$systemProxy.ProxyEnable -eq 1){
    Write-Host ("  System proxy is ON: {0}" -f $systemProxy.ProxyServer) -ForegroundColor Yellow
} else {
    Write-Host "  System proxy is OFF." -ForegroundColor Gray
}
if(@($envRows | Where-Object { $_.User -or $_.Process }).Count -gt 0){
    Write-Host "  Env proxy is SET. Apps/terminals may use env proxy." -ForegroundColor Yellow
} else {
    Write-Host "  Env proxy is empty." -ForegroundColor Gray
}
Write-Host ""

Write-Host "Details:" -ForegroundColor White
Write-Host "Listening ports:" -ForegroundColor White
if($listeners.Count -eq 0){
    Write-Host "  18090/7892/18091 are not listening" -ForegroundColor Yellow
} else {
    $listenerRows | Format-Table -AutoSize
}

Write-Host "System proxy:" -ForegroundColor White
$systemProxy | Select-Object ProxyEnable,ProxyServer | Format-Table -AutoSize

Write-Host "Environment proxy:" -ForegroundColor White
$envRows | Format-Table -AutoSize

Write-Host "Default routes:" -ForegroundColor White
$routeRows | Format-Table -AutoSize

Write-Host "Exit IP comparison:" -ForegroundColor White
$ipRows | Format-Table -AutoSize

Write-Host "======================================================" -ForegroundColor White
