#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([ValidateSet('Diagnose','SoftReset','AdapterReset')][string]$Mode='Diagnose',[string]$InterfaceAlias,
    [ValidateRange(0,120)][int]$WaitSeconds=5,[switch]$SkipConnectivityChecks,[Alias('AsJson')][switch]$Json,[string]$LogPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$confirmation=@{};if($PSBoundParameters.ContainsKey('Confirm')){$confirmation.Confirm=$PSBoundParameters['Confirm']}
$result=$null;$code=0
try{
    $adapter=Get-PCWifiAdapter -InterfaceAlias $InterfaceAlias
    $before=Get-PCWifiSnapshot -Adapter $adapter
    $operation=[pscustomobject]@{status='diagnosed'}
    if($Mode -ne 'Diagnose'){
        $operation=Invoke-PCWifiReset -Adapter $adapter -Mode $Mode -WaitSeconds $WaitSeconds -WhatIf:$WhatIfPreference @confirmation
        if($operation.status -eq 'needs_attention'){$code=2}
    }
    $probe=if($SkipConnectivityChecks -or $WhatIfPreference){[pscustomobject]@{status='not_tested'}}else{Test-PCConnectivity}
    $result=[pscustomobject]@{schema='proxyclean.wifi.v1';status=$operation.status;mode=$Mode;selected_adapter=$before;operation=$operation;connectivity=$probe;log_written=$false
        note='显式网卡选择不要求它已连接或已有 IPv4。诊断不改设置；重置会临时断开该连接。'}
}catch{
    $code=1;$result=[pscustomobject]@{schema='proxyclean.wifi.v1';status='failed';mode=$Mode;message='网卡选择、权限或重置回读未通过；不报告恢复成功。多网卡请指定 InterfaceAlias。';recovery='若网卡已禁用，请通过 Windows 网络设置重新启用；DHCP 网卡可重新连接并续租。';log_written=$false}
}
if($LogPath -and -not $WhatIfPreference){
    if($PSCmdlet.ShouldProcess('指定的脱敏日志文件','创建诊断摘要；不覆盖已有文件')){
        if(Test-Path -LiteralPath $LogPath){throw '日志文件已存在；未覆盖。'}
        [IO.File]::WriteAllText([IO.Path]::GetFullPath($LogPath),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
        $result.log_written=$true
    }
}
if($Json){$result|ConvertTo-Json -Depth 10}else{$result|ConvertTo-Json -Depth 8|Write-Host}
if($code){exit $code}
