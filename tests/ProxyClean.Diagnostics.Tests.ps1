#Requires -Version 5.1
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force }
Describe 'Docker current runtime evidence stays separate from configured intent' {
    BeforeEach {
        $script:oldAppData=$env:APPDATA;$script:oldLocal=$env:LOCALAPPDATA
        $env:APPDATA=Join-Path $TestDrive 'roaming';$env:LOCALAPPDATA=Join-Path $TestDrive 'local'
        [IO.Directory]::CreateDirectory((Join-Path $env:APPDATA 'Docker'))|Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'Docker\log\host'))|Out-Null
        [IO.File]::WriteAllText((Join-Path $env:APPDATA 'Docker\settings-store.json'),'{"ProxyHTTPMode":"system","ContainersProxyHTTPMode":"system"}')
        Mock Get-Process -ModuleName ProxyClean.Common { [pscustomobject]@{ProcessName='com.docker.backend';StartTime=(Get-Date).AddHours(-1)} }
    }
    AfterEach { $env:APPDATA=$script:oldAppData;$env:LOCALAPPDATA=$script:oldLocal }
    It 'reports a current manual runtime after configuration has switched to System' {
        $line='['+[DateTimeOffset]::UtcNow.ToString('O')+'] host will use proxy: app settings http://localhost:34567'
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'),$line)
        $r=Get-PCDockerSnapshot
        $r.pending_apply|Should -BeTrue;$r.runtime_evidence_current|Should -BeTrue;$r.local_manual_pin_present|Should -BeTrue
        $r.runtime_local_endpoint|Should -Be 'http://localhost:34567'
    }
    It 'does not refresh a stale event because unrelated log writes are recent' {
        $line='['+[DateTimeOffset]::UtcNow.AddHours(-2).ToString('O')+'] host will use proxy: app settings localhost:34567'
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'),$line)
        $r=Get-PCDockerSnapshot;$r.pending_apply|Should -BeFalse;$r.runtime_evidence_current|Should -BeFalse
    }
    It 'does not classify remote URI credentials as a local runtime pin' {
        $line='['+[DateTimeOffset]::UtcNow.ToString('O')+'] host will use proxy: app settings http://127.0.0.1:34567@proxy.example.test:8443'
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'),$line)
        $r=Get-PCDockerSnapshot;$r.pending_apply|Should -BeFalse;$r.runtime_local_endpoint|Should -BeNullOrEmpty
    }
    It 'does not fabricate a current mode from an unparseable timestamp' {
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'),'host will use proxy: app settings localhost:34567')
        (Get-PCDockerSnapshot).runtime_mode|Should -Be 'unknown'
    }
}
Describe 'Unpublished proxy-owned listeners are diagnostic candidates, never implicit HTTP endpoints' {
    It 'preserves dynamic client discovery without guessing a fixed port or HTTP capability' {
        Mock Get-Process -ModuleName ProxyClean.Common {[pscustomobject]@{ProcessName='verge-mihomo'}}
        $listeners=@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=34567;OwningProcess=501},[pscustomobject]@{LocalAddress='::1';LocalPort=34568;OwningProcess=501})
        $rows=@(Get-PCListenerCandidates -Listeners $listeners)
        $rows|Should -HaveCount 2
        @($rows|Where-Object published_by_system_proxy)|Should -HaveCount 0
        @($rows|Where-Object http_proxy_confirmed)|Should -HaveCount 0
        Should -Invoke Get-Process -ModuleName ProxyClean.Common -Times 1
    }
    It 'does not include a LAN-only listener just because its port is published' {
        $listeners=@([pscustomobject]@{LocalAddress='192.0.2.1';LocalPort=34567;OwningProcess=501})
        @(Get-PCListenerCandidates $listeners @(Get-ProxyEndpoints 'http://localhost:34567'))|Should -HaveCount 0
    }
}
Describe 'Disconnected adapter diagnostics retain absence and unknown separately' {
    It 'returns zero observed addresses when the selected adapter has none' {
        Mock Get-NetIPInterface -ModuleName ProxyClean.Common { @() }
        Mock Get-NetIPAddress -ModuleName ProxyClean.Common { @() }
        $r=Get-PCWifiSnapshot ([pscustomobject]@{Name='Fixture';InterfaceIndex=501;Status='Disconnected'})
        $r.ipv4_address_count|Should -Be 0;$r.address_observation|Should -Be 'observed';$r.dhcp|Should -Be 'unknown'
    }
    It 'reports query failure as unknown rather than no address' {
        Mock Get-NetIPInterface -ModuleName ProxyClean.Common {throw 'fixture'}
        Mock Get-NetIPAddress -ModuleName ProxyClean.Common {throw 'fixture'}
        $r=Get-PCWifiSnapshot ([pscustomobject]@{Name='Fixture';InterfaceIndex=501;Status='Disconnected'})
        $r.ipv4_address_count|Should -BeNullOrEmpty;$r.address_observation|Should -Be 'unknown'
    }
}