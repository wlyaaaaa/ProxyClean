#Requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('All','Network')][string]$Suite='All',[switch]$Json)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    $files=@(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File|Where-Object { $_.Extension -in @('.ps1','.psm1') -and $_.FullName -notmatch '[\\/]\.git[\\/]' })
    foreach($file in $files){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw ('Parse failure: '+$file.Name)}}
    Import-Module Pester -MinimumVersion 5.7.1 -Force
    $c=New-PesterConfiguration
    $c.Run.Path=if($Suite -eq 'Network'){Join-Path $PSScriptRoot 'tests\ProxyClean.Network.Tests.ps1'}else{Join-Path $PSScriptRoot 'tests'}
    $c.Run.PassThru=$true;$c.Output.Verbosity='None';$c.TestResult.Enabled=$false
    $r=Invoke-Pester -Configuration $c 6>$null 5>$null 4>$null 3>$null
    $passed=$r.Result -eq 'Passed' -and $r.TotalCount -gt 0 -and $r.FailedCount -eq 0 -and $r.NotRunCount -eq 0
    $result=[pscustomobject]@{schema='proxyclean.repository-tests.v1';status=if($passed){'pass'}else{'fail'};powershell=$PSVersionTable.PSVersion.ToString();suite=$Suite;parser_files=$files.Count;total=$r.TotalCount;passed=$r.PassedCount;failed=$r.FailedCount;skipped=$r.SkippedCount;not_run=$r.NotRunCount;failed_tests=@($r.Tests|Where-Object Result -eq 'Failed'|ForEach-Object {$_.ExpandedPath});discovery_errors=@($r.Containers|ForEach-Object {@($_.ErrorRecord|ForEach-Object ToString)})}
    $result|ConvertTo-Json -Depth 6
    if(-not $passed){exit 1}
} catch {
    [pscustomobject]@{schema='proxyclean.repository-tests.v1';status='fail';message=$_.Exception.Message}|ConvertTo-Json
    exit 1
}