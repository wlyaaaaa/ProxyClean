#Requires -Version 5.1
[CmdletBinding()]
param([Alias('AsJson')][switch]$Json)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$result=Get-PCIPv6Snapshot
if($Json){$result|ConvertTo-Json -Depth 7}else{$result|ConvertTo-Json -Depth 7|Write-Host}
if($result.default_route -eq 'unknown' -or @($result.adapters|Where-Object binding_state -eq 'unknown').Count){exit 2}
