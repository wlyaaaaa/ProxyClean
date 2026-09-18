#Requires -Version 5.1
# Loaded by ProxyClean.Common; only explicit callers invoke mutations.
function Test-PCAdministrator {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-PCLocalPortListeners {
    [CmdletBinding()]
    param([ValidateRange(1,65535)][int]$Port)
    @(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object{
        if([int]$_.LocalPort -ne $Port){return $false}
        [Net.IPAddress]$address=$null
        [Net.IPAddress]::TryParse([string]$_.LocalAddress,[ref]$address) -and
            ([Net.IPAddress]::IsLoopback($address) -or $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any))
    })
}
function Get-PCProcessIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $process=Get-Process -Id $ProcessId -ErrorAction Stop
    [pscustomobject]@{pid=$process.Id;name=$process.ProcessName;start_utc=$process.StartTime.ToUniversalTime().ToString('O');path=$process.Path;session=$process.SessionId}
}
function Get-PCStopPlan {
    [CmdletBinding()]
    param([ValidateRange(1,65535)][int]$Port,[string[]]$ExtraProcessName=@())
    $listeners=@(Get-PCLocalPortListeners -Port $Port)
    $processes=@()
    foreach($processId in @($listeners|Select-Object -ExpandProperty OwningProcess -Unique)){
        if($processId -le 4 -or $processId -eq $PID){throw 'The selected listener is not an eligible user proxy process.'}
        $identity=Get-PCProcessIdentity -ProcessId $processId
        $identity|Add-Member -NotePropertyName selection -NotePropertyValue 'port_listener'
        $processes+=@($identity)
    }
    foreach($name in $ExtraProcessName){
        if($name -notmatch '\A[A-Za-z0-9_. -]+\z'){throw 'Explicit client process names cannot contain wildcards or control characters.'}
        foreach($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)){
            if($p.Id -le 4 -or $p.Id -eq $PID){throw 'Refusing to select a protected system/current process.'}
            if($p.Id -in @($processes|ForEach-Object{$_.pid})){continue}
            $identity=Get-PCProcessIdentity -ProcessId $p.Id
            $identity|Add-Member -NotePropertyName selection -NotePropertyValue 'explicit_client_name'
            $processes+=@($identity)
        }
    }
    [pscustomobject]@{schema='proxyclean.stop-plan.v1';port=$Port;processes=$processes;extra_names=@($ExtraProcessName);observedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
}
function ConvertTo-PCPublicStopPlan {
    param([Parameter(Mandatory)]$Plan)
    [pscustomobject]@{schema=$Plan.schema;port=$Plan.port;processes=@($Plan.processes|Select-Object pid,name,session,selection)
        effects=@('Only current loopback/wildcard listeners at this port are selected.','Whole-client shutdown occurs only for explicitly provided ExtraProcessName.','Stopped processes cannot be restored by proxy-settings undo.','Proxy references are cleaned only after the port is verified closed.')}
}
function Invoke-PCStopPlan {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Plan)
    if($Plan.schema -ne 'proxyclean.stop-plan.v1'){throw 'Unsupported stop plan.'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem){throw 'Use the intended Windows user, not SYSTEM.'}
    $stopped=New-Object 'Collections.Generic.List[int]';$failed=New-Object 'Collections.Generic.List[int]'
    foreach($candidate in @($Plan.processes)){
        if(-not $PSCmdlet.ShouldProcess(('PID {0} {1}' -f $candidate.pid,$candidate.name),'Stop this verified process; this action is not undoable')){continue}
        try{
            $current=Get-PCProcessIdentity -ProcessId $candidate.pid
            if($current.start_utc -cne $candidate.start_utc -or $current.path -cne $candidate.path -or $current.session -ne $candidate.session){throw 'Process identity changed.'}
            if($candidate.selection -eq 'port_listener' -and $candidate.pid -notin @(Get-PCLocalPortListeners -Port $Plan.port|ForEach-Object{$_.OwningProcess})){throw 'Process no longer owns the target listener.'}
            Stop-Process -Id $candidate.pid -Force -ErrorAction Stop
            $stopped.Add([int]$candidate.pid)
        }catch{$failed.Add([int]$candidate.pid)}
    }
    if($WhatIfPreference){return [pscustomobject]@{status='preview';stopped=0;settings_changed=$false}}
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(8)
    do{
        $remaining=@(Get-PCLocalPortListeners -Port $Plan.port)
        if(-not $remaining.Count){break}
        if([DateTimeOffset]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 250}
    }while([DateTimeOffset]::UtcNow -lt $deadline)
    if($remaining.Count -gt 0 -or $failed.Count -gt 0){return [pscustomobject]@{status='incomplete';stopped=$stopped.Count;failed_pids=@($failed);port_closed=($remaining.Count -eq 0);settings_changed=$false}}
    # A fresh per-port plan is deliberately NOT a whole-machine cleanup.
    $repair=Get-PCRepairPlan -Snapshot (Get-PCSnapshot) -Port $Plan.port
    $settings=Invoke-PCRepairPlan -Plan $repair -Confirm:$false
    if($settings.status -eq 'applied'){[void](Send-PCSettingsChanged)}
    [pscustomobject]@{status=if($settings.status -in @('applied','no_changes')){'closed'}else{'incomplete'};stopped=$stopped.Count;port_closed=$true;settings=$settings;network_recovered='not_tested'}
}
function Get-PCWifiAdapter {
    [CmdletBinding()]
    param([string]$InterfaceAlias,[AllowEmptyCollection()][object[]]$Adapters=@())
    if(-not $PSBoundParameters.ContainsKey('Adapters')){$Adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop)}
    $physical=@($Adapters|Where-Object{(Get-PCValue $_ 'HardwareInterface') -eq $true})
    if($InterfaceAlias){$candidates=@($physical|Where-Object{[string]$_.Name -ieq $InterfaceAlias})}
    else{
        $candidates=@($physical|Where-Object{
            [string](Get-PCValue $_ 'NdisPhysicalMedium') -in @('1','9','WirelessLan','Native802_11') -or
            ([string]$_.Name+' '+[string](Get-PCValue $_ 'InterfaceDescription')) -match '(?i)WLAN|Wi-Fi|Wireless|802\.11|FastConnect'
        })
    }
    if($candidates.Count -ne 1){throw 'Exactly one intended physical adapter must be identified. Specify InterfaceAlias; disconnected adapters remain eligible.'}
    return $candidates[0]
}
function Get-PCWifiSnapshot {
    param([Parameter(Mandatory)]$Adapter)
    $index=[int](Get-PCValue $Adapter 'InterfaceIndex' (Get-PCValue $Adapter 'ifIndex'))
    # Enumerate then select: absent addresses must not block repair selection.
    $dhcp='unknown';$addressState='unknown';$v4=$null;$v6=$null
    try{$interfaces=@(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop|Where-Object InterfaceIndex -eq $index);if($interfaces.Count -eq 1){$dhcp=[string]$interfaces[0].Dhcp}}catch{}
    try{$addresses=@(Get-NetIPAddress -ErrorAction Stop|Where-Object InterfaceIndex -eq $index);$v4=@($addresses|Where-Object AddressFamily -eq 'IPv4').Count;$v6=@($addresses|Where-Object AddressFamily -eq 'IPv6').Count;$addressState='observed'}catch{}
    [pscustomobject]@{name=$Adapter.Name;interface_index=$index;status=[string]$Adapter.Status;physical=$true;dhcp=$dhcp
        ipv4_address_count=$v4;ipv6_address_count=$v6;address_observation=$addressState;actual_addresses_redacted=$true}
}
function Invoke-PCWifiReset {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([Parameter(Mandatory)]$Adapter,[ValidateSet('SoftReset','AdapterReset')][string]$Mode,[ValidateRange(0,120)][int]$WaitSeconds=5)
    if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem){throw 'Run as the intended Windows user, not SYSTEM.'}
    $name=[string]$Adapter.Name;$index=[int](Get-PCValue $Adapter 'InterfaceIndex' (Get-PCValue $Adapter 'ifIndex'))
    $current=Get-PCWifiAdapter -InterfaceAlias $name
    if([int](Get-PCValue $current 'InterfaceIndex' (Get-PCValue $current 'ifIndex')) -ne $index){throw 'Adapter identity changed after selection.'}
    if(-not $PSCmdlet.ShouldProcess($name,"$Mode temporarily interrupts this connection")){return [pscustomobject]@{status='preview';mode=$Mode}}
    if(-not(Test-PCAdministrator)){throw 'Network reset requires an elevated window for the same Windows user.'}
    if($Mode -eq 'SoftReset'){
        $ip=Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop
        if([string]$ip.Dhcp -ne 'Enabled'){throw 'The adapter is not using DHCP; its static configuration was preserved.'}
        $native=Join-Path $env:WINDIR 'System32\ipconfig.exe'
        [void](Invoke-PCNative -FilePath $native -ArgumentList @('/flushdns'))
        try { [void](Invoke-PCNative -FilePath $native -ArgumentList @('/release',$name) -TimeoutSeconds 30) }
        finally {
        [void](Invoke-PCNative -FilePath $native -ArgumentList @('/renew',$name) -TimeoutSeconds 90)
        }
    }else{
        $disabled=$false;$enabled=$false
        try{
            Disable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop
            $disabled=$true
            Start-Sleep -Seconds 2
        }finally{
            if($disabled){Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop;$enabled=$true}
        }
        if(-not $enabled){throw 'Adapter reset did not complete; no success was inferred.'}
    }
    if($WaitSeconds){Start-Sleep -Seconds $WaitSeconds}
    $after=Get-PCWifiAdapter -InterfaceAlias $name
    $snapshot=Get-PCWifiSnapshot -Adapter $after
    [pscustomobject]@{status=if($snapshot.status -eq 'Up' -and $snapshot.ipv4_address_count -gt 0){'adapter_ready'}else{'needs_attention'}
        mode=$Mode;adapter=$snapshot;internet_reachability='not_tested';undo_scope='Adapter and DHCP resets are transient network operations, not proxy-settings undo.'}
}
function Get-PCIPv6Snapshot {
    [CmdletBinding()]
    param()
    $rows=@(foreach($adapter in @(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object Status -eq 'Up')){
        $binding=$null;$state='unknown'
        try{$binding=Get-NetAdapterBinding -Name $adapter.Name -ComponentID ms_tcpip6 -ErrorAction Stop;$state=if($binding.Enabled){'enabled'}else{'disabled'}}catch{}
        [pscustomobject]@{name=$adapter.Name;interface_index=[int](Get-PCValue $adapter 'InterfaceIndex' (Get-PCValue $adapter 'ifIndex'));physical=(Get-PCValue $adapter 'HardwareInterface') -eq $true;binding_state=$state}
    })
    $routeState='unknown'
    try{$routes=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop|Where-Object DestinationPrefix -eq '::/0');$routeState=if($routes.Count){'present'}else{'absent'}}catch{}
    [pscustomobject]@{schema='proxyclean.ipv6-status.v1';adapters=$rows;default_route=$routeState;internet_reachability='not_tested';proxy_routing='not_tested'}
}
function Invoke-PCIPv6Change {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param([ValidateSet('Toggle','Enable','Disable')][string]$Mode='Toggle',[string]$InterfaceAlias)
    $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object{
        $_.Status -eq 'Up' -and (Get-PCValue $_ 'HardwareInterface') -eq $true -and
        $_.Name -notmatch 'VMware|vEthernet|Loopback|Tailscale|WSL|FlyingBird|natpierce'
    })
    if($InterfaceAlias){$adapters=@($adapters|Where-Object Name -eq $InterfaceAlias)}
    if(-not $adapters.Count){throw 'No eligible active physical adapter; virtual/tunnel adapters are preserved.'}
    $before=@(foreach($a in $adapters){$binding=Get-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction Stop;[pscustomobject]@{name=$a.Name;index=[int](Get-PCValue $a 'InterfaceIndex' (Get-PCValue $a 'ifIndex'));enabled=[bool]$binding.Enabled}})
    $enable=if($Mode -eq 'Enable'){$true}elseif($Mode -eq 'Disable'){$false}else{@($before|Where-Object enabled).Count -eq 0}
    $changed=New-Object 'Collections.Generic.List[object]'
    try{
        foreach($item in $before){
            if($item.enabled -eq $enable){continue}
            if(-not $PSCmdlet.ShouldProcess($item.name,('Set physical IPv6 binding to '+$enable))){continue}
            if(-not(Test-PCAdministrator)){throw 'IPv6 changes require elevation.'}
            $a=Get-NetAdapter -Name $item.name -ErrorAction Stop
            if([int](Get-PCValue $a 'InterfaceIndex' (Get-PCValue $a 'ifIndex')) -ne $item.index -or (Get-PCValue $a 'HardwareInterface') -ne $true){throw 'Adapter identity changed.'}
            $current=Get-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop
            if([bool]$current.Enabled -ne $item.enabled){throw 'Binding changed after selection.'}
            $changed.Add($item)
            if($enable){Enable-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop|Out-Null}else{Disable-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop|Out-Null}
            if([bool](Get-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled -ne $enable){throw 'IPv6 binding readback failed.'}
        }
    }catch{
        $failures=@()
        foreach($item in $changed){try{if($item.enabled){Enable-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop|Out-Null}else{Disable-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop|Out-Null};if([bool](Get-NetAdapterBinding -Name $item.name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled -ne $item.enabled){throw 'Readback failed'}}catch{$failures+=@($item.name)}}
        if($failures.Count){throw 'IPv6 change failed and one or more original bindings require recovery. Inspect IPv6-Status.ps1; no full recovery was claimed.'}
        throw 'IPv6 change failed; this run restored its changed bindings.'
    }
    [pscustomobject]@{status=if($WhatIfPreference){'preview'}else{'binding_verified'};changed=$changed.Count;enabled=$enable;proxy_routing='not_tested';internet_reachability='not_tested'}
}

function Get-PCExitComparison {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    $curl=Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $curl){return [pscustomobject]@{path='process-default';status='unavailable'}}
    $paths=@([pscustomobject]@{name='process-default';proxy=$null})
    if($Snapshot.systemProxy -and $Snapshot.systemProxy.enabled){
        foreach($e in @(Get-ProxyEndpoints $Snapshot.systemProxy.server)){
            if(-not $e.local -or $e.credentials_present -or (Get-PCListenerState $e $Snapshot.listeners ($Snapshot.availability.listeners -eq 'observed')) -ne 'listening'){continue}
            $hostText=if($e.family -eq 'InterNetworkV6'){'['+$e.host+']'}else{$e.host}
            $proxy=$e.scheme+'://'+$hostText+':'+$e.port
            if($proxy -notin @($paths|ForEach-Object{$_.proxy})){$paths+=@([pscustomobject]@{name='forced-local-'+$e.port;proxy=$proxy})}
        }
    }
    $groups=@{}
    foreach($path in $paths){
        try{
            $arguments=@('--silent','--show-error','--connect-timeout','4','--max-time','8')
            if($path.proxy){$arguments+=@('--proxy',$path.proxy,'--noproxy','')}
            $arguments+=@('https://api.ipify.org')
            $r=Invoke-PCNative -FilePath $curl.Source -ArgumentList $arguments -TimeoutSeconds 11
            [Net.IPAddress]$ip=$null
            if(-not [Net.IPAddress]::TryParse($r.stdout.Trim(),[ref]$ip)){throw 'Exit probe did not return an IP address.'}
            $key=$ip.ToString();if(-not $groups.ContainsKey($key)){$groups[$key]='exit-group-'+($groups.Count+1)}
            [pscustomobject]@{path=$path.name;status='observed';exit_group=$groups[$key];address_redacted=$true;identifies_client=$false}
        }catch{[pscustomobject]@{path=$path.name;status='unknown';exit_group=$null;address_redacted=$true;identifies_client=$false}}
    }
}