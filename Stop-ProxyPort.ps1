<#
.SYNOPSIS
    Force-stop the local proxy process listening on a specific port, then clean
    proxy leftovers that point at that port.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,

    [string]$Label = "127.0.0.1:$Port",

    [string[]]$ExtraProcessName = @()
)

$ErrorActionPreference = 'Continue'

function Info($m){ Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok($m)  { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

function Test-LocalProxyForPort([string]$value, [int]$port){
    if([string]::IsNullOrWhiteSpace($value)){ return $false }
    if($value -notmatch '(?i)(127\.0\.0\.1|localhost)'){ return $false }
    return [bool]([regex]::Matches($value, ':(\d{2,5})') |
        Where-Object { [int]$_.Groups[1].Value -eq $port })
}

function Get-ListeningPids([int]$port){
    @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        Where-Object { $_ -and $_ -gt 0 })
}

function Refresh-WinInet(){
    try {
        if(-not ([System.Management.Automation.PSTypeName]'WinINet.NativeMethods').Type){
            Add-Type -Namespace WinINet -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("wininet.dll", SetLastError=true)]
public static extern bool InternetSetOption(System.IntPtr h, int opt, System.IntPtr buf, int len);
"@
        }
        [WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        [WinINet.NativeMethods]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch {}
}

function Stop-ExtraProcesses([string[]]$names){
    foreach($name in $names){
        if([string]::IsNullOrWhiteSpace($name)){ continue }
        $matches = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if($matches.Count -eq 0){
            Info "Extra process '$name' is not running"
            continue
        }

        foreach($proc in $matches){
            if($proc.Id -eq $PID){ continue }
            Info ("Stopping extra process PID {0}: {1}" -f $proc.Id, $proc.ProcessName)
            try {
                Stop-Process -Id $proc.Id -Force -ErrorAction Stop
                Ok ("Stopped extra process PID {0}: {1}" -f $proc.Id, $proc.ProcessName)
            } catch {
                Warn ("Failed to stop extra process PID {0}: {1}" -f $proc.Id, $_.Exception.Message)
            }
        }
    }
}

function Get-DefaultExtraProcessNames([int]$port){
    switch($port){
        7892 { return @('FlyingBird','FlyingBirdCore','FlyingBirdHelperService') }
        7897 { return @('clash-verge','verge-mihomo') }
        7890 { return @('TAG','tag','mihomo-tag','tag-mihomo') }
        default { return @() }
    }
}

Write-Host "==================== Stop Proxy Port ====================" -ForegroundColor White
Write-Host ("Conclusion: closing {0} (127.0.0.1:{1})." -f $Label, $Port) -ForegroundColor Yellow
Write-Host "Details:" -ForegroundColor White
Info "Target: $Label (127.0.0.1:$Port)"

$defaultExtraProcessName = @(Get-DefaultExtraProcessNames $Port)
$allExtraProcessName = @($defaultExtraProcessName + $ExtraProcessName | Select-Object -Unique)

$pids = Get-ListeningPids $Port
$hadListener = ($pids.Count -gt 0)
if($pids.Count -eq 0){
    Info "Port $Port has no listening process"
} else {
    foreach($processId in $pids){
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if(-not $proc){
            Warn "PID $processId no longer exists"
            continue
        }

        Info ("Stopping PID {0}: {1}" -f $processId, $proc.ProcessName)
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Ok ("Stopped PID {0}: {1}" -f $processId, $proc.ProcessName)
        } catch {
            Warn ("Failed to stop PID {0}: {1}" -f $processId, $_.Exception.Message)
        }
    }

    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 300
        $left = Get-ListeningPids $Port
    } while($left.Count -gt 0 -and (Get-Date) -lt $deadline)

}

Stop-ExtraProcesses $allExtraProcessName

$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$pp = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
if($pp -and [int]$pp.ProxyEnable -eq 1 -and (Test-LocalProxyForPort ([string]$pp.ProxyServer) $Port)){
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Ok "System proxy pointed at $Port; disabled system proxy"
} else {
    Info "System proxy does not point at $Port; unchanged"
}

$envVars = 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'
$envChanged = $false
foreach($name in $envVars){
    $userValue = [Environment]::GetEnvironmentVariable($name, 'User')
    if(Test-LocalProxyForPort $userValue $Port){
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        $envChanged = $true
        Ok "Cleared user env var $name"
    }

    $processValue = [Environment]::GetEnvironmentVariable($name, 'Process')
    if(Test-LocalProxyForPort $processValue $Port){
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        Ok "Cleared current-process env var $name"
    }
}
if(-not $envChanged){ Info "User env vars do not point at $Port; unchanged" }

$git = Get-Command git -ErrorAction SilentlyContinue
if($git){
    $gitChanged = $false
    foreach($key in 'http.proxy','https.proxy'){
        $value = (& git config --global --get $key) 2>$null
        if(Test-LocalProxyForPort $value $Port){
            & git config --global --unset $key 2>$null
            $gitChanged = $true
            Ok "Cleared git $key"
        }
    }
    if(-not $gitChanged){ Info "git proxy does not point at $Port; unchanged" }
}

try { ipconfig /flushdns | Out-Null; Ok "Flushed DNS cache" } catch {}
Refresh-WinInet

$cleaner = Join-Path $PSScriptRoot 'ProxyClean.ps1'
if(Test-Path $cleaner){
    Info "Running ProxyClean for route/dead-port cleanup"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $cleaner -Quiet
}

$finalPids = Get-ListeningPids $Port
Write-Host "-------------------- Result --------------------" -ForegroundColor White
if($finalPids.Count -eq 0){
    if($hadListener){ Ok "Conclusion: port $Port is closed." }
    else { Ok "Conclusion: port $Port was already closed." }
} else {
    Warn "Conclusion: port $Port is STILL listening. PID: $($finalPids -join ', ')"
}

Write-Host "-------------------- Current Ports --------------------" -ForegroundColor White
Get-NetTCPConnection -State Listen -LocalPort 7890,7892,7897 -ErrorAction SilentlyContinue |
    Select-Object LocalAddress,LocalPort,OwningProcess |
    Format-Table -AutoSize

Write-Host "=========================================================" -ForegroundColor White
