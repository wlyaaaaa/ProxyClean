#Requires -Version 5.1
# Client policy and lifecycle helpers. Importing this file has no effects.
function Test-PCClientBroker {
    param([string]$Name)
    return ($Name -replace '(?i)\.exe$','') -match '^(?i:clash-verge-service|verge-service|FlyingBirdHelperService)$'
}
function Get-PCDisconnectTransition {
    param([string]$Status,[bool]$Requested,[bool]$Administrator,[bool]$ElevationAttempted)
    if(-not $Requested){return 'display'}
    switch($Status){
        'client_needs_admin'{if($Administrator -or $ElevationAttempted){return 'permission_failed'};return 'elevate'}
        'client_preview'{return 'apply'}
        'choose_client'{return 'choose'}
        default{return 'stop'}
    }
}

function Restore-PCClientService {
    param([Parameter(Mandatory)]$Service)
    $current=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $Service.name)
    if($current.Count -ne 1 -or [string]$current[0].PathName -cne $Service.path){throw 'Service identity changed.'}
    if($current[0].State -eq 'Running'){return}
    $controller=Get-Service -Name $Service.name -ErrorAction Stop
    if($controller.Status -eq 'StopPending'){$controller.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(8))}
    if($controller.Status -ne 'StartPending'){
        [void](Invoke-PCNative -FilePath (Join-Path $env:WINDIR 'System32\sc.exe') -ArgumentList @('start',$Service.name) -AllowedExitCodes @(0,1056) -TimeoutSeconds 10)
    }
    $controller.WaitForStatus('Running',[TimeSpan]::FromSeconds(8))
}
function Get-PCClientInstance {
    param([Parameter(Mandatory)]$Client,[Parameter(Mandatory)][string]$Sid)
    $rows=@(foreach($p in @($Client.members|Sort-Object ProcessId)){
        $born=Get-PCValue $p 'CreationDate'
        if(-not $born){throw 'Process identity unavailable.'}
        '{0}|{1}|{2}|{3}' -f $p.ProcessId,([string]$p.Name).ToLowerInvariant(),$p.SessionId,([DateTime]$born).ToUniversalTime().ToString('O')
    })
    if(-not $rows.Count){throw 'Process identity unavailable.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Sid+'|'+$Client.key+'|'+($rows -join ';'))))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}

function Wait-PCClientExit {
    param([Parameter(Mandatory)]$Plan,[ValidateRange(0,10)][int]$WaitSeconds)
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
    do{
        $remaining=@($Plan.members|Where-Object{Test-PCClientProcess $_})
        if(-not $remaining.Count -or [DateTimeOffset]::UtcNow -ge $deadline){return $remaining}
        Start-Sleep -Milliseconds 200
    }while($true)
}

function Stop-PCClientProcess {
    param([Parameter(Mandatory)]$Identity)
    if(-not(Test-PCClientProcess $Identity)){return}
    try{Stop-Process -Id $Identity.pid -Force -ErrorAction Stop}
    catch{
        # A verified process can exit between the check and termination.
        # A still-present or reused PID remains an error, never a new target.
        if(Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue){throw}
    }
}
function Get-PCConnectivityFailureMessage {
    param($Probe)
    switch([string](Get-PCValue $Probe 'status' 'not_tested')){
        'dns_resolution_failed'{return 'DNS 域名解析失败。请检查本机 DNS 服务及其上游能否脱离代理工作；重复清理代理设置不能修复这条解析链。'}
        'not_tested'{return '尚未执行网页测试，不能据此确认网络恢复。'}
        'not_available'{return '网页测试工具不可用，尚未确认联网状态。'}
        default{return '基础网页测试未能确认连通。请检查网络连接；这不等于所有网站都不可用。'}
    }
}
function Clear-PCClientDnsCache {
    try{
        [void](Invoke-PCNative -FilePath (Join-Path $env:WINDIR 'System32\ipconfig.exe') -ArgumentList @('/flushdns') -TimeoutSeconds 8)
        return 'flushed'
    }catch{return 'failed'}
}
function Get-PCDnsDependency {
    try{
        $indices=@(Get-NetAdapter -ErrorAction Stop|Where-Object {$_.HardwareInterface -and $_.Status -eq 'Up'}|ForEach-Object InterfaceIndex)
        $addresses=@(Get-DnsClientServerAddress -ErrorAction Stop|Where-Object InterfaceIndex -in $indices|ForEach-Object ServerAddresses)
        $local=@($addresses|Where-Object{[Net.IPAddress]$ip=$null;[Net.IPAddress]::TryParse($_,[ref]$ip) -and [Net.IPAddress]::IsLoopback($ip)})
        [pscustomobject]@{status=if(-not $addresses.Count){'unknown'}elseif($local.Count){'local_resolver_configured'}else{'external_resolver_configured'};upstream_independent_of_proxy='not_proven';settings_changed=$false}
    }catch{[pscustomobject]@{status='unknown';upstream_independent_of_proxy='not_proven';settings_changed=$false}}
}
