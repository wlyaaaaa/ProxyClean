#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[switch]$AsJson,[switch]$SmokeTest,
    [ValidateSet('Control','Clean','Direct','Status','WifiSoft','WifiReset','IPv6Toggle','IPv6Status','StopPort','Undo','IPv6Enable','IPv6Disable','FlushDns','Disconnect')][string]$InitialAction='Control',
    [ValidateRange(0,65535)][int]$Port=0,[string]$InterfaceAlias,[string]$ClientKey,[string]$ExpectedSid,[ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any')
$ErrorActionPreference='Stop'

$window=$null;$maintenance=$null;$detailsWindow=$null
$script:pc=@{ui=@{};job=$null;inspection=$null;pending=$null;intent='Inspect';copy=$null;closing=$false;ticks=0;admin=$false;initial=$false;lastMessage='';direct=$false;resumeAction=$null;legacyClient=$ExpectedClient;clientKey=$ClientKey;forcePreview=$false;closeContext=$null;home=$false;maintenanceMode=$false;clients=@()}
function Set-PCScreen {
    param([string]$Title,[string]$Message,[string]$Primary='返回首页',[string]$Intent='Home',[string]$Tone='good',[object[]]$Actions=@())
    $pc.home=$false
    $pc.ui.Headline.Text=$Title;$pc.ui.Explanation.Text=$Message
    $pc.ui.Primary.Content=$Primary;$pc.intent=$Intent;$pc.ui.ActionItems.ItemsSource=@($Actions)
    $pc.ui.Eyebrow.Text=switch($Tone){'warning'{'下一步'}'error'{'需要处理'}default{'处理结果'}}
    $pc.ui.Hero.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Tone -eq 'error'){'#FFF7F2'}else{'#F1FAF5'}))
    $pc.ui.DisconnectButton.Visibility='Collapsed';$pc.ui.ClientPickerPanel.Visibility='Collapsed'
    $pc.ui.HomeButton.Visibility=if($Intent -eq 'Home'){'Collapsed'}else{'Visible'}
}
function Show-PCHome {
    if(-not $pc.inspection){Start-PCWork Inspect;return}
    $r=$pc.inspection;$v=$r.view
    if($v.blocked){Set-PCScreen $v.title $v.message $v.primary $v.intent 'warning';return}
    $message=if($v.change_count){'发现 '+$v.change_count+' 项可修复设置。点击下面的绿色按钮，先查看修复范围。'}elseif($v.tone -eq 'warning'){'部分状态未能确认。上不了网时，点击下面的绿色按钮继续检查。'}else{'没有发现失效的代理设置。能正常上网就不用操作。'}
    Set-PCScreen $r.proxy_summary $message '检查并修复上网问题' 'Diagnose'
    $pc.home=$true;$pc.ui.Eyebrow.Text='当前状态';$pc.ui.HomeButton.Visibility='Collapsed';$pc.ui.DisconnectButton.Visibility='Visible'
    $pc.ui.UndoButton.Visibility=if($r.undo.available){'Visible'}else{'Collapsed'}
    $pc.ui.CurrentStage.Text='打开程序只检查状态，不会自动修改网络。'
}
function Open-PCMaintenance {
    if($pc.job){return}
    $pc.ui.AdvancedExpander.IsExpanded=$true
    $maintenance.Owner=$window
    [void]$maintenance.ShowDialog()
}
function Add-PCLog {
    param([string]$Message)
    $pc.lastMessage=$Message
    [void]$pc.ui.ProcessLog.Items.Add(((Get-Date -Format 'HH:mm:ss')+'  '+$Message))
    if($pc.ui.ProcessLog.Items.Count -gt 80){$pc.ui.ProcessLog.Items.RemoveAt(0)}
    $pc.ui.CurrentStage.Text=$Message
}
function Set-PCBusy {
    param([bool]$Busy,[bool]$ReadOnly=$false)
    foreach($name in @('Primary','DisconnectButton','UndoButton','AdvancedBody','HomeButton','MaintenanceButton')){$pc.ui[$name].IsEnabled=-not $Busy}
    $pc.ui.Progress.Visibility=if($Busy){'Visible'}else{'Collapsed'};$pc.ui.Progress.IsIndeterminate=$Busy
    $pc.ui.CancelButton.Visibility=if($Busy -and $ReadOnly){'Visible'}else{'Collapsed'};$pc.ui.CancelButton.IsEnabled=$true
}
function Start-PCWork {
    param([string]$Action,[hashtable]$Options=@{})
    if($pc.job){return}
    if($maintenance -and $maintenance.IsVisible){$maintenance.Hide()}
    if($detailsWindow -and $detailsWindow.IsVisible){$detailsWindow.Hide()}
    $pc.home=$false;$pc.ui.DisconnectButton.Visibility='Collapsed';$pc.ui.ClientPickerPanel.Visibility='Collapsed'
    $pc.ui.HomeButton.Visibility='Collapsed';$pc.ui.UndoButton.Visibility='Collapsed'
    $pc.resumeAction=switch($Action){
        {$_ -in @('DisconnectPreview','Disconnect','DisconnectForce')}{'Disconnect'}
        'Repair'{if($pc.direct){'Direct'}else{'Clean'}}
        {$_ -in @('Stop','StopPreview')}{'StopPort'}
        'Inspect'{if($Options.Direct){'Direct'}else{'Control'}}
        default{$Action}
    }
    $pc.ui.PageScroll.ScrollToTop()
    $readOnly=$Action -in @('Inspect','Diagnose','DisconnectPreview','Connectivity','StopPreview','IPv6Status','ExitProbe')
    $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $control=[hashtable]::Synchronized(@{cancel=$false;readOnly=$readOnly})
    $worker=[PowerShell]::Create()
    $runspace=[RunspaceFactory]::CreateRunspace();$runspace.ApartmentState='STA';$runspace.ThreadOptions='ReuseThread';$runspace.Open();$worker.Runspace=$runspace
    $body={param($Root,$Action,$Options,$Queue,$Control)
        $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
        Import-Module (Join-Path $Root 'ProxyClean.Common.psm1') -Force
        $progress={param($Stage,$Message)
            if($Control.cancel -and $Control.readOnly){throw 'PC_CANCELLED'}
            $Queue.Enqueue([pscustomobject]@{stage=$Stage;message=$Message})
        }.GetNewClosure()
        try{
            $result=Invoke-PCWorkflow -Action $Action @Options -Progress $progress -Confirm:$false
            if($Control.cancel -and $Control.readOnly){[pscustomobject]@{action=$Action;status='cancelled';message='检查已取消，没有修改网络设置。'}}else{$result}
        }catch{[pscustomobject]@{action=$Action;status='failed';message=ConvertTo-PCFriendlyError $_;error_type=$_.Exception.GetType().FullName}}
    }
    [void]$worker.AddScript($body.ToString()).AddArgument($PSScriptRoot).AddArgument($Action).AddArgument($Options).AddArgument($queue).AddArgument($control)
    $pc.pending=$null;$pc.intent='Inspect';$pc.ui.ActionItems.ItemsSource=@();$pc.ui.ProcessLog.Items.Clear()
    $pc.ui.Primary.Content='正在处理…';$pc.ui.Eyebrow.Text=if($readOnly){'只读检查'}else{'正在执行你确认的操作'}
    $pc.ui.Headline.Text=switch($Action){'Inspect'{'正在检查代理设置'}'Diagnose'{'正在检查上网问题'}'DisconnectPreview'{'正在确认要关闭的代理'}default{'正在处理你确认的操作'}}
    $pc.ui.Explanation.Text=if($readOnly){'本次只读取状态，不会修改网络设置。'}else{'窗口会显示实际执行步骤。修改与恢复过程中不会强行中断。'}
    Set-PCBusy $true $readOnly;Add-PCLog '正在准备…'
    try{
        $async=$worker.BeginInvoke()
        $pc.job=@{worker=$worker;runspace=$runspace;async=$async;queue=$queue;control=$control;watch=[Diagnostics.Stopwatch]::StartNew();action=$Action;readOnly=$readOnly}
    }catch{$worker.Dispose();$runspace.Dispose();Set-PCBusy $false;Set-PCScreen '操作未启动' (ConvertTo-PCFriendlyError $_) -Tone error}
}
function Get-PCElevationOptions {
    param([string]$Action='Control')
    $launch=@{Action='Control';Elevated=$true;InitialAction=$Action;ExpectedSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;ExpectedClient=$pc.legacyClient}
    [int]$selectedPort=0
    if([int]::TryParse($pc.ui.PortInput.Text,[ref]$selectedPort) -and $selectedPort -ge 1 -and $selectedPort -le 65535){$launch.Port=$selectedPort}
    if($pc.ui.AdapterCombo.SelectedItem -and $pc.ui.AdapterCombo.SelectedItem.name){$launch.InterfaceAlias=[string]$pc.ui.AdapterCombo.SelectedItem.name}
    if($pc.clientKey){$launch.ClientKey=$pc.clientKey};return $launch
}
function Request-PCElevation {
    param([string]$Action='Control')
    try{
        $launch=Get-PCElevationOptions $Action
        & (Join-Path $PSScriptRoot 'Launch-ProxyClean.ps1') @launch
        Add-PCLog '已请求管理员窗口。新窗口会重新检查，不会自动执行修改。'
        $window.Close()
    }catch{Set-PCScreen '没有取得管理员权限' '你取消了授权，或 Windows 未能打开管理员窗口。当前没有因此修改设置。';Add-PCLog '授权未完成，原窗口仍可使用。'}
}
function Confirm-PCAction {
    param([string]$Message,[string]$Title='确认操作')
    return [Windows.MessageBox]::Show($window,$Message,$Title,'YesNo','Warning','No') -eq 'Yes'
}
function Show-PCResult {
    param($Result)
    $pc.ui.ModeBadge.Text=if($pc.admin){'管理员窗口'}else{'本机检查'}
    switch($Result.status){
        'inspected'{
            $pc.inspection=$Result;$pc.clients=@($Result.clients);$pc.pending=$Result.plan;$pc.direct=$Result.plan.mode -eq 'manual-user-direct'
            $pc.ui.DetailsText.Text=$Result.details
            $pc.copy=[pscustomobject]@{snapshot=$Result.snapshot;clients=$Result.clients;plan=ConvertTo-PCPublicPlan $Result.plan;undo=$Result.undo}|ConvertTo-Json -Depth 14
            $clients=@([pscustomobject]@{label='选择客户端的端口';port=0})
            foreach($client in $pc.clients){foreach($portValue in $client.ports){$clients+=@([pscustomobject]@{label=$client.label+' · '+$portValue;port=$portValue})}}
            $pc.ui.ClientCombo.ItemsSource=$clients;$pc.ui.ClientCombo.SelectedIndex=0
            $adapters=@([pscustomobject]@{label='请选择要操作的物理网卡';name=''})
            $adapters+=@($Result.adapters|ForEach-Object{[pscustomobject]@{label=$_.name+'  ·  '+$(if($_.status -eq 'Up'){'已连接'}else{'未连接'});name=$_.name}})
            $pc.ui.AdapterCombo.ItemsSource=$adapters;$pc.ui.AdapterCombo.SelectedIndex=0
            if($InterfaceAlias){foreach($item in $adapters){if($item.name -eq $InterfaceAlias){$pc.ui.AdapterCombo.SelectedItem=$item;break}}}
            if($pc.direct){$v=$Result.view;Set-PCScreen $v.title $v.message $v.primary $v.intent $v.tone $v.actions}
            else{Show-PCHome}
        }
        'diagnosed'{
            Show-PCResult $Result.inspection
            $v=$Result.inspection.view
            if($v.blocked){return}
            if($v.change_count){
                Set-PCScreen $v.title '将修复下面这些失效设置，不会关闭正在使用的代理。确认后保存原设置、修复并自动核验。' '开始修复' 'Repair' 'warning' $v.actions
                if($v.requires_admin -and -not $pc.admin){$pc.ui.Primary.Content='授权后继续修复'}
            }elseif($Result.connectivity.status -eq 'http_reachable'){
                $title=if($v.tone -eq 'warning'){'测试网页可连接，部分设置未确认'}else{'没有发现代理故障，测试网页可连接'}
                Set-PCScreen $title '没有修改网络设置。个别网站或应用仍有问题时，不需要反复清理代理。'
            }else{Set-PCScreen '没有找到可自动修复的代理问题' '测试网页也未能确认连通。请检查 Wi-Fi 或网线，以及代理客户端是否可用；本次没有重启网卡或修改无关设置。' -Tone warning}
        }
        'choose_client'{
            $pc.ui.DisconnectClients.ItemsSource=@($Result.clients);$pc.ui.DisconnectClients.SelectedIndex=-1
            Set-PCScreen '当前运行了多个代理' '请选择要关闭的客户端。其他客户端和它们的设置会保留。' '继续' 'ChooseClient' 'warning'
            $pc.ui.ClientPickerPanel.Visibility='Visible'
        }
        'client_needs_admin'{
            $pc.clientKey=$Result.key;$pc.resumeAction='Disconnect'
            Set-PCScreen ('关闭'+$Result.label+'需要授权') '这个客户端使用了受保护的进程或辅助服务。授权后先显示关闭范围，再由你确认，不会直接断开连接。' '授权后继续' 'Elevate' 'warning'
        }
        'client_preview'{
            $pc.pending=$Result.plan;$pc.clientKey=$Result.plan.key
            $force=[bool]$pc.forcePreview;$pc.forcePreview=$false
            $label=$Result.plan.label
            $message=if($force){'正常退出未完成。将强制结束这个客户端的剩余进程，相关连接会中断；不会关闭其他代理。设置可恢复，已退出的程序需要重新打开。'}else{'将请求这个客户端及其辅助服务正常退出，确认退出后清理它留下的代理设置。相关连接会中断；不会关闭其他代理，也不会重启网卡。'}
            $button=if($force){'确认强制关闭'+$label}else{'确认关闭'+$label}
            $intent=if($force){'DisconnectForce'}else{'Disconnect'}
            Set-PCScreen ('关闭'+$label+'，恢复普通上网') $message $button $intent 'warning' @($Result.actions)
            $pc.copy=$Result.public|ConvertTo-Json -Depth 8
        }
        'client_still_running'{
            $pc.clientKey=$Result.key;$pc.closeContext=$Result.previous_plan
            if($Result.force_attempted){Set-PCScreen ($Result.label+'仍未完全退出') '客户端可能自动重启，或端口已被其他程序占用。没有清理仍在使用的设置，请从客户端的托盘菜单退出后再检查。' -Tone warning}
            else{Set-PCScreen ($Result.label+'没有完全退出') '正常退出未完成，尚未清理代理设置。下一步可以查看强制关闭范围，或返回首页。' '继续关闭…' 'ForcePreview' 'warning'}
        }
        'client_settings_incomplete'{
            $label=$Result.label
            Set-PCScreen ($label+'已退出，设置尚未处理完') '请继续检查失效代理设置。已结束的进程不会自动重启，未确认的配置不会被覆盖。' '检查并修复上网问题' 'Diagnose' 'warning'
            if($Result.settings.status -eq 'recovery_required'){Set-PCScreen '代理已退出，部分设置需要恢复' '请先恢复本次未完成的修改，再继续检查。' '恢复上次修改' 'Undo' 'error'}
        }
        'client_closed'{
            $remaining=@($Result.remaining)
            $message=if($remaining.Count){($remaining -join '；')+'。已保留这些设置，尚不能确认已恢复普通上网。'}elseif($Result.connectivity.status -eq 'http_reachable'){'客户端已退出，相关代理引用已清理，基础网页测试通过。已打开的应用可能需要重新打开。'}else{'客户端已退出，相关代理引用已处理，但基础网页测试尚未通过。请检查 Wi-Fi 或网线连接。'}
            Set-PCScreen ('已关闭'+$Result.label) $message -Tone $(if($remaining.Count -or $Result.connectivity.status -ne 'http_reachable'){'warning'}else{'good'})
            if($Result.settings.status -eq 'applied'){$pc.ui.UndoButton.Visibility='Visible'}
        }
        'no_client'{
            $p=$Result.snapshot.system_proxy
            if($p.enabled -or $p.pac_configured -or @($Result.snapshot.tun_routes).Count){Set-PCScreen '没有找到可直接退出的客户端' '仍检测到代理设置。先检查是否有失效配置；有效的远程代理、自动代理脚本和未识别的隧道不会直接删除。' '检查并修复上网问题' 'Diagnose' 'warning'}
            else{Set-PCScreen '没有发现正在运行的代理客户端' 'Windows 手动代理未开启。本次没有修改设置；这不等于已验证所有应用的联网状态。'}
        }
        'stop_preview'{
            $pc.copy=$Result.public|ConvertTo-Json -Depth 10
            if(-not @($Result.plan.processes).Count){Set-PCScreen '这个端口没有正在运行的程序' '没有需要结束的程序，也没有修改任何设置。'}
            else{
                $pc.pending=$Result.plan
                $names=@($Result.plan.processes|ForEach-Object{$_.name+'（进程 '+$_.pid+'）'})
                Set-PCScreen '确认要结束这些程序吗？' '这会强制结束以下完整进程，中断相关连接。端口关闭后，只清理引用该端口的代理设置。“恢复上次修改”不会重新启动程序。' '确认结束这些程序' 'Stop' 'warning' $names
            }
            $pc.ui.PageScroll.ScrollToTop()
        }
        'applied'{
            $count=Get-PCValue $Result.configuration 'changed' 0
            $message=if($Result.connectivity.status -eq 'http_reachable'){'设置已核验，基础网页测试通过。已打开的应用可能需要重新打开。'}else{'设置已修复，但基础网页测试尚未通过。不要重复清理同一设置，请检查 Wi-Fi、网线或代理客户端。'}
            if($Result.notification -and -not $Result.notification.wininet_notified){$message+=' Windows 通知未确认送达，但设置已经保存。'}
            Set-PCScreen ("已修复 $count 项设置") $message
            $pc.ui.UndoButton.Visibility='Visible'
        }
        'no_changes'{Set-PCScreen '没有需要修改的设置' '没有写入配置，也没有刷新缓存。'}
        'plan_changed'{Set-PCScreen '情况已变化，未继续清理' $Result.configuration.message -Tone warning}
        'failed_rolled_back'{$pc.ui.UndoButton.Visibility='Collapsed';Set-PCScreen '修改未完成，本次改动已恢复' '操作过程中发现变化或写入失败。已经恢复本次改动，请重新检查后再决定。' -Tone warning}
        'recovery_required'{Set-PCScreen '部分设置还需要恢复' '没有覆盖其他程序后续修改的设置。请查看详情，并尝试恢复上次修改。' '恢复上次修改' 'Undo' 'error';$pc.ui.UndoButton.Visibility='Collapsed'}
        'recovered'{Set-PCScreen '已恢复上次修改的设置' '只恢复了仍属于上次操作的设置。没有重启已结束的进程，也不代表网络一定恢复。';$pc.ui.UndoButton.Visibility='Collapsed'}
        'nothing_to_undo'{Set-PCScreen '没有可恢复的修改' '尚无修改记录，或上次修改已经恢复。';$pc.ui.UndoButton.Visibility='Collapsed'}
        'http_reachable'{Set-PCScreen '测试网页可以连接' '微软测试网页已成功响应。其他网站和应用可能不同；这项测试也不证明流量绕过了代理隧道。'}
        'http_not_confirmed'{Set-PCScreen '测试网页暂时未能连接' '不能据此认定所有网络都中断。先重新检查代理；不要反复清理同一项设置。' -Tone warning}
        'not_available'{Set-PCScreen '当前无法执行网页测试' '没有找到系统网页测试工具。代理检查结果仍可使用。' -Tone warning}
        'closed'{Set-PCScreen '所选程序已结束，端口已关闭' '已经核对端口关闭，并处理了相关代理引用。恢复设置不会重新启动这些程序。';if($Result.operation.settings.status -eq 'applied'){$pc.ui.UndoButton.Visibility='Visible'}}
        'incomplete'{Set-PCScreen '操作没有完整完成' '部分程序未能结束、重新启动了，或关联设置未处理完。没有把局部完成当成全部成功，请重新检查。' -Tone error}
        'adapter_ready'{Set-PCScreen '网卡已经重新就绪' '选定网卡已连接并取得 IPv4 地址。尚未测试网页。' '检查联网情况' 'Connectivity'}
        'needs_attention'{Set-PCScreen '网卡尚未恢复就绪' '操作已经结束，但还没有确认可用连接。请在 Windows 网络设置中检查该网卡。' -Tone warning}
        'binding_verified'{Set-PCScreen 'IPv6 设置已经核验' '所选物理网卡的 IPv6 设置已回读确认。没有改变其他应用的代理配置。'}
        'dns_flushed'{Set-PCScreen '域名解析缓存已刷新' '没有更改 DNS 服务器或代理设置。尚未测试网页。' '检查联网情况' 'Connectivity'}
        'ipv6_observed'{
            $rows=@($Result.operation.adapters|ForEach-Object{$_.name+'：'+$(switch($_.binding_state){'enabled'{'已启用 IPv6'}'disabled'{'已禁用 IPv6'}default{'未能确认'}})})
            Set-PCScreen 'IPv6 状态已读取' '以下是网卡绑定状态，不是公网连接结果。' -Actions $rows
        }
        'exits_observed'{
            $rows=@($Result.operation|ForEach-Object{
                $name=if($_.path -eq 'process-default'){'本进程默认路径'}else{'指定本机代理端口 '+($_.path -replace '^forced-local-','')}
                $state=if($_.status -eq 'observed'){'出口组 '+($_.exit_group -replace '^exit-group-','')}else{'未能确认'}
                $name+'：'+$state
            })
            Set-PCScreen '联网出口比较已结束' '组号相同表示这次观测到相同出口，不能据此识别具体客户端。未公开原始 IP 地址。' -Actions $rows
        }
        'cancelled'{Set-PCScreen '检查已取消' '没有修改网络设置。点击重新检查即可继续。'}
        'failed'{
            Set-PCScreen '操作没有完成' $Result.message -Tone error
            if($Result.message -match '管理员' -and -not $pc.admin){$pc.ui.Primary.Content='授权后继续';$pc.intent='Elevate'}
        }
        default{Set-PCScreen '操作已结束' '请重新检查当前设置，再决定下一步。'}
    }
    if($Result.status -notin @('inspected','diagnosed','stop_preview','client_preview')){
        if($Result.status -eq 'client_still_running'){$pc.copy=[pscustomobject]@{status=$Result.status;message=$Result.message;client=ConvertTo-PCPublicClientPlan $Result.previous_plan}|ConvertTo-Json -Depth 10}
        else{$pc.copy=$Result|ConvertTo-Json -Depth 14}
        $pc.ui.DetailsText.Text=$pc.ui.Headline.Text+"`r`n"+$pc.ui.Explanation.Text
        $operation=Get-PCValue $Result 'operation' (Get-PCValue $Result 'configuration')
        $remaining=@(Get-PCValue $operation 'remaining' @())
        if($remaining.Count){$pc.ui.DetailsText.Text+="`r`n`r`n尚需处理：`r`n"+($remaining -join "`r`n")}
        if(Get-PCValue $Result 'error_type'){$pc.ui.DetailsText.Text+="`r`n错误类型："+$Result.error_type}
    }
    $pc.ui.CopyButton.IsEnabled=[bool]$pc.copy
    if(-not $pc.home){Add-PCLog $pc.ui.Headline.Text}
}
function Invoke-PCPrimary {
    switch($pc.intent){
        'Home'{$pc.forcePreview=$false;Start-PCWork Inspect}
        'ChooseClient'{
            $selected=$pc.ui.DisconnectClients.SelectedItem
            if(-not $selected){$pc.ui.Explanation.Text='请先选择要关闭的客户端。其他客户端会保留。';return}
            $pc.clientKey=$selected.key;Start-PCWork DisconnectPreview @{ClientKey=$pc.clientKey}
        }
        'ForcePreview'{$pc.forcePreview=$true;Start-PCWork DisconnectPreview @{ClientKey=$pc.clientKey;Plan=$pc.closeContext}}
        {$_ -in @('Disconnect','DisconnectForce')}{
            if(-not $pc.pending){Start-PCWork DisconnectPreview @{ClientKey=$pc.clientKey};return}
            Start-PCWork $pc.intent @{Plan=$pc.pending}
        }
        'Repair'{
            if(-not $pc.pending){Start-PCWork Inspect;return}
            if(-not $pc.admin -and @($pc.pending.steps|Where-Object kind -eq 'Route').Count){Request-PCElevation $(if($pc.direct){'Direct'}else{'Clean'});return}
            Start-PCWork Repair @{Plan=$pc.pending}
        }
        'Stop'{if($pc.pending){Start-PCWork Stop @{Plan=$pc.pending}}else{Start-PCWork Inspect}}
        'Undo'{
            try{$undo=Get-PCUndoSummary}catch{Set-PCScreen '无法读取恢复记录' (ConvertTo-PCFriendlyError $_) -Tone error;return}
            if(-not $pc.admin -and @($undo.resources|Where-Object{$_ -like 'Route:*'}).Count){Request-PCElevation 'Undo';return}
            if(Confirm-PCAction '只恢复上次修改中仍未被其他程序改动的设置。不会重启已经结束的程序。继续？' '恢复上次修改'){Start-PCWork Undo}
        }
        'Elevate'{Request-PCElevation $(if($pc.resumeAction){$pc.resumeAction}else{'Control'})}
        {$_ -in @('WifiSoft','WifiReset','IPv6Enable','IPv6Disable')}{
            $labels=@{WifiSoft='刷新连接';WifiReset='重启网卡';IPv6Enable='启用 IPv6';IPv6Disable='禁用 IPv6'}
            Invoke-PCAdapterAction $pc.intent $labels[$pc.intent]
        }
        'FlushDns'{Invoke-PCDnsAction}
        default{Start-PCWork $pc.intent}
    }
}
function Invoke-PCAdapterAction {
    param([string]$Action,[string]$Label)
    $selected=$pc.ui.AdapterCombo.SelectedItem
    if(-not $selected -or -not $selected.name){[void][Windows.MessageBox]::Show($window,'请先在“网卡与连接”下选择要操作的物理网卡。','请选择网卡','OK','Information');return}
    if(-not $pc.admin){
        if(Confirm-PCAction ($Label+'需要管理员权限。授权后会回到检查页面，不会自动修改网卡。') '需要管理员权限'){Request-PCElevation $Action}
        return
    }
    if(Confirm-PCAction ($Label+'：'+$selected.name+"。`n`n可能暂时断网；代理设置的恢复按钮不能撤销这项网卡操作。正在远程控制这台电脑时，请谨慎选择。") $Label){
        Start-PCWork $Action @{InterfaceAlias=[string]$selected.name}
    }
}
function Invoke-PCDnsAction {
    if(Confirm-PCAction '只清空本机域名解析缓存，不修改 DNS 服务器。此操作不能通过代理设置恢复按钮撤销。继续？' '刷新域名缓存'){Start-PCWork FlushDns}
}
function Show-PCInitialAction {
    param([string]$Action)
    if($pc.inspection.view.blocked){return}
    switch($Action){
        'Disconnect'{Start-PCWork DisconnectPreview @{ClientKey=$pc.clientKey}}
        'Clean'{Start-PCWork Diagnose}
        'StopPort'{if($Port){Start-PCWork StopPreview @{Port=$Port;ExpectedClient=$pc.legacyClient}}}
        'IPv6Status'{Start-PCWork IPv6Status}
        'Status'{$detailsWindow.Owner=$window;[void]$detailsWindow.ShowDialog()}
        'Undo'{
            $pc.ui.UndoButton.Visibility='Collapsed'
            if($pc.inspection.undo.available){Set-PCScreen '准备恢复上次修改' '会先确认恢复范围，只恢复仍属于上次操作的设置。不会重新启动已结束的程序。' '恢复上次修改' 'Undo'}
            else{Set-PCScreen '没有可恢复的修改' '尚无修改记录，或上次修改已经恢复。'}
        }
        'FlushDns'{Set-PCScreen '准备刷新域名缓存' '只刷新缓存，不更换 DNS 服务器。确认后才执行。' '刷新域名缓存…' 'FlushDns'}
        {$_ -in @('WifiSoft','WifiReset','IPv6Enable','IPv6Disable','IPv6Toggle')}{
            $labels=@{WifiSoft='刷新连接';WifiReset='重启网卡';IPv6Enable='启用 IPv6';IPv6Disable='禁用 IPv6';IPv6Toggle='选择 IPv6 操作'}
            if($Action -eq 'IPv6Toggle'){Set-PCScreen $labels[$Action] '请在下方选择物理网卡，再点击“启用 IPv6”或“禁用 IPv6”。确认前不会修改设置。' '查看 IPv6 状态' 'IPv6Status'}
            else{Set-PCScreen ('准备'+$labels[$Action]) '请在下方选择物理网卡，再点击对应操作。连接可能暂时中断，确认前不会修改设置。' ($labels[$Action]+'…') $Action 'warning'}
            $pc.ui.AdvancedExpander.IsExpanded=$true
            $pc.ui.AdapterCombo.BringIntoView();Open-PCMaintenance
        }
    }
}
try{
    if(-not $AsJson){Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase}
    Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
    if($AsJson){ConvertTo-PCPublicSnapshot (Get-PCSnapshot)|ConvertTo-Json -Depth 12;return}
    $pc.admin=Test-PCAdministrator
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($ExpectedSid -and $ExpectedSid -ne $sid){throw '启动账户发生变化。请用原 Windows 账户授权，避免修改其他用户的代理设置。'}
    $reader=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'ControlCenter.xaml'))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    foreach($entry in @(@{file='Maintenance.xaml';name='maintenance'},@{file='Details.xaml';name='detailsWindow'})){
        $xr=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot $entry.file))
        try{Set-Variable -Name $entry.name -Value ([Windows.Markup.XamlReader]::Load($xr))}finally{$xr.Dispose()}
    }
    $maintenance.Add_Closing({param($sender,$event)if(-not $pc.closing){$event.Cancel=$true;$sender.Hide()}})
    $detailsWindow.Add_Closing({param($sender,$event)if(-not $pc.closing){$event.Cancel=$true;$sender.Hide()}})
    $names=@('PageScroll','ModeBadge','Hero','Eyebrow','Headline','Explanation','ActionItems','Primary','DisconnectButton','ClientPickerPanel','DisconnectClients','HomeButton','ViewDetailsButton','MaintenanceButton','UndoButton','CancelButton','Progress','CurrentStage','ProcessExpander','ProcessLog','DetailsExpander','DetailsText','CopyButton','AdvancedExpander','AdvancedBody','DirectButton','ConnectivityButton','ExitButton','ClientCombo','PortInput','StopPreviewButton','AdapterCombo','WifiSoftButton','WifiResetButton','DnsButton','IPv6StatusButton','IPv6EnableButton','IPv6DisableButton')
    foreach($name in $names){$pc.ui[$name]=$window.FindName($name);if(-not $pc.ui[$name]){$pc.ui[$name]=$maintenance.FindName($name)};if(-not $pc.ui[$name]){$pc.ui[$name]=$detailsWindow.FindName($name)};if(-not $pc.ui[$name]){throw ('界面组件缺失：'+$name)}}
    $window.Width=[Math]::Min($window.Width,[Windows.SystemParameters]::WorkArea.Width-32)
    $window.Height=[Math]::Min($window.Height,[Windows.SystemParameters]::WorkArea.Height-40)
    if($Port){$pc.ui.PortInput.Text=[string]$Port}
    $pc.ui.Primary.Add_Click({Invoke-PCPrimary})
    $pc.ui.HomeButton.Add_Click({$pc.forcePreview=$false;Start-PCWork Inspect})
    $pc.ui.DisconnectButton.Add_Click({$pc.clientKey=$null;$pc.closeContext=$null;$pc.forcePreview=$false;Start-PCWork DisconnectPreview})
    $pc.ui.MaintenanceButton.Add_Click({Open-PCMaintenance})
    $pc.ui.ViewDetailsButton.Add_Click({$detailsWindow.Owner=$window;[void]$detailsWindow.ShowDialog()})
    $pc.ui.UndoButton.Add_Click({$pc.intent='Undo';Invoke-PCPrimary})
    $pc.ui.CancelButton.Add_Click({if($pc.job -and $pc.job.readOnly){$pc.job.control.cancel=$true;$pc.ui.CancelButton.IsEnabled=$false;Add-PCLog '正在取消，当前只读步骤结束后停止。'}})
    $pc.ui.CopyButton.Add_Click({try{[Windows.Clipboard]::SetText([string]$pc.copy);Add-PCLog '已复制脱敏诊断。'}catch{Add-PCLog '剪贴板暂时被占用，请再点一次复制。'}})
    $pc.ui.DirectButton.Add_Click({$pc.ui.PageScroll.ScrollToTop();Start-PCWork Inspect @{Direct=$true}})
    $pc.ui.ConnectivityButton.Add_Click({Start-PCWork Connectivity})
    $pc.ui.ExitButton.Add_Click({if(Confirm-PCAction '将请求 ipify 的公网 IP 查询服务，并比较默认路径与可识别的本机代理路径。只显示匿名分组，不修改设置。继续？' '比较联网出口'){Start-PCWork ExitProbe}})
    $pc.ui.ClientCombo.Add_SelectionChanged({if($pc.ui.ClientCombo.SelectedItem -and $pc.ui.ClientCombo.SelectedItem.port){$pc.ui.PortInput.Text=[string]$pc.ui.ClientCombo.SelectedItem.port}})
    $pc.ui.PortInput.Add_TextChanged({$pc.legacyClient='Any';if($pc.intent -eq 'Stop'){$pc.pending=$null;Set-PCScreen '端口已改变，请重新查看结束范围' '新的端口尚未确认，本次不会结束任何程序。' -Tone warning}})
    $pc.ui.StopPreviewButton.Add_Click({
        [int]$selectedPort=0
        if(-not [int]::TryParse($pc.ui.PortInput.Text,[ref]$selectedPort) -or $selectedPort -lt 1 -or $selectedPort -gt 65535){[void][Windows.MessageBox]::Show($window,'请选择程序，或输入 1 到 65535 之间的端口。','请选择端口','OK','Information');return}
        Start-PCWork StopPreview @{Port=$selectedPort;ExpectedClient=$pc.legacyClient}
    })
    $pc.ui.WifiSoftButton.Add_Click({Invoke-PCAdapterAction WifiSoft '刷新连接'})
    $pc.ui.WifiResetButton.Add_Click({Invoke-PCAdapterAction WifiReset '重启网卡'})
    $pc.ui.IPv6EnableButton.Add_Click({Invoke-PCAdapterAction IPv6Enable '启用 IPv6'})
    $pc.ui.IPv6DisableButton.Add_Click({Invoke-PCAdapterAction IPv6Disable '禁用 IPv6'})
    $pc.ui.IPv6StatusButton.Add_Click({Start-PCWork IPv6Status})
    $pc.ui.DnsButton.Add_Click({Invoke-PCDnsAction})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        if(-not $pc.job){return}
        $pc.ticks++;$job=$pc.job;$event=$null
        while($job.queue.TryDequeue([ref]$event)){Add-PCLog $event.message;$event=$null}
        $pc.ui.CurrentStage.Text=$pc.lastMessage+'  ·  已用 '+[int]$job.watch.Elapsed.TotalSeconds+' 秒'
        if(-not $job.async.IsCompleted){return}
        try{
            $output=@($job.worker.EndInvoke($job.async))
            if(-not $output.Count){throw '工作线程没有返回结果。'}
            $result=$output[-1]
        }catch{$result=[pscustomobject]@{status='failed';message='执行没有返回完整结果，请重新检查。';error_type=$_.Exception.GetType().FullName}}
        finally{$job.worker.Dispose();$job.runspace.Dispose();$pc.job=$null;Set-PCBusy $false}
        $pc.renderFailure=$false
        try{Show-PCResult $result}
        catch{
            $pc.renderFailure=$true;$pc.pending=$null;$pc.copy=$null;$pc.ui.CopyButton.IsEnabled=$false
            Set-PCScreen '结果显示未完成，请重新检查' '没有根据不完整的显示继续执行操作。重新检查可以读取当前真实设置。' -Tone error
        }
        $pc.ui.PageScroll.ScrollToTop()
        if($SmokeTest){
            $pc.smokeResult=[pscustomobject]@{schema='proxyclean.ui-smoke.v1';status=if($result.status -eq 'inspected' -and $pc.ticks -gt 0 -and -not $pc.renderFailure){'pass'}else{'fail'};result=$result.status;dispatcher_ticks=$pc.ticks;progress_messages=$pc.ui.ProcessLog.Items.Count;shown=$true;mutations=$false;headline=$pc.ui.Headline.Text}
            $window.Close();return
        }
        if($pc.closing){$window.Close();return}
        if(-not $pc.initial){
            $pc.initial=$true
            if($result.status -eq 'inspected' -and -not $pc.renderFailure){Show-PCInitialAction $InitialAction}
        }
    })
    $window.Add_ContentRendered({if(-not $pc.initial -and -not $pc.job){Start-PCWork Inspect @{Direct=($InitialAction -eq 'Direct')}}})
    $window.Add_Closing({param($sender,$event)
        if($pc.job){
            $event.Cancel=$true
            if($pc.job.readOnly){$pc.closing=$true;$pc.job.control.cancel=$true;Add-PCLog '正在结束只读检查，随后关闭窗口。'}
            else{[void][Windows.MessageBox]::Show($window,'正在修改或恢复设置。为避免只完成一半，本次操作结束后才能关闭窗口。','操作尚未结束','OK','Information')}
        }
    })
    if($SelfTest){[pscustomobject]@{schema='proxyclean.ui-test.v2';status='constructed';controls=$names.Count;theme='white-green';shown=$false;automatic_mutations=$false}|ConvertTo-Json -Compress;return}
    $timer.Start();[void]$window.ShowDialog();$pc.closing=$true;$maintenance.Close();$detailsWindow.Close()
    if($SmokeTest){if(-not $pc.smokeResult){throw 'GUI smoke test returned no result.'};$pc.smokeResult|ConvertTo-Json -Compress;if($pc.smokeResult.status -ne 'pass'){throw 'GUI smoke test failed.'}}
}catch{
    if($SelfTest -or $SmokeTest -or $AsJson){throw}
    $message='ProxyClean 未能打开。请保留完整文件夹，重新解压后双击“00-打开 ProxyClean”。需要 Windows PowerShell 5.1 或 PowerShell 7。'
    if($ExpectedSid -and $ExpectedSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){$message='启动账户发生变化，未开始检查或修改。请使用原 Windows 账户授权后再打开，不要切换为另一位管理员。'}
    if('Windows.MessageBox' -as [type]){[void][Windows.MessageBox]::Show($message,'启动失败','OK','Error')}
    else{[void](New-Object -ComObject WScript.Shell).Popup($message,0,'启动失败',16)}
}finally{
    if(Get-Variable timer -ErrorAction SilentlyContinue){$timer.Stop()}
    if($pc.job -and $pc.job.async.IsCompleted){$pc.job.worker.Dispose();$pc.job.runspace.Dispose();$pc.job=$null}
}
