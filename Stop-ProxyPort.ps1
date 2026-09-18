#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port,[string]$Label,
    [ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any',
    [string[]]$ExtraProcessName=@(),[switch]$Preview,[Alias('AsJson')][switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
try{
    $plan=Get-PCStopPlan -Port $Port -ExtraProcessName $ExtraProcessName
        if($ExpectedClient -ne 'Any'){
        $pattern=switch($ExpectedClient){'TAG'{'(?i)^(?:tag|mihomo-tag|tag-mihomo)$'}'ClashVerge'{'(?i)^(?:clash-verge|verge-mihomo)$'}'FlyingBird'{'(?i)^FlyingBird(?:Core|HelperService)?$'}}
        if(@($plan.processes|Where-Object{$_.name -notmatch $pattern}).Count){throw 'The legacy shortcut port belongs to a different process; nothing was stopped.'}
    }
    $public=ConvertTo-PCPublicStopPlan $plan
    if($Preview -or $WhatIfPreference){$result=[pscustomobject]@{status='preview';plan=$public}}
    elseif($PSCmdlet.ShouldProcess(('本地端口 '+$Port),'关闭当前确认的进程；仅端口关闭成功后清理该端点引用')){$result=Invoke-PCStopPlan -Plan $plan -Confirm:$false}
    else{$result=[pscustomobject]@{status='declined';plan=$public}}
    if($Json){$result|ConvertTo-Json -Depth 10}else{$result|ConvertTo-Json -Depth 8|Write-Host}
    if($result.status -eq 'incomplete'){exit 1}
}catch{
    [pscustomobject]@{status='failed';port=$Port;message='无法完整核实或关闭所选端口；未默认关闭任何其他客户端。请重新预览。'}|ConvertTo-Json
    exit 1
}
