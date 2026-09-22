#Requires -Version 5.1
# Sourced by ProxyClean.Common. Effects are isolated from endpoint classification.
function Get-PCRegistryValue {
    param([ValidateSet('WinInet','UserEnv')][string]$Area,[string]$Name)
    $path=if($Area -eq 'WinInet'){'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'}else{'HKCU:\Environment'}
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject][ordered]@{exists=$false;value=$null;kind=$null}}
    $key=Get-Item -LiteralPath $path -ErrorAction Stop
    if($Name -notin @($key.GetValueNames())){return [pscustomobject][ordered]@{exists=$false;value=$null;kind=$null}}
    [pscustomobject][ordered]@{exists=$true;value=$key.GetValue($Name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=[string]$key.GetValueKind($Name)}
}
function Test-PCSameValue {
    param($Left,$Right)
    return (ConvertTo-Json -InputObject $Left -Depth 15 -Compress) -ceq (ConvertTo-Json -InputObject $Right -Depth 15 -Compress)
}
function ConvertTo-PCRouteRecord {
    param($Route)
    [pscustomobject][ordered]@{interface_index=[int](Get-PCValue $Route 'InterfaceIndex' (Get-PCValue $Route 'ifIndex'));destination=[string]$Route.DestinationPrefix;next_hop=[string]$Route.NextHop;metric=[int]$Route.RouteMetric}
}
function New-PCStep {
    param([string]$Kind,[string]$Name,$Before,$After,[string]$Reason)
    [pscustomobject]@{kind=$Kind;name=$Name;before=$Before;after=$After;reason=$Reason;phase='planned'}
}
function Get-PCRepairPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot,[switch]$Direct,[ValidateRange(0,65535)][int]$Port=0,[ValidateRange(1,65535)][int[]]$Ports=@())
    $targetPorts=@(@(if($Port){$Port})+@($Ports)|Sort-Object -Unique)
    $steps=New-Object 'Collections.Generic.List[object]'
    $warnings=New-Object 'Collections.Generic.List[string]'
    $listenerKnown=$Snapshot.availability.listeners -eq 'observed'
    $absent=[pscustomobject][ordered]@{exists=$false;value=$null;kind=$null}
    if($Snapshot.availability.wininet -eq 'observed' -and $Snapshot.systemProxy){
        $proxy=$Snapshot.systemProxy
        if($targetPorts.Count -gt 0 -and $proxy.enabled){
            $remove=Remove-PCProxyEndpoints -Value $proxy.server -Ports $targetPorts
            if($remove.changed){
                if($remove.value){$steps.Add((New-PCStep 'WinInet' 'ProxyServer' $proxy.values.ProxyServer ([pscustomobject][ordered]@{exists=$true;value=$remove.value;kind='String'}) 'Remove only the requested local endpoint; preserve other mappings.'))}
                else{$steps.Add((New-PCStep 'WinInet' 'ProxyEnable' $proxy.values.ProxyEnable ([pscustomobject][ordered]@{exists=$true;value=0;kind='DWord'}) 'No remaining endpoint after removing the requested local proxy.'))}
            }
        }elseif($proxy.enabled -and ($Direct -or (Test-LocalProxyDead -Value $proxy.server -Listeners $Snapshot.listeners -QuerySucceeded $listenerKnown))){
            $steps.Add((New-PCStep 'WinInet' 'ProxyEnable' $proxy.values.ProxyEnable ([pscustomobject][ordered]@{exists=$true;value=0;kind='DWord'}) 'Disable the selected manual user proxy.'))
        }
        if($proxy.pac){$warnings.Add('PAC is configured and will be preserved; manual-proxy cleanup is not proof of direct routing.')}
    }
    if($Snapshot.availability.environment -eq 'observed'){
        foreach($row in @($Snapshot.environment|Where-Object{$_.scope -eq 'User' -and -not [string]::IsNullOrEmpty($_.value)})){
            $after=$null;$change=$false
            if($targetPorts.Count -gt 0){$r=Remove-PCProxyEndpoints $row.value $targetPorts;$change=$r.changed;if($r.value){$after=[pscustomobject][ordered]@{exists=$true;value=$r.value;kind=$row.registry.kind}}else{$after=$absent}}
            elseif($Direct -or (Test-LocalProxyDead -Value $row.value -Listeners $Snapshot.listeners -QuerySucceeded $listenerKnown)){$change=$true;$after=$absent}
            if($change){$steps.Add((New-PCStep 'UserEnv' $row.name $row.registry $after 'Change only the selected current-user proxy variable; NO_PROXY remains untouched.'))}
        }
    }
    if($Snapshot.availability.git -eq 'observed'){
        foreach($row in $Snapshot.git){
            $before=@($row.values);if(-not $before.Count){continue}
            if(-not (Get-PCValue $row 'writable' $false)){$warnings.Add('A Git proxy uses included, ambiguous or unavailable configuration; preserved.');continue}
            $after=@();$change=$false
            if($targetPorts.Count -gt 0){
                foreach($value in $before){$r=Remove-PCProxyEndpoints $value $targetPorts;if($r.changed){$change=$true};if($r.value -or -not $r.changed){$after+=@($r.value)}}
            }elseif($Direct){$change=$true}
            elseif(@($before|Where-Object{-not (Test-LocalProxyDead -Value $_ -Listeners $Snapshot.listeners -QuerySucceeded $listenerKnown)}).Count -eq 0){$change=$true}
                        if($change){
                $step=New-PCStep 'Git' $row.key $before $after 'Preserve remote/live/malformed values unless direct mode was explicitly selected.'
                $step|Add-Member -NotePropertyName target_file -NotePropertyValue $row.target_file
                $steps.Add($step)
            }
        }
    }
    if($targetPorts.Count -eq 0 -and $Snapshot.availability.routes -eq 'observed' -and $Snapshot.availability.adapters -eq 'observed'){
        $physical=@($Snapshot.routes|Where-Object{Test-PCPhysicalRoute $_ $Snapshot.adapters})
        if(-not $physical.Count){$warnings.Add('No verified physical IPv4 default route: no route deletion is planned.')}
        else{
            foreach($route in @($Snapshot.routes|Where-Object DestinationPrefix -eq '0.0.0.0/0')){
                if(Test-PCPhysicalRoute $route $Snapshot.adapters){continue}
                $index=Get-PCValue $route 'InterfaceIndex' (Get-PCValue $route 'ifIndex')
                $ad=@($Snapshot.adapters|Where-Object{(Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $index})
                $orphan=$ad.Count -eq 0 -or ($ad.Count -eq 1 -and $ad[0].Status -ne 'Up')
                $fake=[string]$route.NextHop -match '^198\.1[89]\.'
                if($orphan -or ($Direct -and $fake)){
                    $record=ConvertTo-PCRouteRecord $route
                    $step=New-PCStep 'Route' ([string]$index+':'+$record.destination) $record $null 'Remove only this ActiveStore default route after rechecking physical fallback.'
                    $step|Add-Member -NotePropertyName allow_active_fake -NotePropertyValue ([bool]($Direct -and $fake))
                    $steps.Add($step)
                }
            }
        }
    }
    if(@($Snapshot.availability.PSObject.Properties|Where-Object Value -eq 'unknown').Count){$warnings.Add('Some layers are unknown; no absence or recovery conclusion is inferred for them.')}
    # Keep these conditions private, like preimages. A stable ProxyEnable value
    # alone does not prove that the proxy server or its listener is unchanged.
    foreach($step in $steps){
        if($step.kind -eq 'WinInet'){
            $step|Add-Member -NotePropertyName preview_server -NotePropertyValue $Snapshot.systemProxy.values.ProxyServer
        }
        if($step.kind -in @('WinInet','UserEnv','Git')){
            if($targetPorts.Count -gt 0){$step|Add-Member -NotePropertyName required_closed_ports -NotePropertyValue @($targetPorts)}
            elseif(-not $Direct){
                $values=switch($step.kind){'WinInet'{@($Snapshot.systemProxy.server)}'UserEnv'{@([string]$step.before.value)}'Git'{@($step.before)}}
                $step|Add-Member -NotePropertyName required_dead_values -NotePropertyValue @($values)
            }
        }
    }
    [pscustomobject]@{schema='proxyclean.plan.v1';id=[Guid]::NewGuid().ToString('N');sid=$Snapshot.sid;observedUtc=$Snapshot.observedUtc
        mode=if($targetPorts.Count){'port'}elseif($Direct){'manual-user-direct'}else{'dead-local-cleanup'};port=$Port;ports=@($targetPorts);steps=$steps.ToArray();warnings=$warnings.ToArray()
        limits=@('WinHTTP, PAC, machine environment, URL-scoped Git and consumer configs are preserved.','Undo covers one operation, not stopped processes, DNS caches or other applications.','Already running applications may retain inherited proxy environment variables.')}
}
function ConvertTo-PCPublicPlan {
    param([Parameter(Mandatory)]$Plan)
    [pscustomobject]@{schema=$Plan.schema;id=$Plan.id;mode=$Plan.mode;observedUtc=$Plan.observedUtc;action_count=@($Plan.steps).Count
        actions=@($Plan.steps|ForEach-Object{[pscustomobject]@{resource=$_.kind+':'+$_.name;reason=$_.reason}})
        warnings=@($Plan.warnings);limits=@($Plan.limits);contains_preimages=$false}
}
function Enter-PCLock {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=New-Object Threading.Mutex($false,('Global\ProxyClean-'+$sid))
    try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){$mutex.Dispose();throw 'Another ProxyClean operation is running for this Windows user.'}
    return $mutex
}
function Get-PCJournalPath {Join-Path $env:LOCALAPPDATA 'ProxyClean\last-operation.dpapi'}
function Save-PCJournal {
    param([Parameter(Mandatory)]$Journal)
    $path=Get-PCJournalPath;[IO.Directory]::CreateDirectory((Split-Path -Parent $path))|Out-Null
    # Standard Windows current-user DPAPI avoids writing proxy credentials in plaintext.
    $secure=ConvertTo-SecureString ($Journal|ConvertTo-Json -Depth 25 -Compress) -AsPlainText -Force
    try{$text=ConvertFrom-SecureString $secure}finally{$secure.Dispose()}
    $temp=$path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
    }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Get-PCJournal {
    $path=Get-PCJournalPath;if(-not(Test-Path -LiteralPath $path)){return $null}
    $secure=ConvertTo-SecureString (Get-Content -LiteralPath $path -Raw)
    try{$credential=New-Object Management.Automation.PSCredential('journal',$secure);$journal=$credential.GetNetworkCredential().Password|ConvertFrom-Json}finally{$secure.Dispose()}
    if($journal.schema -ne 'proxyclean.undo.v1' -or $journal.sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'The undo record does not belong to this Windows user.'}
    return $journal
}
function Get-PCResourceValue {
    param([Parameter(Mandatory)]$Step)
    switch($Step.kind){
        'WinInet'{Get-PCRegistryValue -Area WinInet -Name $Step.name}
        'UserEnv'{Get-PCRegistryValue -Area UserEnv -Name $Step.name}
        'Git'{return ,@(Get-PCGitValues -Key $Step.name)}
        'Route'{
            $r=$Step.before
            $rows=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop|Where-Object{[int](Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $r.interface_index -and $_.DestinationPrefix -eq $r.destination})
            if(-not $rows.Count){return $null}
            if($rows.Count -ne 1 -or $rows[0].NextHop -ne $r.next_hop){throw 'Route changed or became ambiguous; preserved.'}
            ConvertTo-PCRouteRecord $rows[0]
        }
        default{throw 'Unsupported undo resource.'}
    }
}
function Set-PCResourceValue {
    param([Parameter(Mandatory)]$Step,[AllowNull()]$Value)
    switch($Step.kind){
        {$_ -in @('WinInet','UserEnv')}{
            if($Step.kind -eq 'WinInet'){
                if($Step.name -notin @('ProxyEnable','ProxyServer')){throw 'Unsupported WinINET field.'}
                $path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            }else{
                if($Step.name -notin @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){throw 'Unsupported environment field.'}
                $path='HKCU:\Environment'
            }
            if($Value.exists){
                if(-not(Test-Path -LiteralPath $path)){New-Item -Path $path -Force -ErrorAction Stop|Out-Null}
                $key=Get-Item -LiteralPath $path -ErrorAction Stop
                $key.SetValue($Step.name,$Value.value,[Microsoft.Win32.RegistryValueKind]$Value.kind)
            }elseif(Test-Path -LiteralPath $path){$key=Get-Item -LiteralPath $path -ErrorAction Stop;$key.DeleteValue($Step.name,$false)}
        }
        'Git'{
            if($Step.name -notin @('http.proxy','https.proxy')){throw 'Unsupported Git field.'}
            Set-PCGitAtomicValues -Step $Step -Values @($Value)
        }
        'Route'{
            $r=$Step.before
            if($null -eq $Value){
                $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
                $routes=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop)
                if(-not @($routes|Where-Object{Test-PCPhysicalRoute $_ $adapters}).Count){throw 'Physical fallback disappeared; route preserved.'}
                $target=@($routes|Where-Object{[int](Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $r.interface_index -and $_.DestinationPrefix -eq $r.destination -and $_.NextHop -eq $r.next_hop})
                if($target.Count -ne 1 -or -not(Test-PCSameValue (ConvertTo-PCRouteRecord $target[0]) $r)){throw 'Route changed before removal.'}
                $targetAdapter=@($adapters|Where-Object{[int](Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $r.interface_index})
                if(Test-PCPhysicalRoute $target[0] $adapters){throw 'Target is now a healthy physical route; preserved.'}
                $stillOrphan=$targetAdapter.Count -eq 0 -or ($targetAdapter.Count -eq 1 -and $targetAdapter[0].Status -ne 'Up')
                $explicitActiveFake=(Get-PCValue $Step 'allow_active_fake' $false) -and $r.next_hop -match '^198\.1[89]\.'
                if(-not $stillOrphan -and -not $explicitActiveFake){throw 'Target adapter recovered after preview; route preserved.'}
                Remove-NetRoute -InterfaceIndex $r.interface_index -DestinationPrefix $r.destination -NextHop $r.next_hop -PolicyStore ActiveStore -Confirm:$false -ErrorAction Stop
            }else{
                $adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object InterfaceIndex -eq $r.interface_index)
                if($adapters.Count -ne 1){throw 'Original route interface is unavailable; undo remains pending.'}
                New-NetRoute -InterfaceIndex $r.interface_index -DestinationPrefix $r.destination -NextHop $r.next_hop -RouteMetric $r.metric -PolicyStore ActiveStore -ErrorAction Stop|Out-Null
            }
        }
        default{throw 'Unsupported undo resource.'}
    }
}
function Restore-PCJournal {
    param([Parameter(Mandatory)]$Journal)
    $failures=New-Object 'Collections.Generic.List[string]'
    $failureDetails=@()
    $Journal.phase='recovering';Save-PCJournal $Journal
    $steps=@($Journal.steps)
    for($i=$steps.Count-1;$i -ge 0;$i--){
        $step=$steps[$i]
        if($step.phase -in @('planned','restored')){continue}
        try{
            $current=Get-PCResourceValue $step
            if(-not(Test-PCSameValue $current $step.before)){
                if(-not(Test-PCSameValue $current $step.after)){throw 'Resource changed after this operation.'}
                Set-PCResourceValue -Step $step -Value $step.before
                if(-not(Test-PCSameValue (Get-PCResourceValue $step) $step.before)){throw 'Undo readback failed.'}
            }
            $step.phase='restored';Save-PCJournal $Journal
        }catch{$failures.Add($step.kind+':'+$step.name);$failureDetails+=@([pscustomobject]@{resource=$step.kind+':'+$step.name;error_type=$_.Exception.GetType().FullName;error_id=$_.FullyQualifiedErrorId})}
    }
    $Journal.phase=if($failures.Count){'recovery_required'}else{'undone'};$Journal.remaining=$failures.ToArray();Save-PCJournal $Journal
    [pscustomobject]@{status=if($failures.Count){'recovery_required'}else{'recovered'};remaining=$failures.ToArray();failure_details=$failureDetails;network_recovered='not_tested'}
}
function Invoke-PCRepairPlan {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
    param([Parameter(Mandatory)]$Plan,[scriptblock]$Progress)
    if($Plan.schema -ne 'proxyclean.plan.v1'){throw 'Unsupported repair plan.'}
    if([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -or $Plan.sid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Apply must run as the same intended Windows user, never SYSTEM.'}
    $selected=@(foreach($step in @($Plan.steps)){if($PSCmdlet.ShouldProcess($step.kind+':'+$step.name,$step.reason)){$step}})
    if(-not $selected.Count){return [pscustomobject]@{status=if($WhatIfPreference){'preview'}else{'no_changes'};changed=0;network_recovered='not_tested'}}
    $lock=Enter-PCLock
    try{
        $old=Get-PCJournal
        if($old -and $old.phase -notin @('completed','undone')){throw 'An unfinished cleanup exists. Inspect or undo it before another operation.'}
        Write-PCProgress $Progress 'revalidate' '正在复查：准备修改的设置是否仍与检查结果一致…'
        try{
            foreach($step in $selected){
                Assert-PCStepCondition -Step $step
                if(-not(Test-PCSameValue (Get-PCResourceValue $step) $step.before)){throw 'Configuration changed after preview; preserved.'}
            }
        }
        catch{return [pscustomobject]@{status='plan_changed';changed=0;message=ConvertTo-PCFriendlyError $_;network_recovered='not_tested'}}
        Write-PCProgress $Progress 'backup' '正在保存修改前的设置，便于恢复…'
        $journal=[pscustomobject]@{schema='proxyclean.undo.v1';id=$Plan.id;sid=$Plan.sid;phase='applying';startedUtc=[DateTimeOffset]::UtcNow.ToString('O');steps=@($selected | ForEach-Object { $_ | ConvertTo-Json -Depth 20 | ConvertFrom-Json });remaining=@()}
        Save-PCJournal $journal
        $changed=0
        try{
            foreach($step in @($journal.steps)){
                if(-not(Test-PCSameValue (Get-PCResourceValue $step) $step.before)){throw 'Configuration changed after preview; preserved.'}
                Assert-PCStepCondition -Step $step
                Write-PCProgress $Progress 'apply' ('正在处理：'+(Get-PCStepLabel $step)+'…')
                $step.phase='prepared';Save-PCJournal $journal
                Set-PCResourceValue -Step $step -Value $step.after
                Write-PCProgress $Progress 'verify' ('正在核验：'+(Get-PCStepLabel $step)+'…')
                if(-not(Test-PCSameValue (Get-PCResourceValue $step) $step.after)){throw 'Configuration write could not be verified.'}
                $step.phase='applied';Save-PCJournal $journal;$changed++
            }
            $journal.phase='completed';Save-PCJournal $journal
        }catch{
            Write-PCProgress $Progress 'rollback' '修改未完成，正在恢复本次已经改动的设置…'
            $failureId=$_.FullyQualifiedErrorId;$recovery=Restore-PCJournal $journal
            return [pscustomobject]@{status=if($recovery.status -eq 'recovered'){'failed_rolled_back'}else{'recovery_required'};changed_before_failure=$changed;remaining=$recovery.remaining;failure_id=$failureId;failure_details=$recovery.failure_details;network_recovered='not_tested'}
        }
        [pscustomobject]@{status='applied';changed=$changed;undo_available=$true;network_recovered='not_tested';applications_may_need_restart=$true}
    }finally{try{$lock.ReleaseMutex()}finally{$lock.Dispose()}}
}
function Invoke-PCUndo {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param()
    $lock=Enter-PCLock
    try{
        $journal=Get-PCJournal
        if(-not $journal -or $journal.phase -eq 'undone'){return [pscustomobject]@{status='nothing_to_undo'}}
        if($PSCmdlet.ShouldProcess('Last ProxyClean operation','Restore only resources still matching this operation')){Restore-PCJournal $journal}
        else{[pscustomobject]@{status='preview';phase=$journal.phase;resources=@($journal.steps|ForEach-Object{$_.kind+':'+$_.name})}}
    }finally{try{$lock.ReleaseMutex()}finally{$lock.Dispose()}}
}
function Get-PCUndoSummary {
    $j=Get-PCJournal
    if(-not $j){return [pscustomobject]@{available=$false;phase='none'}}
    [pscustomobject]@{available=$j.phase -ne 'undone';phase=$j.phase;resources=@($j.steps|ForEach-Object{$_.kind+':'+$_.name});remaining=@($j.remaining)}
}
function Send-PCSettingsChanged {
    if(-not('ProxyClean.Notifications' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ProxyClean { public static class Notifications {
 [DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h,int option,IntPtr value,int size);
 [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint msg,IntPtr w,string value,uint flags,uint timeout,out IntPtr result);
}}
'@
    }
    $result=[IntPtr]::Zero
    [void][ProxyClean.Notifications]::SendMessageTimeout([IntPtr]65535,26,[IntPtr]::Zero,'Environment',2,200,[ref]$result)
    $a=[ProxyClean.Notifications]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)
    $b=[ProxyClean.Notifications]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)
    [pscustomobject]@{wininet_notified=$a -and $b;already_running_process_environment_refreshed=$false}
}
function Test-PCConnectivity {
    $curl=Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if(-not $curl){return [pscustomobject]@{status='not_available';scope='HTTP only';direct_route_proven=$false}}
    try{
        $r=Invoke-PCNative -FilePath $curl.Source -ArgumentList @('--noproxy','*','-4','--silent','--show-error','--output','NUL','--write-out','%{http_code}','--connect-timeout','5','--max-time','10','https://www.msftconnecttest.com/connecttest.txt') -TimeoutSeconds 13
        $ok=$r.stdout.Trim() -match '^2\d\d$'
        [pscustomobject]@{status=if($ok){'http_reachable'}else{'http_not_confirmed'};scope='IPv4 HTTP bypassing explicit proxies; TUN/IP routing can still apply';direct_route_proven=$false}
    }catch{[pscustomobject]@{status='http_not_confirmed';scope='IPv4 HTTP probe';direct_route_proven=$false}}
}

function Get-PCGitWriteTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    $git=Get-PCGitPath
    $r=Invoke-PCNative -FilePath $git -ArgumentList @('config','--global','--no-includes','--null','--show-origin','--get-all',$Key) -AllowedExitCodes @(0,1)
    if($r.exit_code -eq 1){return $null}
    $parts=@($r.stdout -split "`0")
    $paths=@();$values=@()
    for($i=0;$i -lt $parts.Count-1;$i+=2){
        if(-not $parts[$i].StartsWith('file:')){throw 'Git configuration origin is not a local file.'}
        $paths+=@([IO.Path]::GetFullPath($parts[$i].Substring(5)));$values+=@([string]$parts[$i+1])
    }
    $unique=@($paths|Select-Object -Unique)
    if($unique.Count -ne 1 -or -not(Test-Path -LiteralPath $unique[0] -PathType Leaf)){throw 'Git configuration origin is ambiguous.'}
    if(-not(Test-PCSameValue @($values) @(Get-PCGitValues -Key $Key))){throw 'Included Git values are preserved, not rewritten.'}
    return $unique[0]
}

function Set-PCGitAtomicValues {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Step,[AllowEmptyCollection()][object[]]$Values=@())
    $path=Get-PCValue $Step 'target_file'
    if(-not $path -or -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Recorded Git configuration is unavailable.'}
    $expected=if(Test-PCSameValue @($Values) @($Step.after)){@($Step.before)}else{@($Step.after)}
    if(-not(Test-PCSameValue @(Get-PCGitValues -Key $Step.name) @($expected))){throw 'Git proxy changed before mutation.'}
    # Use Git's existing file.lock convention, not a second global lock service.
    # Native git writes only the private prepared file; the user's config changes
    # once by atomic replacement, so interruption cannot leave a partial value list.
    $lockPath=$path+'.lock';$owned=$false
    try{
        $stream=[IO.File]::Open($lockPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $owned=$true
        try{$bytes=[IO.File]::ReadAllBytes($path);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$before=[Convert]::ToBase64String($sha.ComputeHash($bytes))}finally{$sha.Dispose()}
        $git=Get-PCGitPath
        Invoke-PCNative -FilePath $git -ArgumentList @('config','--file',$lockPath,'--no-includes','--unset-all',$Step.name) -AllowedExitCodes @(0,5)|Out-Null
        foreach($value in $Values){Invoke-PCNative -FilePath $git -ArgumentList @('config','--file',$lockPath,'--add',$Step.name,[string]$value)|Out-Null}
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$current=[Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($path)))}finally{$sha.Dispose()}
        if($current -cne $before -or -not(Test-PCSameValue @(Get-PCGitValues -Key $Step.name) @($expected))){throw 'Git configuration changed before replacement; preserved.'}
        [IO.File]::Replace($lockPath,$path,[NullString]::Value);$owned=$false
    }finally{if($owned -and (Test-Path -LiteralPath $lockPath)){Remove-Item -LiteralPath $lockPath -Force}}
}
function Remove-PCProxyEndpoints {
    param([string]$Value,[int[]]$Ports)
    $current=$Value;$changed=$false
    foreach($port in $Ports){$r=Remove-PCProxyEndpoint -Value $current -Port $port;if($r.changed){$changed=$true};$current=$r.value}
    [pscustomobject]@{changed=$changed;value=$current}
}
