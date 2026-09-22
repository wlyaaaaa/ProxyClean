#Requires -Version 5.1
<#
.SYNOPSIS
    预览或清理失效本地代理，修改前保存恢复记录，修改后回读核验。
.DESCRIPTION
    双击使用请打开 00-打开 ProxyClean.vbs。此入口供命令行使用。
    默认不刷新 DNS；FlushDns 显式启用。GUI 与命令行共用执行流程。
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param([switch]$Direct,[switch]$Quiet,[switch]$Preview,[switch]$Undo,
    [Alias('AsJson')][switch]$Json,[switch]$SkipConnectivityChecks,[switch]$FlushDns)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$progress=$null
if(-not $Json -and -not $Quiet){$progress={param($Stage,$Message) Write-Host $Message}}
try{
    if($Undo){
        if($Preview -or $WhatIfPreference){$result=[pscustomobject]@{status='preview';undo=Get-PCUndoSummary}}
        elseif($PSCmdlet.ShouldProcess('上次 ProxyClean 修改','只恢复仍属于上次操作的设置')){$result=Invoke-PCWorkflow -Action Undo -Progress $progress -Confirm:$false}
        else{$result=[pscustomobject]@{status='declined'}}
    }else{
        $plan=Get-PCRepairPlan -Snapshot (Get-PCSnapshot -Progress $progress) -Direct:$Direct
        if($Preview -or $WhatIfPreference){$result=[pscustomobject]@{status='preview';plan=ConvertTo-PCPublicPlan $plan}}
        elseif($PSCmdlet.ShouldProcess('检查结果中选定的代理设置','保存原值并执行修复')){
            $result=Invoke-PCWorkflow -Action Repair -Plan $plan -SkipConnectivityChecks:$SkipConnectivityChecks -Progress $progress -Confirm:$false
            if($FlushDns -and $result.status -in @('applied','no_changes')){
                $dns=Invoke-PCWorkflow -Action FlushDns -Progress $progress -Confirm:$false
                $result.dns_cache=if($dns.status -eq 'dns_flushed'){'flushed'}else{'failed'}
            }
        }else{$result=[pscustomobject]@{status='declined'}}
    }
    if($Json){$result|ConvertTo-Json -Depth 14}else{
        $label=switch($result.status){
            'preview'{'当前为预览，没有修改设置。'}
            'applied'{'代理设置已修复，并已回读核验。'}
            'no_changes'{'没有需要清理的设置，没有修改配置。'}
            'recovered'{'上次修改已恢复。'}
            'nothing_to_undo'{'没有可恢复的修改。'}
            'plan_changed'{'情况已经变化，未继续清理。请重新检查。'}
            'failed_rolled_back'{'修复未完成，本次改动已恢复。'}
            'recovery_required'{'部分设置仍需恢复，请使用 -Undo -Preview 查看。'}
            'declined'{'已取消，没有执行修改。'}
            default{'操作没有完成，请重新检查。'}
        }
        Write-Host $label
        if($result.status -eq 'preview' -and -not $Quiet){
            if($Undo){foreach($resource in @(Get-PCValue $result.undo 'resources' @())){Write-Host ('将尝试恢复：'+$resource)}}
            else{foreach($step in $plan.steps){Write-Host ('将处理：'+(Get-PCStepLabel $step))}}
        }
        if(Get-PCValue $result 'message'){Write-Host $result.message}
        $probe=Get-PCValue $result 'connectivity'
        if($probe){Write-Host $(switch($probe.status){'http_reachable'{'测试网页可以连接，但不代表所有应用均已直连。'}'http_not_confirmed'{'测试网页未能连接，与设置修复结果分别报告。'}default{'尚未确认网页连接。'}})}
    }
    if($result.status -in @('failed_rolled_back','recovery_required','failed','incomplete','plan_changed')){exit 1}
    if((Get-PCValue $result 'dns_cache') -eq 'failed'){exit 2}
}catch{
    $failure=[pscustomobject]@{schema='proxyclean.cleanup-result.v1';status='failed';message=ConvertTo-PCFriendlyError $_;error_type=$_.Exception.GetType().FullName}
    if($Json){$failure|ConvertTo-Json}else{Write-Host $failure.message}
    exit 1
}
