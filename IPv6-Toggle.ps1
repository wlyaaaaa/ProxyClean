#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
param([ValidateSet('Toggle','Enable','Disable')][string]$Mode='Toggle',[string]$InterfaceAlias,[Alias('AsJson')][switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$confirmation=@{};if($PSBoundParameters.ContainsKey('Confirm')){$confirmation.Confirm=$PSBoundParameters['Confirm']}
try{
    $result=Invoke-PCIPv6Change -Mode $Mode -InterfaceAlias $InterfaceAlias -WhatIf:$WhatIfPreference @confirmation
    if($Json){$result|ConvertTo-Json -Depth 7}else{$result|Format-List}
}catch{[pscustomobject]@{status='failed';message='IPv6 切换没有完成；请用 IPv6-Status.ps1 检查当前绑定，不能据此断言公网或代理已恢复。'}|ConvertTo-Json;exit 1}
