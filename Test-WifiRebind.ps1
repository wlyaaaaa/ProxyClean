#Requires -Version 5.1
[CmdletBinding()]
param([string]$ScriptPath=(Join-Path $PSScriptRoot 'WifiRebind.ps1'),[switch]$Json)
$ErrorActionPreference='Stop'
if([IO.Path]::GetFullPath($ScriptPath) -ne (Join-Path $PSScriptRoot 'WifiRebind.ps1')){throw 'Run the tests in the repository that owns the selected script.'}
& (Join-Path $PSScriptRoot 'ProxyClean.test.ps1') -Suite Network -Json:$Json