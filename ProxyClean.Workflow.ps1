#Requires -Version 5.1
# Shared application workflow. UI callbacks receive Chinese messages, never preimages.
function Write-PCProgress {
    param([scriptblock]$Progress,[string]$Stage,[string]$Message)
    if($Progress){& $Progress $Stage $Message|Out-Null}
}
function Get-PCStepLabel {
    param($Step)
    switch($Step.kind){
        'WinInet'{'Windows 手动代理设置'}
        'UserEnv'{"终端代理变量 $($Step.name)"}
        'Git'{"Git 代理设置 $($Step.name)"}
        'Route'{if(Get-PCValue $Step 'allow_active_fake' $false){'代理隧道的默认网络路由（将移除）'}else{'已失效的默认网络路由'}}
        default{'选定的代理设置'}
    }
}
function Assert-PCStepCondition {
    param([Parameter(Mandatory)]$Step)
    $server=Get-PCValue $Step 'preview_server'
    if($null -ne $server -and -not(Test-PCSameValue (Get-PCRegistryValue -Area WinInet -Name ProxyServer) $server)){
        throw 'PC_PROXY_SERVER_CHANGED'
    }
    $values=@(Get-PCValue $Step 'required_dead_values' @())
    $ports=@(Get-PCValue $Step 'required_closed_ports' @());$oldPort=[int](Get-PCValue $Step 'required_closed_port' 0);if($oldPort){$ports+=@($oldPort)}
    if(-not $values.Count -and -not $ports.Count){return}
    try{$listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop)}catch{throw 'PC_LISTENER_UNKNOWN'}
    if($ports.Count){
        foreach($row in $listeners){
            if([int]$row.LocalPort -notin $ports){continue}
            [Net.IPAddress]$address=$null
            if([Net.IPAddress]::TryParse([string]$row.LocalAddress,[ref]$address) -and
                ([Net.IPAddress]::IsLoopback($address) -or $address.Equals([Net.IPAddress]::Any) -or $address.Equals([Net.IPAddress]::IPv6Any))){throw 'PC_PROXY_RESTARTED'}
        }
    }
    foreach($value in $values){
        if(-not(Test-LocalProxyDead -Value ([string]$value) -Listeners $listeners)){throw 'PC_PROXY_RESTARTED'}
    }
}
function ConvertTo-PCFriendlyError {
    param($ErrorRecord)
    $message=if($ErrorRecord -is [string]){$ErrorRecord}else{[string]$ErrorRecord.Exception.Message}
    switch -Regex ($message){
        'PC_CANCELLED|OperationCanceled'{return '检查已取消，没有修改网络设置。'}
        'Service identity changed|Process identity changed'{return '所选程序或服务已变化，本次没有继续操作。请重新检查后再确认。'}
        'PC_PROXY_SERVER_CHANGED|Configuration changed|Git proxy changed|Route changed|identity changed'{return '设置在检查后发生了变化。本次已停止，请重新检查后再操作。'}
        'PC_PROXY_RESTARTED|adapter recovered'{return '代理或网卡已经恢复运行，本次不再清理。请重新检查。'}
        'PC_LEGACY_CLIENT_CHANGED'{return '旧快捷方式的端口已属于其他程序，未选择任何结束操作。请重新选择实际程序。'}
        'PC_LISTENER_UNKNOWN'{return '暂时无法确认代理是否仍在运行。本次没有继续清理，请重新检查。'}
        'unfinished cleanup'{return '上次修改尚未恢复完成。请先点击“恢复上次修改”。'}
        'Another ProxyClean'{return '另一个 ProxyClean 窗口正在修改设置。完成后再试。'}
        'elevat|administrator|Access.*denied|拒绝访问|Unauthorized'{return '这项操作需要管理员权限，请点击“授权后继续”。'}
        'same intended Windows user|intended Windows user|never SYSTEM'{return '请从当前登录的 Windows 桌面打开本工具，不要以系统账户运行。'}
        'Exactly one intended physical adapter'{return '没有找到唯一的目标网卡，请在更多操作中明确选择网卡。'}
        'not using DHCP|static configuration'{return '这块网卡使用固定地址，未执行自动地址刷新。请保留原配置。'}
        'Physical fallback disappeared'{return '当前没有可确认的备用网络连接，已保留原路由。'}
        'IPv6 change failed and one or more'{return 'IPv6 修改失败，部分网卡尚未恢复。请打开 Windows 网络设置检查选定网卡。'}
        'IPv6 change failed; this run restored'{return 'IPv6 修改没有完成，本次已恢复改动过的绑定。'}
        default{return '操作没有完成，未将失败显示为成功。请重新检查；技术详情中保留了脱敏错误编号。'}
    }
}
function Get-PCCheckView {
    param([Parameter(Mandatory)]$Snapshot,[Parameter(Mandatory)]$Plan,[Parameter(Mandatory)]$Undo)
    $unknown=@($Snapshot.availability.PSObject.Properties|Where-Object Value -eq 'unknown')
    $count=@($Plan.steps).Count
    $blocked=$Undo.phase -notin @('none','undone','completed')
    $actions=@($Plan.steps|ForEach-Object{Get-PCStepLabel $_}|Select-Object -Unique)
    $message='检查不会修改设置，也不会退出代理程序。'
    if($blocked){
        $title=if($Undo.phase -eq 'unreadable'){'无法读取上次恢复记录'}else{'请先处理上次未完成的修改'}
        $message=if($Undo.phase -eq 'unreadable'){'未开始新的修改。请使用原 Windows 账户打开，或查看技术详情。'}else{'先恢复上次修改，再开始新的修复，避免覆盖尚未处理的设置。'}
        $primary=if($Undo.available){'恢复上次修改'}else{'重新检查'};$intent=if($Undo.available){'Undo'}else{'Inspect'};$tone='warning'
    }elseif($count){
        $title=if($Plan.mode -eq 'manual-user-direct'){"将调整 $count 项代理设置"}else{"发现 $count 项可修复设置"}
        $message=if($Plan.mode -eq 'manual-user-direct'){'这是你主动选择的操作，可能影响正在使用的代理。将关闭下列手动代理设置，并按列出的范围处理隧道路由；不会退出客户端。'}else{'下列设置仍指向失效的代理或连接。修复前会保存原设置，并再次确认问题仍然存在。'}
        $primary=if($Plan.mode -eq 'manual-user-direct'){'确认调整这些设置'}else{'修复这些设置'};$intent='Repair';$tone='warning'
    }elseif($unknown.Count){
        $title='部分检查未完成';$message='已检查的部分没有可自动清理的设置。未确认的部分不会被当成正常或失效，请查看详情。'
        $primary='重新检查';$intent='Inspect';$tone='warning'
    }else{
        $title='没有发现可清理的失效代理';$message='目前无需清理。正在运行的代理会保留；这不代表所有网站或应用都能联网。'
        $primary='检查联网情况';$intent='Connectivity';$tone='good'
    }
    if($unknown.Count -and $count -and -not $blocked){$message+=' 另有部分检查未完成，未确认的设置会保留。'}
    [pscustomobject]@{title=$title;message=$message;primary=$primary;intent=$intent;tone=$tone;actions=$actions;change_count=$count;requires_admin=(@($Plan.steps|Where-Object kind -eq 'Route').Count -gt 0);blocked=$blocked}
}
function Format-PCInspection {
    param([Parameter(Mandatory)]$Snapshot)
    $lines=New-Object 'Collections.Generic.List[string]'
    $labels=@{listeners='本机代理进程';adapters='网卡';routes='默认网络路由';wininet='Windows 手动代理';environment='终端代理变量';git='Git 代理';winhttp='Windows 服务代理';docker='Docker 代理'}
    $states=@{observed='已检查';unknown='未能确认';not_installed='未安装';not_inspected='未检查'}
    foreach($item in $Snapshot.availability.PSObject.Properties){
        $label=if($labels.ContainsKey($item.Name)){$labels[$item.Name]}else{$item.Name}
        $state=if($states.ContainsKey([string]$item.Value)){$states[[string]$item.Value]}else{'未能确认'}
        $lines.Add($label+'：'+$state)
    }
    $lines.Add('')
    if($null -eq $Snapshot.system_proxy.enabled){$lines.Add('Windows 手动代理：未能确认')}
    elseif($Snapshot.system_proxy.enabled){$lines.Add('Windows 手动代理：已开启（'+$Snapshot.system_proxy.server+'）')}
    else{$lines.Add('Windows 手动代理：未开启')}
    if($Snapshot.system_proxy.pac_configured){$lines.Add('自动代理脚本：已配置，本工具不会自动删除。')}
    foreach($e in @($Snapshot.endpoints)){
        $state=switch($e.state){'listening'{'对应端口正在运行'}'dead'{'对应本机端口未运行'}'remote'{'远程代理，保留'}default{'状态未能确认，保留'}}
        $lines.Add($e.endpoint+'：'+$state)
    }
    if(@($Snapshot.tun_routes).Count){$lines.Add('检测到活动代理隧道路由，默认修复会保留。')}
    if($Snapshot.conclusion.consumer_local_proxy_pin_present){$lines.Add('Docker 仍指定了本机代理；需要在 Docker 中单独调整。')}
    foreach($row in @($Snapshot.environment|Where-Object configured)){
        $scope=switch($row.scope){'User'{'当前用户'}'Machine'{'系统级（不自动修改）'}'Process'{'当前进程（可能保留旧值）'}default{$row.scope}}
        $lines.Add($scope+' '+$row.name+'：'+$row.endpoint)
    }
    $lines.Add('');$lines.Add('检查范围：代理设置与端口状态。远程代理、自动代理脚本、系统级设置和应用自身配置不会被偷偷改写。')
    return $lines -join [Environment]::NewLine
}
function Invoke-PCWorkflow {
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
    param([ValidateSet('Inspect','Diagnose','DisconnectPreview','Disconnect','DisconnectForce','Repair','Undo','Connectivity','StopPreview','Stop','WifiSoft','WifiReset','IPv6Status','IPv6Enable','IPv6Disable','ExitProbe','FlushDns')][string]$Action='Inspect',
        $Plan,[string]$ClientKey,[switch]$Direct,[ValidateRange(0,65535)][int]$Port=0,[string]$InterfaceAlias,[ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any',
        [switch]$SkipConnectivityChecks,[scriptblock]$Progress)
    try{
        if($Action -in @('Disconnect','DisconnectForce','Repair','Undo','Stop','WifiSoft','WifiReset','IPv6Enable','IPv6Disable') -and
            -not $PSCmdlet.ShouldProcess('选定的设置或程序','执行已确认的操作')){
            return [pscustomobject]@{action=$Action;status='preview'}
        }
        switch($Action){
            'Diagnose'{
                $inspection=Invoke-PCWorkflow Inspect -Progress $Progress
                if($inspection.status -ne 'inspected'){return $inspection}
                $probe=[pscustomobject]@{status='not_tested'}
                if(-not $inspection.view.blocked -and -not @($inspection.plan.steps).Count){
                    Write-PCProgress $Progress 'connectivity' '没有发现可修复的代理设置，正在测试基础网页连接…'
                    $probe=Test-PCConnectivity
                }
                return [pscustomobject]@{status='diagnosed';inspection=$inspection;connectivity=$probe}
            }
            'DisconnectPreview'{return Get-PCClientClosePreview -ClientKey $ClientKey -PreviousPlan $Plan -Progress $Progress}
            {$_ -in @('Disconnect','DisconnectForce')}{
                if(-not $Plan){throw 'Please preview the client first.'}
                return Invoke-PCClientClose -Plan $Plan -Force:($Action -eq 'DisconnectForce') -Progress $Progress -Confirm:$false -WhatIf:$WhatIfPreference
            }
            'Inspect'{
                $snapshot=Get-PCSnapshot -Progress $Progress
                Write-PCProgress $Progress 'plan' '正在整理检查结果与可恢复记录…'
                $plan=Get-PCRepairPlan -Snapshot $snapshot -Direct:$Direct
                try{$undo=Get-PCUndoSummary}catch{$undo=[pscustomobject]@{available=$false;phase='unreadable'}}
                $public=ConvertTo-PCPublicSnapshot $snapshot
                $view=Get-PCCheckView -Snapshot $public -Plan $plan -Undo $undo
                $clients=@();$clientObservation='observed'
                try{
                    $endpoints=@(if($snapshot.systemProxy -and $snapshot.systemProxy.enabled){Get-ProxyEndpoints $snapshot.systemProxy.server})
                    $clients=@(ConvertTo-PCPublicClients @(Get-PCClientInventory -Listeners $snapshot.listeners -Endpoints $endpoints))
                }catch{$clientObservation='unknown'}
                $adapters=@($snapshot.adapters|Where-Object{(Get-PCValue $_ 'HardwareInterface') -eq $true}|ForEach-Object{[pscustomobject]@{name=[string]$_.Name;status=[string]$_.Status}})
                Write-PCProgress $Progress 'done' '检查完成，没有修改网络设置。'
                return [pscustomobject]@{action=$Action;status='inspected';clients=$clients;client_observation=$clientObservation;proxy_summary=(Get-PCProxySummary $public $clients $clientObservation);view=$view;plan=$plan;snapshot=$public;undo=$undo;adapters=$adapters;details=Format-PCInspection $public}
            }
            'Repair'{
                if(-not $Plan){$Plan=Get-PCRepairPlan -Snapshot (Get-PCSnapshot -Progress $Progress) -Direct:$Direct}
                $applied=Invoke-PCRepairPlan -Plan $Plan -Progress $Progress -Confirm:$false -WhatIf:$WhatIfPreference
                $notification=$null;$probe=[pscustomobject]@{status='not_tested'}
                if($applied.status -eq 'applied'){
                    Write-PCProgress $Progress 'notify' '设置已核验，正在通知 Windows 使用新设置…'
                    try{$notification=Send-PCSettingsChanged}catch{$notification=[pscustomobject]@{wininet_notified=$false;already_running_process_environment_refreshed=$false}}
                }
                if(-not $SkipConnectivityChecks -and -not $WhatIfPreference -and $applied.status -in @('applied','no_changes')){
                    Write-PCProgress $Progress 'connectivity' '正在测试网页连接，结果与设置修复分别报告…'
                    $probe=Test-PCConnectivity
                }
                Write-PCProgress $Progress 'done' '本次操作已结束，请查看上方结果。'
                return [pscustomobject]@{schema='proxyclean.cleanup-result.v1';action=$Action;status=$applied.status;plan=ConvertTo-PCPublicPlan $Plan;configuration=$applied;notification=$notification;dns_cache='not_changed';connectivity=$probe;all_applications_direct='not_proven'}
            }
            'Undo'{
                Write-PCProgress $Progress 'undo' '正在恢复仍属于上次修改的设置…'
                $result=Invoke-PCUndo -Confirm:$false -WhatIf:$WhatIfPreference
                if($result.status -eq 'recovered'){try{[void](Send-PCSettingsChanged)}catch{}}
                return [pscustomobject]@{action=$Action;status=$result.status;operation=$result}
            }
            'Connectivity'{
                Write-PCProgress $Progress 'connectivity' '正在连接微软测试网页；不会修改代理设置…'
                $result=Test-PCConnectivity
                return [pscustomobject]@{action=$Action;status=$result.status;operation=$result}
            }
            'StopPreview'{
                if(-not $Port){throw 'Please select a port.'}
                Write-PCProgress $Progress 'process' '正在确认这个端口由哪些程序占用…'
                $plan=Get-PCStopPlan -Port $Port
                Assert-PCExpectedClient -Plan $plan -ExpectedClient $ExpectedClient
                return [pscustomobject]@{action=$Action;status='stop_preview';plan=$plan;public=ConvertTo-PCPublicStopPlan $plan}
            }
            'Stop'{
                if(-not $Plan){throw 'Please preview the processes first.'}
                Write-PCProgress $Progress 'stop' '正在结束已确认的程序，并等待端口关闭…'
                $result=Invoke-PCStopPlan -Plan $Plan -Confirm:$false -WhatIf:$WhatIfPreference
                return [pscustomobject]@{action=$Action;status=$result.status;operation=$result}
            }
            {$_ -in @('WifiSoft','WifiReset')}{
                $adapter=Get-PCWifiAdapter -InterfaceAlias $InterfaceAlias
                Write-PCProgress $Progress 'network' ('正在处理网卡 '+$adapter.Name+'，连接可能暂时中断…')
                $mode=if($Action -eq 'WifiSoft'){'SoftReset'}else{'AdapterReset'}
                $result=Invoke-PCWifiReset -Adapter $adapter -Mode $mode -Confirm:$false -WhatIf:$WhatIfPreference
                return [pscustomobject]@{action=$Action;status=$result.status;operation=$result}
            }
            'IPv6Status'{
                Write-PCProgress $Progress 'ipv6' '正在读取 IPv6 网卡设置…'
                return [pscustomobject]@{action=$Action;status='ipv6_observed';operation=Get-PCIPv6Snapshot}
            }
            {$_ -in @('IPv6Enable','IPv6Disable')}{
                $mode=if($Action -eq 'IPv6Enable'){'Enable'}else{'Disable'}
                Write-PCProgress $Progress 'ipv6' ('正在修改所选网卡的 IPv6 设置：'+$InterfaceAlias+'…')
                $result=Invoke-PCIPv6Change -Mode $mode -InterfaceAlias $InterfaceAlias -Confirm:$false -WhatIf:$WhatIfPreference
                return [pscustomobject]@{action=$Action;status=$result.status;operation=$result}
            }
            'ExitProbe'{
                Write-PCProgress $Progress 'exit' '正在比较联网出口，只显示是否相同，不公开 IP 地址…'
                $snapshot=Get-PCSnapshot -SkipConsumers
                return [pscustomobject]@{action=$Action;status='exits_observed';operation=@(Get-PCExitComparison $snapshot)}
            }
            'FlushDns'{
                if($PSCmdlet.ShouldProcess('本机 DNS 缓存','刷新域名解析缓存，不更改 DNS 服务器')){
                    Write-PCProgress $Progress 'dns' '正在刷新域名解析缓存…'
                    [void](Invoke-PCNative -FilePath (Join-Path $env:WINDIR 'System32\ipconfig.exe') -ArgumentList @('/flushdns'))
                    return [pscustomobject]@{action=$Action;status='dns_flushed'}
                }
                return [pscustomobject]@{action=$Action;status='preview'}
            }
        }
    }catch{
        $cancel=[string]$_.Exception.Message -match 'PC_CANCELLED'
        return [pscustomobject]@{action=$Action;status=if($cancel){'cancelled'}else{'failed'};message=ConvertTo-PCFriendlyError $_;error_type=$_.Exception.GetType().FullName}
    }
}

function Assert-PCExpectedClient {
    param($Plan,[string]$ExpectedClient='Any')
    if($ExpectedClient -eq 'Any'){return}
    $pattern=switch($ExpectedClient){'TAG'{'(?i)^(?:tag|mihomo-tag|tag-mihomo)$'}'ClashVerge'{'(?i)^(?:clash-verge|verge-mihomo)$'}'FlyingBird'{'(?i)^FlyingBird(?:Core|HelperService)?$'}default{throw 'PC_LEGACY_CLIENT_CHANGED'}}
    if(@($Plan.processes|Where-Object{$_.name -notmatch $pattern}).Count){throw 'PC_LEGACY_CLIENT_CHANGED'}
}