<#
.SYNOPSIS
    Show which local proxy ports are alive and compare their observed exit IPs.
#>
[CmdletBinding()]
param()

$ports = 7892,7897

Write-Host "==================== Proxy Status ====================" -ForegroundColor White

Write-Host "Listening ports:" -ForegroundColor White
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $ports -ErrorAction SilentlyContinue)
if($listeners.Count -eq 0){
    Write-Host "  7892/7897 are not listening" -ForegroundColor Yellow
} else {
    & {
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
    } | Format-Table -AutoSize
}

Write-Host "System proxy:" -ForegroundColor White
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue |
    Select-Object ProxyEnable,ProxyServer |
    Format-Table -AutoSize

Write-Host "Environment proxy:" -ForegroundColor White
& {
    foreach($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','http_proxy','https_proxy','all_proxy'){
        [pscustomobject]@{
            Name = $name
            User = [Environment]::GetEnvironmentVariable($name, 'User')
            Process = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
    }
} | Format-Table -AutoSize

Write-Host "Default routes:" -ForegroundColor White
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Select-Object InterfaceAlias,NextHop,RouteMetric |
    Format-Table -AutoSize

Write-Host "Exit IP comparison:" -ForegroundColor White
function Get-IpLine([string]$name, [string]$proxy){
    $args = @('-s','-m','10')
    if($proxy){ $args += @('-x', $proxy) }
    $args += 'https://ifconfig.me/ip'
    $ip = (& curl.exe @args) 2>$null
    if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip)){ $ip = '<failed>' }
    [pscustomobject]@{ Path = $name; ExitIP = $ip.Trim() }
}

Get-IpLine 'current-default' $null
Get-IpLine 'force-7892' 'http://127.0.0.1:7892'
Get-IpLine 'force-7897' 'http://127.0.0.1:7897'

Write-Host "======================================================" -ForegroundColor White
