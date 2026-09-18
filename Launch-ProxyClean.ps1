#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Clean','Direct','Status','WifiSoft','WifiReset','IPv6Toggle','IPv6Status','StopPort','Control')][string]$Action='Control',
    [ValidateRange(1,65535)][int]$Port=1080,[ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any',
    [switch]$Elevated,[switch]$PreviewLaunch)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$pwsh=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$exe=if(Test-Path -LiteralPath $pwsh){$pwsh}else{Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}
$entry=switch($Action){'Clean'{'ProxyClean.ps1'}'Direct'{'ProxyClean.ps1'}'Status'{'ProxyStatus.ps1'}'WifiSoft'{'WifiRebind.ps1'}'WifiReset'{'WifiRebind.ps1'}'IPv6Toggle'{'IPv6-Toggle.ps1'}'IPv6Status'{'IPv6-Status.ps1'}'StopPort'{'Stop-ProxyPort.ps1'}'Control'{'ControlCenter.ps1'}}
$arguments=@('-NoLogo','-NoProfile')
if($Action -eq 'Control'){$arguments+=@('-STA','-WindowStyle','Hidden')}else{$arguments+=@('-NoExit')}
$arguments+=@('-File',(Join-Path $PSScriptRoot $entry))
switch($Action){
    'Status'{$arguments+=@('-ProbeExit')}
    'Direct'{$arguments+=@('-Direct')}
    'WifiSoft'{$arguments+=@('-Mode','SoftReset')}
    'WifiReset'{$arguments+=@('-Mode','AdapterReset')}
    'IPv6Toggle'{}
    'StopPort'{$arguments+=@('-Port',[string]$Port,'-ExpectedClient',$ExpectedClient)}
}
$needsElevation=$Elevated -or $Action -in @('Clean','Direct','WifiSoft','WifiReset','IPv6Toggle','StopPort')
$argumentLine=($arguments|ForEach-Object{ConvertTo-PCArgument ([string]$_)}) -join ' '
if($PreviewLaunch){[pscustomobject]@{executable=$exe;arguments=$arguments;argument_line=$argumentLine;elevate=$needsElevation;side_effects=$false}|ConvertTo-Json -Depth 5;return}
$start=@{FilePath=$exe;ArgumentList=$argumentLine}
if($needsElevation -and -not(Test-PCAdministrator)){$start.Verb='RunAs'}
Start-Process @start|Out-Null
