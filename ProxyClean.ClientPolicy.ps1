#Requires -Version 5.1
# Client policy and lifecycle helpers. Importing this file has no effects.
function Test-PCClientBroker {
    param([string]$Name)
    return ($Name -replace '(?i)\.exe$','') -match '^(?i:clash-verge-service|verge-service|FlyingBirdHelperService)$'
}
function Test-PCClientController {
    param([string]$Name)
    return ($Name -replace '(?i)\.exe$','') -match '^(?i:FlyingBird|clash-verge|Clash for Windows|tag)$'
}
function Get-PCClashVergeIntentStep {
    param([Parameter(Mandatory)]$Plan)
    if($Plan.key -ne 'clash-verge'){return}
    $services=@($Plan.services|Where-Object name -ceq 'clash_verge_service')
    if(-not $services.Count){return}
    if($services.Count -ne 1){throw 'Service identity changed.'}
    $executable=([string]$services[0].path).Trim('"')
    if([IO.Path]::GetFileName($executable) -ine 'clash-verge-service.exe'){throw 'Service identity changed.'}
    $bin=Split-Path -Parent $executable
    # New Verge services persist core-run intent alongside their installed bin directory.
    # Older services do not have this state. Do not inspect user profiles or subscriptions.
    if((Split-Path -Leaf $bin) -ine 'bin'){return}
    $root=Split-Path -Parent $bin
    $ownerPath=Join-Path $root 'active-owner.json'
    if(-not(Test-Path -LiteralPath $ownerPath)){return}
    $ownerText=[IO.File]::ReadAllText($ownerPath)
    $owner=$ownerText|ConvertFrom-Json
    $windows=Get-PCValue (Get-PCValue $owner 'identity') 'Windows'
    if((Get-PCValue $windows 'sid') -cne $Plan.sid -or (Get-PCValue $owner 'owner_key') -cnotmatch '^[a-f0-9]{64}$'){throw 'PC_CLIENT_OWNER_CHANGED'}
    $path=Join-Path $root ('users\'+$owner.owner_key+'\desired-state.json')
    $before=[IO.File]::ReadAllText($path)
    $state=$before|ConvertFrom-Json
    if((Get-PCValue $state 'core_should_be_running') -isnot [bool]){throw 'PC_CLIENT_STATE_UNSUPPORTED'}
    if(-not $state.core_should_be_running){return}
    $corePath=Get-PCValue (Get-PCValue (Get-PCValue $state 'last_clash_config') 'core_config') 'core_path'
    if(-not $corePath -or -not @($Plan.members|Where-Object {([string]$_.path -replace '^\\\\\?\\','') -ieq ([string]$corePath -replace '^\\\\\?\\','')}).Count){throw 'PC_CLIENT_OWNER_CHANGED'}
    # Replace this boolean only: retain unknown fields and original JSON values verbatim.
    $pattern='("core_should_be_running"\s*:\s*)true\b'
    if([regex]::Matches($before,$pattern).Count -ne 1){throw 'PC_CLIENT_STATE_UNSUPPORTED'}
    $after=[regex]::Replace($before,$pattern,'${1}false')
    $step=New-PCStep 'ClientIntent' 'ClashVerge' $before $after 'Stop the selected client from restoring its just-closed core.'
    $step|Add-Member -NotePropertyMembers @{target_file=$path;owner_file=$ownerPath;owner_before=$ownerText;service=$services[0]}
    return $step
}
function Set-PCClientIntentValue {
    param([Parameter(Mandatory)]$Step,[Parameter(Mandatory)][string]$Value)
    $current=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $Step.service.name)
    if($current.Count -ne 1 -or [string]$current[0].PathName -cne $Step.service.path -or $current[0].State -ne 'Stopped'){throw 'Service identity changed.'}
    if([IO.File]::ReadAllText($Step.owner_file) -cne $Step.owner_before){throw 'PC_CLIENT_OWNER_CHANGED'}
    $expected=if($Value -ceq $Step.after){$Step.before}elseif($Value -ceq $Step.before){$Step.after}else{throw 'Unsupported client intent value.'}
    if([IO.File]::ReadAllText($Step.target_file) -cne $expected){throw 'Configuration changed after preview; preserved.'}
    $temp=$Step.target_file+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes($Value)
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        # ReplaceFile preserves the original ACL and makes the change atomic.
        [IO.File]::Replace($temp,$Step.target_file,[NullString]::Value)
        if([IO.File]::ReadAllText($Step.owner_file) -cne $Step.owner_before){throw 'PC_CLIENT_OWNER_CHANGED'}
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Get-PCClientPortState {
    param([Parameter(Mandatory)]$Plan,[AllowEmptyCollection()][object[]]$Inventory=@())
    $otherIds=@($Inventory|Where-Object key -cne $Plan.key|ForEach-Object {Get-PCValue $_ 'members' @()}|ForEach-Object ProcessId)
    $closed=@();$reassigned=@();$unknown=@()
    foreach($port in @($Plan.ports)){
        $listeners=@(Get-PCLocalPortListeners -Port $port)
        if(-not $listeners.Count){$closed+=@($port)}
        elseif(@($listeners|Where-Object OwningProcess -notin $otherIds).Count){$unknown+=@($port)}
        else{$reassigned+=@($port)}
    }
    [pscustomobject]@{closed=$closed;reassigned=$reassigned;unknown=$unknown}
}
function Assert-PCClientStayedClosed {
    param([Parameter(Mandatory)]$Plan,[ValidateRange(0,5000)][int]$Milliseconds=1000)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop)
        $inventory=@(Get-PCClientInventory -Listeners $listeners)
        if(@($inventory|Where-Object key -ceq $Plan.key).Count){throw 'PC_CLIENT_RESTARTED'}
        if(@((Get-PCClientPortState -Plan $Plan -Inventory $inventory).unknown).Count){throw 'PC_CLIENT_PORT_OCCUPIED'}
        if($timer.ElapsedMilliseconds -ge $Milliseconds){return}
        Start-Sleep -Milliseconds 200
    }while($true)
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
