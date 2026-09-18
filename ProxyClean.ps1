#Requires -Version 5.1
<#
.SYNOPSIS
    预览或清理当前用户的失效本地代理，并保留一轮可核对的撤销。
.DESCRIPTION
    默认只处理死本地端点。Direct 仅关闭手动 WinINET、用户代理环境变量和全局通用 Git 代理；
    PAC、WinHTTP、机器环境、应用配置和 URL 专属 Git 设置不被隐式改写。
    脚本完成不等于全系统已直连；配置回读与 HTTP 探测分别报告。
#>
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='Medium')]
param([switch]$Direct,[switch]$Quiet,[switch]$Preview,[switch]$Undo,[Alias('AsJson')][switch]$Json,[switch]$SkipConnectivityChecks)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
try{
    if($Undo){
        if($Preview -or $WhatIfPreference){$result=[pscustomobject]@{status='preview';undo=Get-PCUndoSummary}}
        elseif($PSCmdlet.ShouldProcess('上次 ProxyClean 操作','仅撤销仍与上次结果一致的设置')){$result=Invoke-PCUndo -Confirm:$false; if($result.status -eq 'recovered'){[void](Send-PCSettingsChanged)}}
        else{$result=[pscustomobject]@{status='declined'}}
    }else{
        $plan=Get-PCRepairPlan -Snapshot (Get-PCSnapshot) -Direct:$Direct
        if($Preview -or $WhatIfPreference){$result=[pscustomobject]@{status='preview';plan=ConvertTo-PCPublicPlan $plan}}
        else{
                        $invoke=@{Plan=$plan}
            if($PSBoundParameters.ContainsKey('Confirm')){$invoke.Confirm=$PSBoundParameters['Confirm']}
            $applied=Invoke-PCRepairPlan @invoke
            $notification=$null;$dns='not_changed';$probe=[pscustomobject]@{status='not_tested'}
            if($applied.status -eq 'applied'){$notification=Send-PCSettingsChanged}
            if($applied.status -in @('applied','no_changes')){
                if($PSCmdlet.ShouldProcess('本机 DNS 缓存','刷新缓存；不更改 DNS 服务器')){
                    try{[void](Invoke-PCNative -FilePath (Join-Path $env:WINDIR 'System32\ipconfig.exe') -ArgumentList @('/flushdns'));$dns='flushed'}catch{$dns='failed'}
                }
                if(-not $SkipConnectivityChecks){$probe=Test-PCConnectivity}
            }
            $result=[pscustomobject]@{schema='proxyclean.cleanup-result.v1';status=$applied.status;plan=ConvertTo-PCPublicPlan $plan;configuration=$applied;notification=$notification;dns_cache=$dns;connectivity=$probe;all_applications_direct='not_proven'}
        }
    }
    if($Json){$result|ConvertTo-Json -Depth 12}else{
        Write-Host ('ProxyClean 结果：'+$result.status)
        if(-not $Quiet){$result|ConvertTo-Json -Depth 10|Write-Host}
        Write-Host '配置回读、端口关闭、HTTP 连通和所有应用直连是不同结果。撤销不会重启已关闭的进程。'
    }
    if($result.status -in @('failed_rolled_back','recovery_required','failed','incomplete')){exit 1}
    if((Get-PCValue $result 'dns_cache') -eq 'failed'){exit 2}
}catch{
    $failure=[pscustomobject]@{schema='proxyclean.cleanup-result.v1';status='failed';message='操作未能完成。未把错误当成成功；请查看脱敏诊断和撤销预览。';recovery_hint='.\ProxyClean.ps1 -Undo -Preview'}
    if($Json){$failure|ConvertTo-Json}else{$failure|Format-List}
    exit 1
}
