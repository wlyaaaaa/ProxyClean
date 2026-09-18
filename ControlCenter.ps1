#Requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest,[switch]$AsJson)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
if($AsJson){ConvertTo-PCPublicSnapshot (Get-PCSnapshot)|ConvertTo-Json -Depth 12;return}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$form=New-Object Windows.Forms.Form;$form.Text='ProxyClean 网络诊断与修复';$form.Width=950;$form.Height=740;$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$layout=New-Object Windows.Forms.TableLayoutPanel;$layout.Dock='Fill';$layout.RowCount=4;$layout.ColumnCount=1
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',75)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',45)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',100)))
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$intro=New-Object Windows.Forms.Label;$intro.Dock='Fill';$intro.Padding='12,10,12,0'
$intro.Text="先诊断或预览，再决定是否执行；每次只撤销仍属于上次操作的设置。`n关闭此窗口不会改变网络。暂停/恢复代理客户端仍由客户端自己负责。"
$options=New-Object Windows.Forms.FlowLayoutPanel;$options.Dock='Fill';$options.Padding='10,0,0,0'
$direct=New-Object Windows.Forms.CheckBox;$direct.Text='明确关闭手动用户代理（不是全系统直连）';$direct.Width=370
$portLabel=New-Object Windows.Forms.Label;$portLabel.Text='目标本地端口：';$portLabel.AutoSize=$true
$port=New-Object Windows.Forms.NumericUpDown;$port.Minimum=1;$port.Maximum=65535;$port.Value=1080;$port.Width=95
$options.Controls.Add($direct);$options.Controls.Add($portLabel);$options.Controls.Add($port)
$buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.Padding='10,4,10,4'
$view=New-Object Windows.Forms.TextBox;$view.Multiline=$true;$view.ReadOnly=$true;$view.ScrollBars='Both';$view.Dock='Fill';$view.Font=New-Object Drawing.Font('Consolas',10)
$layout.Controls.Add($intro,0,0);$layout.Controls.Add($options,0,1);$layout.Controls.Add($buttons,0,2);$layout.Controls.Add($view,0,3);$form.Controls.Add($layout)
$script:pendingRepair=$null;$script:pendingStop=$null
$direct.Add_CheckedChanged({$script:pendingRepair=$null})
$port.Add_ValueChanged({$script:pendingStop=$null})
foreach($spec in @(@('分层诊断','status'),@('修复预览','preview'),@('执行已预览修复','apply'),@('撤销预览','undo-preview'),@('撤销上次设置','undo'),@('关闭端口预览','stop-preview'),@('关闭已预览端口','stop'),@('管理员窗口','elevate'))){
    $button=New-Object Windows.Forms.Button;$button.Text=$spec[0];$button.Tag=$spec[1];$button.AutoSize=$true;$button.Height=34
    $button.Add_Click({param($sender,$args)
        $buttons.Enabled=$false
        try{
            $result=$null
            switch([string]$sender.Tag){
                'status'{$result=ConvertTo-PCPublicSnapshot (Get-PCSnapshot)}
                'preview'{$script:pendingRepair=Get-PCRepairPlan -Snapshot (Get-PCSnapshot) -Direct:$direct.Checked;$result=ConvertTo-PCPublicPlan $script:pendingRepair}
                'apply'{
                    if(-not $script:pendingRepair){throw '请先生成修复预览。'}
                    if(-not(Test-PCAdministrator) -and @($script:pendingRepair.steps|Where-Object kind -eq 'Route').Count){throw '预览包含路由修改。请用“管理员窗口”打开后重新预览。'}
                    $result=Invoke-PCRepairPlan -Plan $script:pendingRepair -Confirm:$false
                    $script:pendingRepair=$null
                    if($result.status -eq 'applied'){[void](Send-PCSettingsChanged)}
                }
                'undo-preview'{$result=Get-PCUndoSummary}
                'undo'{
                    $answer=[Windows.Forms.MessageBox]::Show('只恢复上次操作中仍未被其他程序改动的设置，不重启进程。继续？','撤销确认','YesNo','Question')
                    if($answer -eq 'Yes'){$result=Invoke-PCUndo -Confirm:$false;[void](Send-PCSettingsChanged)}else{$result=@{status='declined'}}
                }
                'stop-preview'{$script:pendingStop=Get-PCStopPlan -Port ([int]$port.Value);$result=ConvertTo-PCPublicStopPlan $script:pendingStop}
                'stop'{
                    if(-not $script:pendingStop){throw '请先生成目标端口的关闭预览。'}
                    $answer=[Windows.Forms.MessageBox]::Show('关闭预览中的精确进程会中断对应连接，撤销设置不会重启它们。继续？','关闭端口确认','YesNo','Warning')
                    if($answer -eq 'Yes'){$result=Invoke-PCStopPlan -Plan $script:pendingStop -Confirm:$false;$script:pendingStop=$null}else{$result=@{status='declined'}}
                }
                'elevate'{& (Join-Path $PSScriptRoot 'Launch-ProxyClean.ps1') -Action Control -Elevated;$result=@{status='administrator_window_requested';note='请在新窗口重新诊断或预览；旧窗口不产生网络变更。'}}
            }
            $view.Text=$result|ConvertTo-Json -Depth 12
        }catch{$view.Text='操作未完成。请重新诊断/预览，检查是否需要管理员权限或先处理上次未完成的撤销。未将失败报告为成功。'}
        finally{$buttons.Enabled=$true}
    });$buttons.Controls.Add($button)
}
try{
    if($SelfTest){[pscustomobject]@{schema='proxyclean.ui-test.v1';status='constructed';buttons=$buttons.Controls.Count;shown=$false}|ConvertTo-Json;return}
    $view.Text='点击“分层诊断”读取当前状态；默认不写诊断文件，不发送原始配置，不自动修复。'
    [void]$form.ShowDialog()
}finally{$form.Dispose()}
