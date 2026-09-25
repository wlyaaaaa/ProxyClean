#Requires -Version 5.1
# Client-level navigation and bounded shutdown. Display names never authorize effects.
function Get-PCClientFamily {
    param([string]$Name)
    switch -Regex ($Name -replace '(?i)\.exe$','') {
        '^(?i:FlyingBird(?:Core|HelperService)?)$' {return [pscustomobject]@{key='flyingbird';label='飞鸟'}}
        '^(?i:clash-verge|verge-mihomo|clash-verge-service|verge-service)$' {return [pscustomobject]@{key='clash-verge';label='Clash Verge'}}
        '^(?i:Clash for Windows|clash-win64|clash-win64-windows-amd64)$' {return [pscustomobject]@{key='clash-windows';label='Clash for Windows'}}
        '^(?i:tag|mihomo-tag|tag-mihomo)$' {return [pscustomobject]@{key='tag';label='TAG'}}
        '^(?i:clash|mihomo|clash-meta|clash-premium)$' {return [pscustomobject]@{key='clash-core';label='Clash / Mihomo'}}
        '^(?i:sing-box|xray|v2ray|hysteria|tuic|naive|trojan|sslocal)$' {return [pscustomobject]@{key=($Name -replace '(?i)\.exe$','').ToLowerInvariant();label=($Name -replace '(?i)\.exe$','')}}
        default {return $null}
    }
}
function Get-PCClientInventory {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Listeners=@(),[AllowEmptyCollection()][object[]]$Endpoints=@(),[AllowEmptyCollection()][object[]]$Processes=@())
    if(-not $PSBoundParameters.ContainsKey('Processes')){$Processes=@(Get-CimInstance Win32_Process -ErrorAction Stop)}
    # Optional endpoint inputs can be null; absence is not a dead endpoint.
    $Endpoints=@($Endpoints|Where-Object{$null -ne $_})
    $session=(Get-Process -Id $PID).SessionId
    $all=@{};foreach($p in $Processes){$all[[int]$p.ProcessId]=$p}
    $groups=@{}
    foreach($p in $Processes){
        if([int]$p.ProcessId -le 4 -or [int]$p.ProcessId -eq $PID -or [int]$p.SessionId -notin @(0,$session)){continue}
        $family=Get-PCClientFamily $p.Name
        if(-not $family){continue}
        # A generic core is assigned to its actual controller, never to a brand
        # merely because a similarly named GUI happens to be running.
        $parentId=[int]$p.ParentProcessId;$visited=@()
        while($all.ContainsKey($parentId) -and $parentId -notin $visited){
            $visited+=@($parentId);$parent=$all[$parentId]
            $childBorn=Get-PCValue $p 'CreationDate';$parentBorn=Get-PCValue $parent 'CreationDate'
            if($childBorn -and $parentBorn -and [DateTime]$parentBorn -gt [DateTime]$childBorn){break}
            if([int]$parent.SessionId -notin @(0,$session)){break}
            $owner=Get-PCClientFamily $parent.Name
            if($owner -and $owner.key -in @('flyingbird','clash-verge','clash-windows','tag')){$family=$owner;break}
            $parentId=[int]$parent.ParentProcessId
        }
        if(-not $groups.ContainsKey($family.key)){$groups[$family.key]=[pscustomobject]@{key=$family.key;label=$family.label;members=@();ports=@();published=$false;requires_admin=$false}}
        $group=$groups[$family.key]
        $group.members+=@($p)
        if([int]$p.SessionId -ne $session -or -not [string]$p.ExecutablePath){$group.requires_admin=$true}
        foreach($row in @($Listeners|Where-Object{[int]$_.OwningProcess -eq [int]$p.ProcessId})){
            [Net.IPAddress]$ip=$null
            if(-not [Net.IPAddress]::TryParse([string]$row.LocalAddress,[ref]$ip)){continue}
            if(-not([Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any))){continue}
            $group.ports+=@([int]$row.LocalPort)
            if(@($Endpoints|Where-Object{(Get-PCListenerState $_ @($row)) -eq 'listening'}).Count){$group.published=$true}
        }
    }
    @($groups.Values|Where-Object {@($_.members|Where-Object {-not(Test-PCClientBroker $_.Name)}).Count -gt 0}|Sort-Object label|ForEach-Object{$_.ports=@($_.ports|Sort-Object -Unique);$_})
}
function ConvertTo-PCPublicClients {
    param([AllowEmptyCollection()][object[]]$Clients=@())
    @($Clients|ForEach-Object{[pscustomobject]@{key=$_.key;label=$_.label;process_count=@($_.members).Count;ports=@($_.ports);published=$_.published;requires_admin=$_.requires_admin}})
}
function Get-PCProxySummary {
    param($Snapshot,[AllowEmptyCollection()][object[]]$Clients=@(),[string]$ClientObservation='observed')
    if($Snapshot.availability.wininet -ne 'observed'){return 'Windows 当前代理：未能确认'}
    if($Snapshot.system_proxy.enabled){
        $names=@($Clients|Where-Object published|Select-Object -ExpandProperty label -Unique)
        if($names.Count){return 'Windows 当前代理：'+($names -join '、')}
        if(@($Snapshot.endpoints|Where-Object state -eq 'dead').Count){return 'Windows 当前代理：对应程序未运行'}
        return 'Windows 当前代理：已开启，客户端未确认'
    }
    if($Snapshot.system_proxy.pac_configured){return 'Windows 自动代理：已配置'}
    if(@($Snapshot.tun_routes).Count){return '手动代理已关闭，仍检测到代理隧道'}
    if($ClientObservation -ne 'observed'){return 'Windows 手动代理：未开启；程序状态未确认'}
    if(@($Clients).Count){return 'Windows 手动代理：未开启；'+((@($Clients|ForEach-Object label)) -join '、')+'仍在运行'}
    return 'Windows 手动代理：未开启'
}
function Get-PCClientClosePreview {
    [CmdletBinding()]
    param([string]$ClientKey,$PreviousPlan,[string]$ExpectedClientInstance,[scriptblock]$Progress)
    Write-PCProgress $Progress 'clients' '正在确认运行中的代理客户端…'
    $snapshot=Get-PCSnapshot -Progress $Progress
    $endpoints=@(if($snapshot.systemProxy -and $snapshot.systemProxy.enabled){Get-ProxyEndpoints $snapshot.systemProxy.server})
    $clients=@(Get-PCClientInventory -Listeners $snapshot.listeners -Endpoints $endpoints)
    $undo=Get-PCUndoSummary
    if($undo.phase -notin @('none','undone','completed')){throw 'An unfinished cleanup exists.'}
    if($ClientKey){$selected=@($clients|Where-Object key -ceq $ClientKey)}else{$selected=$clients}
    if($selected.Count -gt 1){return [pscustomobject]@{status='choose_client';clients=@(ConvertTo-PCPublicClients $selected)}}
    if(-not $selected.Count){
        # No client is not permission to clear unrelated live or remote proxies.
        return [pscustomobject]@{status='no_client';snapshot=ConvertTo-PCPublicSnapshot $snapshot;clients=@(ConvertTo-PCPublicClients $clients)}
    }
    $client=$selected[0]
    if($ExpectedClientInstance -and (Get-PCClientInstance $client $snapshot.sid) -cne $ExpectedClientInstance){throw 'Process identity changed.'}
    if($PreviousPlan){
        if($PreviousPlan.schema -ne 'proxyclean.client-close.v1' -or $PreviousPlan.key -cne $client.key -or $PreviousPlan.sid -ne $snapshot.sid){throw 'Process identity changed.'}
        # A normal close may already have stopped the core. Keep its original
        # ports in this same confirmed operation so cleanup is not lost on retry.
        $client.ports=@(@($client.ports)+@($PreviousPlan.ports)|Sort-Object -Unique)
    }
    if($client.requires_admin -and -not(Test-PCAdministrator)){return [pscustomobject]@{status='client_needs_admin';key=$client.key;label=$client.label;instance=(Get-PCClientInstance $client $snapshot.sid)}}
    if($snapshot.availability.listeners -ne 'observed'){throw 'PC_LISTENER_UNKNOWN'}
    $identities=@(foreach($p in $client.members){
        $identity=Get-PCProcessIdentity -ProcessId ([int]$p.ProcessId)
        if(-not $identity.path){throw 'Client identity requires administrator access.'}
        if($identity.name -ine ($p.Name -replace '(?i)\.exe$','')){throw 'Process identity changed.'}
        $identity
    })
    $ids=@($identities|ForEach-Object pid)
    $services=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object{[int]$_.ProcessId -gt 4 -and [int]$_.ProcessId -in $ids}|ForEach-Object{[pscustomobject]@{name=[string]$_.Name;pid=[int]$_.ProcessId;path=[string]$_.PathName}})
    $repair=if($client.ports.Count){Get-PCRepairPlan -Snapshot $snapshot -Ports $client.ports}else{$null}
    $plan=[pscustomobject]@{schema='proxyclean.client-close.v1';sid=$snapshot.sid;key=$client.key;label=$client.label;members=$identities;ports=@($client.ports);services=$services;refresh_dns_cache=$true;observedUtc=$snapshot.observedUtc}
    [pscustomobject]@{status='client_preview';plan=$plan;public=ConvertTo-PCPublicClientPlan $plan;actions=@($(if($repair){$repair.steps|ForEach-Object{Get-PCStepLabel $_}|Select-Object -Unique}))}
}
function ConvertTo-PCPublicClientPlan {
    param($Plan)
    [pscustomobject]@{key=$Plan.key;label=$Plan.label;process_count=@($Plan.members).Count;service_count=@($Plan.services).Count;ports=@($Plan.ports);processes=@($Plan.members|Select-Object name,pid);effects='Only this confirmed client and references to its closed local ports; no other clients or adapters.'}
}
function Test-PCClientProcess {
    param($Identity)
    $process=Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue
    if(-not $process){return $false}
    $current=Get-PCProcessIdentity -ProcessId $Identity.pid
    if($current.start_utc -cne $Identity.start_utc -or $current.path -ine $Identity.path -or $current.session -ne $Identity.session -or $current.name -ine $Identity.name){throw 'Process identity changed.'}
    return $true
}
function Request-PCClientWindowClose {
    param($Identity)
    if(-not(Test-PCClientProcess $Identity)){return}
    try{
        $p=Get-Process -Id $Identity.pid -ErrorAction Stop
        if($p.MainWindowHandle -ne [IntPtr]::Zero){[void]$p.CloseMainWindow()}
    }catch{
        if(Get-Process -Id $Identity.pid -ErrorAction SilentlyContinue){throw}
    }
}
function Stop-PCClientService {
    param($Service)
    $current=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $Service.name)
    if($current.Count -ne 1){throw 'Service identity changed.'}
    if($current[0].State -eq 'Stopped'){return}
    if([int]$current[0].ProcessId -ne $Service.pid -or [string]$current[0].PathName -cne $Service.path){throw 'Service identity changed.'}
    # Do not stop dependent services and never change a service's startup type.
    if($current[0].State -eq 'Stop Pending'){return}
    [void](Invoke-PCNative -FilePath (Join-Path $env:WINDIR 'System32\sc.exe') -ArgumentList @('stop',$Service.name) -AllowedExitCodes @(0,1062) -TimeoutSeconds 10)
}
function Invoke-PCClientClose {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Plan,[switch]$Force,[switch]$ForceFallback,[switch]$SkipConnectivityChecks,[scriptblock]$Progress,[ValidateRange(0,10)][int]$WaitSeconds=4)
    if($Plan.schema -ne 'proxyclean.client-close.v1'){throw 'Unsupported client close plan.'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if($identity.IsSystem -or $identity.User.Value -ne $Plan.sid){throw 'Use the same intended Windows user, never SYSTEM.'}
    if(-not $PSCmdlet.ShouldProcess($Plan.label,$(if($Force){'Force-close only the confirmed client'}else{'Request normal client and service shutdown'}))){return [pscustomobject]@{status='preview'}}
    $restore=New-Object 'Collections.Generic.List[object]'
    $completed=$false
    $lock=Enter-PCLock
    try{
        $undo=Get-PCUndoSummary
        if($undo.phase -notin @('none','undone','completed')){throw 'An unfinished cleanup exists.'}
        # Check the whole selection before the first effect, and again per effect.
        foreach($member in @($Plan.members)){if($member.pid -le 4 -or $member.pid -eq $PID){throw 'Ineligible process.'};[void](Test-PCClientProcess $member)}
        foreach($service in @($Plan.services)){
            $s=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $service.name)
            if($s.Count -ne 1 -or ($s[0].State -ne 'Stopped' -and ([int]$s[0].ProcessId -ne $service.pid -or [string]$s[0].PathName -cne $service.path))){throw 'Service identity changed.'}
        }
        # Preserve the original broker state before a GUI exit can stop it.
        foreach($service in @($Plan.services)){
            $current=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $service.name)
            if($current.Count -eq 1 -and $current[0].State -eq 'Running' -and @($Plan.members|Where-Object {$_.pid -eq $service.pid -and (Test-PCClientBroker $_.name)}).Count){$restore.Add($service)}
        }
        Write-PCProgress $Progress 'close' ('正在请求'+$Plan.label+'正常退出…')
        foreach($member in @($Plan.members)){Request-PCClientWindowClose $member}
        foreach($service in @($Plan.services)){
            Write-PCProgress $Progress 'service' ('正在停止'+$Plan.label+'的辅助服务…')
            $current=@(Get-CimInstance Win32_Service -ErrorAction Stop|Where-Object Name -ceq $service.name)

            if($current.Count -ne 1 -or [string]$current[0].PathName -cne $service.path){throw 'Service identity changed.'}
            Stop-PCClientService $service
        }
        $forceAttempted=[bool]$Force
        if($ForceFallback -and -not $Force){
            $remaining=@(Wait-PCClientExit -Plan $Plan -WaitSeconds $WaitSeconds)
            $forceAttempted=$remaining.Count -gt 0
        }
        if($forceAttempted){
            Write-PCProgress $Progress 'force' ('正在结束你确认的'+$Plan.label+'剩余进程…')
            # Close controllers before cores and brokers to reduce respawn races.
            # This remains the original identity-bound selection, never a new scan.
            $ordered=@($Plan.members|Sort-Object @{Expression={if($_.name -match '^(?i:FlyingBird|clash-verge|Clash for Windows|tag)$'){0}elseif(Test-PCClientBroker $_.name){2}else{1}}},pid)
            foreach($member in $ordered){Stop-PCClientProcess $member}
        }
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds($WaitSeconds)
        do{
            $remaining=@($Plan.members|Where-Object{Test-PCClientProcess $_})
            if(-not $remaining.Count -or [DateTimeOffset]::UtcNow -ge $deadline){break}
            Start-Sleep -Milliseconds 200
        }while($true)
        $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop)
        $inventory=@(Get-PCClientInventory -Listeners $listeners)
        $sameClient=@($inventory|Where-Object key -ceq $Plan.key)
        $occupied=@(foreach($port in @($Plan.ports)){Get-PCLocalPortListeners -Port $port})
        if($remaining.Count -or $sameClient.Count -or $occupied.Count){
            return [pscustomobject]@{status='client_still_running';key=$Plan.key;label=$Plan.label;force_attempted=$forceAttempted;previous_plan=$Plan;settings_changed=$false;message='客户端未完全退出，或端口被重新占用。尚未清理代理设置。'}
        }
        Write-PCProgress $Progress 'verify' '客户端已退出，正在复查并清理它留下的代理引用…'
        $snapshot=Get-PCSnapshot -Progress $Progress
        $settings=[pscustomobject]@{status='no_changes';changed=0}
        if(@($Plan.ports).Count){
            $repair=Get-PCRepairPlan -Snapshot $snapshot -Ports $Plan.ports
            $settings=Invoke-PCRepairPlan -Plan $repair -Progress $Progress -Confirm:$false
            if($settings.status -eq 'applied'){[void](Send-PCSettingsChanged)}
        }
        if($settings.status -notin @('applied','no_changes')){return [pscustomobject]@{status='client_settings_incomplete';label=$Plan.label;settings=$settings}}
        $dnsCache='not_changed'
        if(Get-PCValue $Plan 'refresh_dns_cache' $false){$dnsCache=Clear-PCClientDnsCache}
        Write-PCProgress $Progress 'connectivity' '正在重新检查代理状态，并测试基础网页连接…'
        $after=ConvertTo-PCPublicSnapshot (Get-PCSnapshot -Progress $Progress)
        $still=@(Get-PCClientInventory -Listeners @(Get-NetTCPConnection -State Listen -ErrorAction Stop))
        $probe=if($SkipConnectivityChecks){[pscustomobject]@{status='not_tested'}}else{Test-PCConnectivity}
        $limits=New-Object 'Collections.Generic.List[string]'
        if(@($after.availability.PSObject.Properties|Where-Object Value -eq 'unknown').Count){$limits.Add('部分网络状态未能确认')}
        if($dnsCache -eq 'failed'){$limits.Add('旧域名缓存未能刷新')}
        if($probe.status -eq 'dns_resolution_failed'){$limits.Add('DNS 解析失败，请检查本机 DNS 服务及不依赖代理的上游')}
        if($after.system_proxy.enabled){$limits.Add('仍有手动代理设置')}
        if($after.system_proxy.pac_configured){$limits.Add('自动代理脚本仍保留')}
        if(@($after.tun_routes).Count){$limits.Add('仍检测到代理隧道')}
        if($still.Count){$limits.Add('仍有其他代理程序或重新启动的客户端')}
        if($after.conclusion.consumer_local_proxy_pin_present){$limits.Add('其他应用仍指定代理')}
        if(@($after.environment|Where-Object{$_.configured -and $_.scope -ne 'Process'}).Count -or @($after.git_proxy|Where-Object{@($_.values).Count}).Count){$limits.Add('终端或 Git 仍有其他代理设置')}
        if($after.winhttp -and $after.winhttp.mode -ne 'direct'){$limits.Add('Windows 服务代理尚未确认为直连')}
        $completed=$true
        $result=[pscustomobject]@{status='client_closed';label=$Plan.label;settings=$settings;dns_cache=$dnsCache;connectivity=$probe;remaining=$limits.ToArray();all_applications_direct='not_proven'}
    }finally{
        $restoreErrors=New-Object 'Collections.Generic.List[string]'
        try{
            foreach($service in $restore){
                try{Restore-PCClientService $service}
                catch{$restoreErrors.Add($service.name)}
            }
            if($restoreErrors.Count){throw 'PC_CLIENT_SERVICE_RESTORE_FAILED'}
            if($completed -and $restore.Count){
                $restarted=@(Get-PCClientInventory -Listeners @(Get-NetTCPConnection -State Listen -ErrorAction Stop)|Where-Object key -ceq $Plan.key)
                if($restarted.Count){throw 'PC_CLIENT_RESTARTED'}
            }
        }finally{try{$lock.ReleaseMutex()}finally{$lock.Dispose()}}
    }
    $result
}
