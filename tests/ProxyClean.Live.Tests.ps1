#Requires -Version 5.1
BeforeAll { . (Join-Path $PSScriptRoot '..\ProxyClean.Live.ps1');Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force }
Describe 'Public live projection preserves incomplete counts and source times' {
    It 'records repair outcomes through the workflow with only categories and counts' {
        InModuleScope ProxyClean.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:fixtureStage=Join-Path $Root 'Local\ProxyClean\stage.json'
            Mock Get-PCStagePath {$script:fixtureStage};Mock Test-PCAdministrator {$true}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)};Mock Send-PCSettingsChanged {}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='applied';changed=1}}
            $plan=[pscustomobject]@{steps=@([pscustomobject]@{kind='UserEnv';name='PRIVATE_VALUE';before='PRIVATE_VALUE'})}
            1..11|ForEach-Object {[void](Invoke-PCWorkflow Repair -Plan $plan -SkipConnectivityChecks -Confirm:$false)}
            Mock Invoke-PCRepairPlan {throw 'PRIVATE_VALUE'}
            [void](Invoke-PCWorkflow Repair -Plan $plan -SkipConnectivityChecks -Confirm:$false)
            [void](Invoke-PCWorkflow Repair -Plan $plan -WhatIf)
            $raw=[IO.File]::ReadAllText((Join-Path (Split-Path $script:fixtureStage) 'repair-history.json'))
            $rows=@(($raw|ConvertFrom-Json).items);$rows|Should -HaveCount 10
            $rows[-2].changed|Should -Be 1;$rows[-2].success|Should -BeTrue
            $rows[-1].changed|Should -BeNullOrEmpty;$rows[-1].success|Should -BeFalse
            $rows[-1].categories|Should -Contain '用户环境变量';$raw|Should -Not -Match 'PRIVATE_VALUE'
        }
        $state=[pscustomobject]@{observedUtc='2026-11-17T00:00:00Z';client_inventory=@();collection_errors=@();availability=@{adapters='observed';wininet='observed'};system_proxy=@{enabled=$false};expect_mode='TunOnly';deviations=@()}
        $output=Join-Path $TestDrive 'projection.json';Write-PCLiveSnapshot $state (Join-Path $TestDrive 'Roaming') $output
        $rows=@(([IO.File]::ReadAllText($output)|ConvertFrom-Json).metrics.repairs)
        $rows|Should -HaveCount 10;$rows[0].success|Should -BeFalse
    }
    It 'keeps unknown separate from zero and never copies raw diagnostic values' {
        $client=[pscustomobject]@{family='clash-verge';label='Clash';installed=$true;running=$true;tun_active=$true;saved_preferences=@{state='observed';tun_enabled=$true;system_proxy_enabled=$false}}
        $state=[pscustomobject]@{observedUtc='2026-11-15T19:00:00-07:00';client_inventory=@($client);collection_errors=@();availability=@{adapters='observed';wininet='observed'};system_proxy=@{enabled=$false;server='NEVER_PUBLISH'};expect_mode='TunOnly';deviations=@()}
        $output=Join-Path $TestDrive 'live.json';$appdata=Join-Path $TestDrive 'Roaming'
        Write-PCLiveSnapshot $state $appdata $output
        $first=[IO.File]::ReadAllText($output)|ConvertFrom-Json
        $first.metrics.deviations|Should -Be 0;$first.metrics.saved|Should -Be '1/1'
        $first.deviation_records|Should -HaveCount 0
        $first.notes.deviations|Should -Match '没有差异'
        $first.metrics.undo|Should -BeNullOrEmpty;$first.notes.undo|Should -Match '没有恢复槽'
        $state.observedUtc='2026-11-16T02:01:00Z';$state.collection_errors=@('client_processes_unavailable')
        $client.saved_preferences.state='missing_field'
        Write-PCLiveSnapshot $state $appdata $output
        $second=[IO.File]::ReadAllText($output)|ConvertFrom-Json
        $second.metrics.deviations|Should -BeNullOrEmpty;$second.metrics.running|Should -BeNullOrEmpty
        $second.metrics.saved|Should -BeNullOrEmpty;$second.metrics.clash_verge_tun_enabled|Should -BeNullOrEmpty
        $second.size.at|Should -Be $first.size.at
        [IO.File]::ReadAllText($output)|Should -Match '"at":"2026-11-16T02:00:00.0000000\+00:00"'
        [IO.File]::ReadAllText($output)|Should -Not -Match 'NEVER_PUBLISH'
    }
}
