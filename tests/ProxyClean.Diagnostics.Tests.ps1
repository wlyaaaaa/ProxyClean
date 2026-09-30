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
Describe 'Detailed network paths preserve site and address-family evidence' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:diagnosticSnapshot=[pscustomobject]@{stored_endpoints=@()}
            Mock Get-Command {[pscustomobject]@{Source='C:\Fixture\curl.exe'}}
            Mock Get-PCDnsDependency {[pscustomobject]@{status='local_resolver_configured';upstream_independent_of_proxy='not_proven';settings_changed=$false}}
            Mock Get-PCAddressFamilyObservation {[pscustomobject]@{status='address_available';fake_ip_detected=$false}}
            Mock Invoke-PCNative {[pscustomobject]@{exit_code=0;stdout='200'}}
            Mock Set-PCResourceValue {throw 'Diagnostics must not modify a resource'}
            Mock Clear-PCClientDnsCache {throw 'Diagnostics must not flush DNS'}
        }
    }
    It 'does not stop after domestic success or hide an overseas failure' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCNative {param($ArgumentList)if($ArgumentList[-1] -match 'baidu') {[pscustomobject]@{exit_code=0;stdout='200'}}else{[pscustomobject]@{exit_code=28;stdout='000'}}}
            $r=Test-PCConnectivity -Detailed -Snapshot $script:diagnosticSnapshot
            $r.status|Should -Be paths_diagnosed
            $r.probes.Count|Should -Be 6
            @($r.probes|Where-Object {$_.target -eq '国内网页' -and $_.status -eq 'http_reachable'}).Count|Should -Be 2
            @($r.probes|Where-Object {$_.target -eq '海外网页' -and $_.status -eq 'connection_not_confirmed'}).Count|Should -Be 2
            $r.direct_route_proven|Should -BeFalse
            Should -Invoke Invoke-PCNative -Times 6
            Should -Invoke Set-PCResourceValue -Times 0
            Should -Invoke Clear-PCClientDnsCache -Times 0
        }
    }
    It 'reports HTTP 403 as a response rather than a network outage' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCNative {[pscustomobject]@{exit_code=0;stdout='403'}}
            $r=Test-PCNetworkPaths -Snapshot $script:diagnosticSnapshot
            @($r.probes|Where-Object status -eq 'http_responded').Count|Should -Be 6
            (@(Format-PCNetworkPaths $r) -join ';')|Should -Match 'HTTP 已到达.*403'
        }
    }
    It 'does not call absent AAAA records an IPv6 link failure' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCAddressFamilyObservation {param($Family)[pscustomobject]@{status=if($Family -eq 'IPv6'){'no_address_for_family'}else{'address_available'};fake_ip_detected=$true}}
            $r=Test-PCNetworkPaths -Snapshot $script:diagnosticSnapshot
            @($r.probes|Where-Object status -eq 'no_address_for_family').Count|Should -Be 3
            @($r.probes|Where-Object {$_.family -eq 'IPv4' -and $_.dns.fake_ip_detected}).Count|Should -Be 3
            Should -Invoke Invoke-PCNative -Times 3 -ParameterFilter {$ArgumentList -contains '-4' -and $ArgumentList -contains '--noproxy' -and $TimeoutSeconds -eq 7}
        }
    }
    It 'checks a stored listening HTTP endpoint even with system proxy disabled' {
        InModuleScope ProxyClean.Common {
            $script:diagnosticSnapshot.stored_endpoints=@([pscustomobject]@{endpoint='http://127.0.0.1:34567';scheme='http';mapping=$null;parsed=$true;local=$true;state='listening';source='stored';credentials_present=$false;parameters_present=$false})
            $r=Test-PCNetworkPaths -Snapshot $script:diagnosticSnapshot
            $forced=@($r.probes|Where-Object path -eq 'forced-local-34567')
            $forced.Count|Should -Be 3
            @($forced|Where-Object {$_.source -eq 'stored' -and $_.http_proxy_confirmed -and $_.family -eq 'proxy-managed'}).Count|Should -Be 3
            Should -Invoke Invoke-PCNative -Times 3 -ParameterFilter {$ArgumentList -contains '--proxy' -and $ArgumentList -contains 'http://127.0.0.1:34567' -and $ArgumentList -notcontains '-6'}
            Mock Invoke-PCNative {[pscustomobject]@{stdout='192.0.2.1'}}
            $exit=@(Get-PCExitComparison $script:diagnosticSnapshot)
            $exit.Count|Should -Be 2
            $exit[1].source|Should -Be stored
        }
    }
    It 'does not guess HTTP support from an unpublished candidate listener' {
        InModuleScope ProxyClean.Common {
            $script:diagnosticSnapshot|Add-Member -NotePropertyName listener_candidates -NotePropertyValue @([pscustomobject]@{port=1053;process='FlyingBirdCore';http_proxy_confirmed=$false})
            @(Get-PCObservedHttpEndpoints $script:diagnosticSnapshot)|Should -HaveCount 0
            [void](Test-PCNetworkPaths -Snapshot $script:diagnosticSnapshot)
            Should -Invoke Invoke-PCNative -Times 0 -ParameterFilter {$ArgumentList -contains '--proxy'}
        }
    }
}
Describe 'DNS family evidence uses the real resolver classifier' {
    It 'keeps a DNS response without AAAA separate from a resolver exception' {
        InModuleScope ProxyClean.Common {
            Mock Resolve-DnsName {[pscustomobject]@{Type='CNAME'}}
            (Get-PCAddressFamilyObservation -HostName 'fixture.example.test' -Family IPv6).status|Should -Be no_address_for_family
            Mock Resolve-DnsName {throw 'fixture resolver unavailable'}
            (Get-PCAddressFamilyObservation -HostName 'fixture.example.test' -Family IPv6).status|Should -Be resolution_not_confirmed
        }
    }
}
Describe 'Passive route diagnostics do not enlarge automatic repair targets' {
    It 'preserves split and on-link observations while repair uses only original default routes' {
        $s=[pscustomobject]@{systemProxy=[pscustomobject]@{enabled=$false;server='127.0.0.1:34567';pac=''};listeners=@([pscustomobject]@{OwningProcess=501;LocalAddress='127.0.0.1';LocalPort=34567});
            availability=[pscustomobject]@{listeners='observed';routes='observed';adapters='observed';wininet='observed';environment='observed';git='observed'};adapters=@([pscustomobject]@{InterfaceIndex=2;Name='Fixture Tunnel';InterfaceDescription='Wintun';Status='Up';HardwareInterface=$false});
            routes=@();diagnosticRoutes=@([pscustomobject]@{InterfaceIndex=2;InterfaceAlias='Fixture Tunnel';DestinationPrefix='0.0.0.0/1';RouteMetric=3;NextHop='0.0.0.0'});
            ipInterfaces=@([pscustomobject]@{InterfaceIndex=2;AddressFamily='IPv4';InterfaceMetric=5});environment=@();git=@();winhttp=$null;docker=$null;sid='fixture';isSystem=$false;sessionId=1;observedUtc='fixture'}
        Mock Get-Process -ModuleName ProxyClean.Common {[pscustomobject]@{ProcessName='FlyingBirdCore'}}
        $r=ConvertTo-PCPublicSnapshot $s
        $r.stored_endpoints[0].source|Should -Be stored
        $r.stored_endpoints[0].state|Should -Be listening
        $r.routing_observations[0].combined_metric|Should -Be 8
        $r.routing_observations[0].on_link|Should -BeTrue
        $r.routing_observations[0].tunnel_adapter_observed|Should -BeTrue
        $r.routing_observations[0].actual_destination_route|Should -Be not_probed
        $plan=Get-PCRepairPlan -Snapshot $s -Direct
        @($plan.steps).Count|Should -Be 0
    }
}
