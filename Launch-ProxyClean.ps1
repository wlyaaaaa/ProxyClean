#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('Clean','Direct','Status','WifiSoft','WifiReset','IPv6Toggle','IPv6Status','StopPort','Control','Undo','IPv6Enable','IPv6Disable','FlushDns','Disconnect')][string]$Action='Control',
    [ValidateRange(0,65535)][int]$Port=0,[ValidateSet('Any','TAG','ClashVerge','FlyingBird')][string]$ExpectedClient='Any',
    [ValidateSet('Clean','Direct','Status','WifiSoft','WifiReset','IPv6Toggle','IPv6Status','StopPort','Control','Undo','IPv6Enable','IPv6Disable','FlushDns','Disconnect')][string]$InitialAction='Control',
    [string]$InterfaceAlias,[string]$ClientKey,[string]$ExpectedSid,[string]$ExpectedClientInstance,[switch]$ResumeDisconnect,[switch]$Elevated,[switch]$PreviewLaunch)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ProxyClean.Common.psm1') -Force
$pwsh=Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$exe=if(Test-Path -LiteralPath $pwsh){$pwsh}else{Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'}
# Ordinary launch stays read-only. A same-client UAC handoff continues only
# the disconnect already requested by the user, with SID and instance checks.
$initial=if($Action -eq 'Control'){$InitialAction}else{$Action}
if($ResumeDisconnect -and ($initial -ne 'Disconnect' -or -not $ClientKey -or -not $ExpectedSid -or $ExpectedClientInstance -cnotmatch '^[a-f0-9]{64}$' -or -not $Elevated)){throw 'Invalid client disconnect continuation.'}
$arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',(Join-Path $PSScriptRoot 'ControlCenter.ps1'),'-InitialAction',$initial)
if($Port){$arguments+=@('-Port',[string]$Port)}
if($ExpectedClient -ne 'Any'){$arguments+=@('-ExpectedClient',$ExpectedClient)}
if($InterfaceAlias){$arguments+=@('-InterfaceAlias',$InterfaceAlias)}
if($ClientKey){$arguments+=@('-ClientKey',$ClientKey)}
if($ExpectedSid){$arguments+=@('-ExpectedSid',$ExpectedSid)}
if($ExpectedClientInstance){$arguments+=@('-ExpectedClientInstance',$ExpectedClientInstance)}
if($ResumeDisconnect){$arguments+=@('-ResumeDisconnect')}
$argumentLine=($arguments|ForEach-Object{ConvertTo-PCArgument ([string]$_)}) -join ' '
if($PreviewLaunch){[pscustomobject]@{executable=$exe;arguments=$arguments;argument_line=$argumentLine;elevate=[bool]$Elevated;side_effects=$false;preview_first=(-not [bool]$ResumeDisconnect)}|ConvertTo-Json -Depth 5;return}
$start=@{FilePath=$exe;ArgumentList=$argumentLine;WorkingDirectory=$PSScriptRoot;WindowStyle='Hidden';ErrorAction='Stop'}
if($Elevated -and -not(Test-PCAdministrator)){$start.Verb='RunAs'}
Start-Process @start|Out-Null
