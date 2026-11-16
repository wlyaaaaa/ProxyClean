#Requires -Version 5.1
BeforeAll { . (Join-Path $PSScriptRoot '..\ProxyClean.Live.ps1') }
Describe 'Public live projection preserves incomplete counts and source times' {
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
