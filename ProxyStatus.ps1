#Requires -Version 5.1
[CmdletBinding()]
param([switch]$ProbeExit,[switch]$SkipExitProbe,[Alias('AsJson')][switch]$Json,[switch]$Summary,[ValidateSet('TunOnly')][string]$ExpectMode,[ValidatePattern('^S-1-(?:\d+-)+\d+$')][string]$UserSid)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$reader=$null
$target=Get-PCStatusTarget $UserSid
try {
if($Summary -or $ExpectMode -or $UserSid){$reader=[powershell]::Create();[void]$reader.AddCommand('Get-CimInstance').AddParameter('Query',(Get-PCStatusProcessQuery)).AddParameter('ErrorAction','Stop');$pending=$reader.BeginInvoke()}
$snapshot=if($reader){Get-PCDefaultSnapshot -UserSid $UserSid}else{Get-PCSnapshot}
$result=if($reader){[pscustomobject]@{schema='proxyclean.dynamic-status.v1';observedUtc=$snapshot.observedUtc;credentials_filtered=$true;availability=$snapshot.availability;context=@{observer_sid=$snapshot.sid;inspected_user_sid=$target.sid;session_id=$snapshot.sessionId;system_account=$snapshot.isSystem};system_proxy=@{enabled=if($snapshot.systemProxy){$snapshot.systemProxy.enabled}else{$null};server=if($snapshot.systemProxy){Get-PCSafeProxyValue $snapshot.systemProxy.server}else{$null}};default_routes=@($snapshot.routes|Select-Object InterfaceAlias,InterfaceIndex,DestinationPrefix,NextHop,RouteMetric);exit_probes=@();conclusion=@{current_default='not_probed'}}}else{ConvertTo-PCPublicSnapshot -Snapshot $snapshot}
$arguments=@{Snapshot=$snapshot;ExpectMode=$ExpectMode;AppDataPath=$target.appdata;UserSid=$UserSid};if($reader){$processes=@($reader.EndInvoke($pending));if(-not $reader.HadErrors){$arguments.Processes=$processes}};$clients=Get-PCClientStatus @arguments
} finally {if($reader){$reader.Dispose()}}
foreach($property in $clients.PSObject.Properties){$result|Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value}
$owners=@(foreach($client in $clients.client_inventory){foreach($endpoint in @(Get-ProxyEndpoints ([string](Get-PCStatusValue $snapshot 'systemProxy.server')))){if(@($client.listeners|Where-Object{(Get-PCListenerState $endpoint @($_)) -eq 'listening'}).Count){$client.family}}})
$result.system_proxy.owner=@($owners|Select-Object -Unique)
if($ProbeExit -and -not $SkipExitProbe){$result.exit_probes=@(Get-PCExitComparison -Snapshot $snapshot);$result.conclusion.current_default='process_default_observed_when_probe_succeeds; equal exits do not identify the client'}
if($Json){$result|ConvertTo-Json -Depth 16}elseif($Summary){$result.summary}else{
    Write-Host 'ProxyClean 分层诊断（保留地址，过滤凭据，不写文件）'
    Write-Host '这些是当前执行用户的事实；SYSTEM 或非交互会话不能冒充桌面应用实测。'
    $result|ConvertTo-Json -Depth 10|Write-Host
}
if(@($snapshot.availability.PSObject.Properties|Where-Object Value -eq 'unknown').Count){exit 2}
