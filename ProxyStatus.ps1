#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ProbeExit,[switch]$SkipExitProbe,[Alias('AsJson')][switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$snapshot=Get-PCSnapshot
$result=ConvertTo-PCPublicSnapshot -Snapshot $snapshot
if($ProbeExit -and -not $SkipExitProbe){$result.exit_probes=@(Get-PCExitComparison -Snapshot $snapshot);$result.conclusion.current_default='process_default_observed_when_probe_succeeds; equal exits do not identify the client'}
if($Json){$result|ConvertTo-Json -Depth 12}else{
    Write-Host 'ProxyClean 分层诊断（默认脱敏，不写文件）'
    Write-Host '这些是当前执行用户的事实；SYSTEM 或非交互会话不能冒充桌面应用实测。'
    $result|ConvertTo-Json -Depth 10|Write-Host
}
if(@($snapshot.availability.PSObject.Properties|Where-Object Value -eq 'unknown').Count){exit 2}
