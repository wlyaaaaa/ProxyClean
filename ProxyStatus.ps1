<#
.SYNOPSIS
    Show which local proxy ports are alive and compare their observed exit IPs.
#>
[CmdletBinding()]
param()

$ports = 7890,7892,7897

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
    $args = @('-s','-m','10')
    if($proxy){ $args += @('-x', $proxy) }
    $args += 'https://ifconfig.me/ip'
    $ip = (& curl.exe @args) 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip)){ $ip = '<failed>' }
    [pscustomobject]@{ Path = $name; ExitIP = $ip.Trim() }
}
$ipRows = @(
    Get-IpLine 'current-default' $null
    Get-IpLine 'force-7890' 'http://127.0.0.1:7890'
    Get-IpLine 'force-7892' 'http://127.0.0.1:7892'
    Get-IpLine 'force-7897' 'http://127.0.0.1:7897'
)

$defaultIp = ($ipRows | Where-Object Path -eq 'current-default').ExitIP
$ip7890 = ($ipRows | Where-Object Path -eq 'force-7890').ExitIP
$ip7892 = ($ipRows | Where-Object Path -eq 'force-7892').ExitIP
$ip7897 = ($ipRows | Where-Object Path -eq 'force-7897').ExitIP
$alivePorts = @($listenerRows | Select-Object -ExpandProperty Port)
$aliveText = if($alivePorts.Count -gt 0){ ($alivePorts -join ' / ') } else { 'none' }
$routeHint = 'unknown'
if($defaultIp -ne '<failed>' -and $defaultIp -eq $ip7890){ $routeHint = '7890' }
elseif($defaultIp -ne '<failed>' -and $defaultIp -eq $ip7892){ $routeHint = '7892' }
elseif($defaultIp -ne '<failed>' -and $defaultIp -eq $ip7897){ $routeHint = '7897' }
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
    Write-Host "  7890/7892/7897 are not listening" -ForegroundColor Yellow
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
