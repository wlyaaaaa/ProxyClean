#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[switch]$AsJson,[switch]$SmokeTest,
    [ValidateSet('Control','Clean','Direct','Status','WifiSoft','WifiReset','IPv6Toggle','IPv6Status','StopPort')][string]$InitialAction='Control',
    [ValidateRange(0,65535)][int]$Port=0,[string]$InterfaceAlias,[string]$ExpectedSid,[ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
if($AsJson){ConvertTo-PCPublicSnapshot (Get-PCSnapshot)|ConvertTo-Json -Depth 12;return}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$window=$null
$script:pc=@{ui=@{};job=$null;inspection=$null;pending=$null;intent='Inspect';copy=$null;closing=$false;ticks=0;admin=(Test-PCAdministrator);initial=$false;lastMessage='';direct=$false;resumeAction=$null;legacyClient=$ExpectedClient}
function Set-PCScreen {
    param([string]$Title,[string]$Message,[string]$Primary='重新检查',[string]$Intent='Inspect',[string]$Tone='good',[object[]]$Actions=@())
    $pc.ui.Headline.Text=$Title;$pc.ui.Explanation.Text=$Message
    $pc.ui.Primary.Content=$Primary;$pc.intent=$Intent;$pc.ui.ActionItems.ItemsSource=@($Actions)
    $pc.ui.Eyebrow.Text=switch($Tone){'warning'{'需要你确认'}'error'{'有一项需要处理'}default{'检查与操作结果'}}
    $pc.ui.Hero.Background=[Windows.Media.BrushConverter]::new().ConvertFromString($(if($Tone -eq 'error'){'#FFF7F2'}else{'#F1FAF5'}))
    $pc.ui.Recheck.Visibility=if($Intent -eq 'Inspect'){'Collapsed'}else{'Visible'}
}
function Add-PCLog {
    param([string]$Message)
    $pc.lastMessage=$Message
    $pc.ui.ProcessLog.Items.Insert(0,((Get-Date -Format 'HH:mm:ss')+'  '+$Message))
    if($pc.ui.ProcessLog.Items.Count -gt 60){$pc.ui.ProcessLog.Items.RemoveAt($pc.ui.ProcessLog.Items.Count-1)}

    $pc.ui.CurrentStage.Text=$Message
}
function Set-PCBusy {
    param([bool]$Busy,[bool]$ReadOnly=$false)
    $pc.ui.Primary.IsEnabled=-not $Busy;$pc.ui.Recheck.IsEnabled=-not $Busy
    $pc.ui.UndoButton.IsEnabled=-not $Busy;$pc.ui.AdvancedBody.IsEnabled=-not $Busy
    $pc.ui.Progress.Visibility=if($Busy){'Visible'}else{'Collapsed'}
    $pc.ui.Progress.IsIndeterminate=$Busy
    $pc.ui.CancelButton.Visibility=if($Busy -and $ReadOnly){'Visible'}else{'Collapsed'}
    $pc.ui.CancelButton.IsEnabled=$true
}
function Start-PCWork {
    param([string]$Action,[hashtable]$Options=@{})
    if($pc.job){return}
    $pc.ui.PageScroll.ScrollToTop()
    $readOnly=$Action -in @('Inspect','Connectivity','StopPreview','IPv6Status','ExitProbe')
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
            $result=Invoke-PCWorkflow -Action $Action @Options -Progress $progress -SkipConnectivityChecks -Confirm:$false
            if($Control.cancel -and $Control.readOnly){[pscustomobject]@{action=$Action;status='cancelled';message='检查已取消，没有修改网络设置。'}}else{$result}
        }catch{[pscustomobject]@{action=$Action;status='failed';message=ConvertTo-PCFriendlyError $_;error_type=$_.Exception.GetType().FullName}}
    }
    [void]$worker.AddScript($body.ToString()).AddArgument($PSScriptRoot).AddArgument($Action).AddArgument($Options).AddArgument($queue).AddArgument($control)
    $pc.pending=$null;$pc.intent='Inspect';$pc.ui.ActionItems.ItemsSource=@();$pc.ui.ProcessLog.Items.Clear()
    $pc.ui.Primary.Content='正在处理…';$pc.ui.Eyebrow.Text=if($readOnly){'只读检查'}else{'正在执行你确认的操作'}
    $pc.ui.Headline.Text=if($Action -eq 'Inspect'){'正在检查代理设置'}else{'正在处理，请查看下方进度'}
    $pc.ui.Explanation.Text=if($readOnly){'本次只读取状态，不会修改网络设置。'}else{'窗口会显示实际执行步骤。修改与恢复过程中不会强行中断。'}
    Set-PCBusy $true $readOnly;Add-PCLog '正在准备…'
    try{
        $async=$worker.BeginInvoke()
        $pc.job=@{worker=$worker;runspace=$runspace;async=$async;queue=$queue;control=$control;watch=[Diagnostics.Stopwatch]::StartNew();action=$Action;readOnly=$readOnly}
    }catch{$worker.Dispose();$runspace.Dispose();Set-PCBusy $false;Set-PCScreen '操作未启动' (ConvertTo-PCFriendlyError $_) -Tone error}
}
function Request-PCElevation {
    param([string]$Action='Control')
    try{
        $launch=@{Action='Control';Elevated=$true;InitialAction=$Action;ExpectedSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
        if($pc.ui.PortInput.Text -match '^\d+$'){$launch.Port=[int]$pc.ui.PortInput.Text}
        if($pc.ui.AdapterCombo.SelectedItem){$launch.InterfaceAlias=$pc.ui.AdapterCombo.SelectedItem.name}
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
            $pc.inspection=$Result;$pc.pending=$Result.plan;$pc.direct=$Result.plan.mode -eq 'manual-user-direct'
            $v=$Result.view
            Set-PCScreen $v.title $v.message $v.primary $v.intent $v.tone $v.actions
            if($v.requires_admin -and -not $pc.admin -and $v.intent -eq 'Repair'){$pc.ui.Primary.Content='授权后继续'}
            $pc.ui.UndoButton.Visibility=if($Result.undo.available -and $v.intent -ne 'Undo'){'Visible'}else{'Collapsed'}
            $pc.ui.DetailsText.Text=$Result.details
            $pc.copy=[pscustomobject]@{snapshot=$Result.snapshot;plan=ConvertTo-PCPublicPlan $Result.plan;undo=$Result.undo}|ConvertTo-Json -Depth 14
            $clients=@([pscustomobject]@{label='请选择程序，或在右侧输入端口';port=0})
            $clients+=@($Result.snapshot.listener_candidates|Sort-Object port,process -Unique|ForEach-Object{[pscustomobject]@{label=$_.process+'  ·  端口 '+$_.port;port=$_.port}})
            $pc.ui.ClientCombo.ItemsSource=$clients;$pc.ui.ClientCombo.SelectedIndex=0
            $adapters=@([pscustomobject]@{label='请选择要操作的物理网卡';name=''})
            $adapters+=@($Result.adapters|ForEach-Object{[pscustomobject]@{label=$_.name+'  ·  '+$(if($_.status -eq 'Up'){'已连接'}else{'未连接'});name=$_.name}})
            $pc.ui.AdapterCombo.ItemsSource=$adapters;$pc.ui.AdapterCombo.SelectedIndex=0
            if($InterfaceAlias){foreach($item in $adapters){if($item.name -eq $InterfaceAlias){$pc.ui.AdapterCombo.SelectedItem=$item;break}}}
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
            $message='修改后的设置已重新读取并核验。尚未测试网页；已经运行的程序可能需要重新打开。'
            if($Result.notification -and -not $Result.notification.wininet_notified){$message+=' Windows 通知未确认送达，但设置已经保存。'}
            Set-PCScreen ("已修复 $count 项设置") $message '检查联网情况' 'Connectivity'
            $pc.ui.UndoButton.Visibility='Visible'
        }
        'no_changes'{Set-PCScreen '没有需要修改的设置' '没有写入配置，也没有刷新缓存。可以检查联网情况，或重新检查代理。' '检查联网情况' 'Connectivity'}
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
    if($Result.status -notin @('inspected','stop_preview')){
        $pc.copy=$Result|ConvertTo-Json -Depth 14
        $pc.ui.DetailsText.Text=$pc.ui.Headline.Text+"`r`n"+$pc.ui.Explanation.Text
        $operation=Get-PCValue $Result 'operation' (Get-PCValue $Result 'configuration')
        $remaining=@(Get-PCValue $operation 'remaining' @())
        if($remaining.Count){$pc.ui.DetailsText.Text+="`r`n`r`n尚需处理：`r`n"+($remaining -join "`r`n")}
        if(Get-PCValue $Result 'error_type'){$pc.ui.DetailsText.Text+="`r`n错误类型："+$Result.error_type}
    }
    $pc.ui.CopyButton.IsEnabled=[bool]$pc.copy
    Add-PCLog $pc.ui.Headline.Text
}
function Invoke-PCPrimary {
    switch($pc.intent){
        'Repair'{
            if(-not $pc.pending){Start-PCWork Inspect;return}
            if(-not $pc.admin -and @($pc.pending.steps|Where-Object kind -eq 'Route').Count){Request-PCElevation $(if($pc.direct){'Direct'}else{'Clean'});return}
            Start-PCWork Repair @{Plan=$pc.pending}
        }
        'Stop'{if($pc.pending){Start-PCWork Stop @{Plan=$pc.pending}}else{Start-PCWork Inspect}}
        'Undo'{
            if(Confirm-PCAction '只恢复上次修改中仍未被其他程序改动的设置。不会重启已经结束的程序。继续？' '恢复上次修改'){Start-PCWork Undo}
        }
        'Elevate'{Request-PCElevation}
        default{Start-PCWork $pc.intent}
    }
}
function Invoke-PCAdapterAction {
    param([string]$Action,[string]$Label)
    $selected=$pc.ui.AdapterCombo.SelectedItem
    if(-not $selected -or -not $selected.name){[void][Windows.MessageBox]::Show($window,'请先在“网卡与连接”下选择要操作的物理网卡。','请选择网卡','OK','Information');return}
    if(-not $pc.admin){
        if(Confirm-PCAction ($Label+'需要管理员权限。授权后会回到检查页面，不会自动修改网卡。') '需要管理员权限'){Request-PCElevation 'WifiReset'}
        return
    }
    if(Confirm-PCAction ($Label+'：'+$selected.name+"。`n`n可能暂时断网；代理设置的恢复按钮不能撤销这项网卡操作。正在远程控制这台电脑时，请谨慎选择。") $Label){
        Start-PCWork $Action @{InterfaceAlias=[string]$selected.name}
    }
}
try{
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($ExpectedSid -and $ExpectedSid -ne $sid){throw '启动账户发生变化。请用原 Windows 账户授权，避免修改其他用户的代理设置。'}
    $reader=[Xml.XmlReader]::Create((Join-Path $PSScriptRoot 'ControlCenter.xaml'))
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Dispose()}
    $names=@('PageScroll','ModeBadge','Hero','Eyebrow','Headline','Explanation','ActionItems','Primary','Recheck','UndoButton','CancelButton','Progress','CurrentStage','ProcessExpander','ProcessLog','DetailsExpander','DetailsText','CopyButton','AdvancedExpander','AdvancedBody','DirectButton','ConnectivityButton','ExitButton','ClientCombo','PortInput','StopPreviewButton','AdapterCombo','WifiSoftButton','WifiResetButton','DnsButton','IPv6StatusButton','IPv6EnableButton','IPv6DisableButton')
    foreach($name in $names){$pc.ui[$name]=$window.FindName($name);if(-not $pc.ui[$name]){throw ('界面组件缺失：'+$name)}}
    $window.Width=[Math]::Min($window.Width,[Windows.SystemParameters]::WorkArea.Width-32)
    $window.Height=[Math]::Min($window.Height,[Windows.SystemParameters]::WorkArea.Height-40)
    if($Port){$pc.ui.PortInput.Text=[string]$Port}
    $pc.ui.Primary.Add_Click({Invoke-PCPrimary})
    $pc.ui.Recheck.Add_Click({Start-PCWork Inspect})
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
    $pc.ui.DnsButton.Add_Click({if(Confirm-PCAction '只清空本机域名解析缓存，不修改 DNS 服务器。此操作不能通过代理设置恢复按钮撤销。继续？' '刷新域名缓存'){Start-PCWork FlushDns}})
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
            if($InitialAction -notin @('Control','Clean','Direct')){$pc.ui.AdvancedExpander.IsExpanded=$true}
            if($InitialAction -eq 'StopPort' -and $Port){Start-PCWork StopPreview @{Port=$Port;ExpectedClient=$pc.legacyClient}}
            elseif($InitialAction -eq 'IPv6Status'){Start-PCWork IPv6Status}
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
    $timer.Start();[void]$window.ShowDialog()
    if($SmokeTest){if(-not $pc.smokeResult){throw 'GUI smoke test returned no result.'};$pc.smokeResult|ConvertTo-Json -Compress;if($pc.smokeResult.status -ne 'pass'){throw 'GUI smoke test failed.'}}
}catch{
    if($SelfTest -or $SmokeTest){throw}
    [void][Windows.MessageBox]::Show(('ProxyClean 未能打开。请确认整个文件夹完整，并使用 Windows PowerShell 5.1 或 PowerShell 7。'+"`n`n"+$_.Exception.Message),'启动失败','OK','Error')
}finally{
    if(Get-Variable timer -ErrorAction SilentlyContinue){$timer.Stop()}
    if($pc.job -and $pc.job.async.IsCompleted){$pc.job.worker.Dispose();$pc.job.runspace.Dispose();$pc.job=$null}
}
