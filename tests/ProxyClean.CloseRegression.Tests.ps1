#Requires -Version 5.1
# All process, service and network effects in this file are mocked.
BeforeAll {Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force}
Describe 'Bounded launch-broker restoration' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:service=[pscustomobject]@{name='fixture-broker';pid=991001;path='C:\Fixture\broker.exe'}
            $script:state='Stopped';$script:servicePath=$script:service.path
            $script:controller=[pscustomobject]@{Status='Stopped';waits=@();failWait=$false}
            $script:controller|Add-Member ScriptMethod WaitForStatus {param($target,$timeout) if($this.failWait){throw 'fixture wait timeout'};$this.waits+=@([string]$target);$this.Status=[string]$target}
            Mock Get-CimInstance {[pscustomobject]@{Name='fixture-broker';State=$script:state;PathName=$script:servicePath}}
            Mock Get-Service {$script:controller}
            Mock Invoke-PCNative {[pscustomobject]@{exit_code=0}}
            Mock Start-Service {throw 'Use a bounded native start'}
            Mock Set-Service {throw 'Startup type changes are prohibited'}
        }
    }
    It 'starts a verified stopped broker with a time limit and verifies Running' {
        InModuleScope ProxyClean.Common {
            Restore-PCClientService $script:service
            Should -Invoke Invoke-PCNative -Times 1 -ParameterFilter {$ArgumentList[0] -eq 'start' -and $ArgumentList[1] -eq 'fixture-broker' -and $TimeoutSeconds -eq 10}
            $script:controller.waits|Should -Contain Running
        }
    }
    It 'does not restart an already running broker' {
        InModuleScope ProxyClean.Common {$script:state='Running';Restore-PCClientService $script:service;Should -Invoke Invoke-PCNative -Times 0}
    }
    It 'waits for an in-flight stop before starting' {
        InModuleScope ProxyClean.Common {$script:controller.Status='StopPending';Restore-PCClientService $script:service;$script:controller.waits[0]|Should -Be Stopped;$script:controller.waits[1]|Should -Be Running}
    }
    It 'does not duplicate an in-flight start' {
        InModuleScope ProxyClean.Common {$script:controller.Status='StartPending';Restore-PCClientService $script:service;Should -Invoke Invoke-PCNative -Times 0;$script:controller.waits|Should -Contain Running}
    }
    It 'rejects a service path change before any start' {
        InModuleScope ProxyClean.Common {$script:servicePath='C:\Other\broker.exe';{Restore-PCClientService $script:service}|Should -Throw '*identity changed*';Should -Invoke Invoke-PCNative -Times 0}
    }
    It 'surfaces native start failure' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {throw 'fixture start failure'};{Restore-PCClientService $script:service}|Should -Throw '*start failure*'}
    }
    It 'surfaces a Running verification timeout' {
        InModuleScope ProxyClean.Common {$script:controller.failWait=$true;{Restore-PCClientService $script:service}|Should -Throw '*wait timeout*'}
    }
}
Describe 'A naturally exiting process is not a failed forced close' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:processIdentity=[pscustomobject]@{pid=991002;name='fixture'}
            Mock Test-PCClientProcess {$true}
            Mock Stop-Process {}
            Mock Get-Process {$null}
        }
    }
    It 'targets only the identity-verified PID' {
        InModuleScope ProxyClean.Common {Stop-PCClientProcess $script:processIdentity;Should -Invoke Stop-Process -Times 1 -ParameterFilter {$Id -eq 991002 -and $Force}}
    }
    It 'does nothing when the original process is already absent' {
        InModuleScope ProxyClean.Common {Mock Test-PCClientProcess {$false};Stop-PCClientProcess $script:processIdentity;Should -Invoke Stop-Process -Times 0}
    }
    It 'accepts disappearance between check and termination' {
        InModuleScope ProxyClean.Common {Mock Stop-Process {throw 'fixture already exited'};{Stop-PCClientProcess $script:processIdentity}|Should -Not -Throw}
    }
    It 'does not suppress a failure while the PID is still present' {
        InModuleScope ProxyClean.Common {Mock Stop-Process {throw 'fixture access failure'};Mock Get-Process {[pscustomobject]@{Id=991002}};{Stop-PCClientProcess $script:processIdentity}|Should -Throw '*access failure*'}
    }
    It 'refuses PID reuse without sending any termination request' {
        InModuleScope ProxyClean.Common {Mock Test-PCClientProcess {throw 'Process identity changed.'};{Stop-PCClientProcess $script:processIdentity}|Should -Throw '*identity changed*';Should -Invoke Stop-Process -Times 0}
    }
}
Describe 'Connectivity separates resolver failures from other network failures' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:probeCount=0
            Mock Get-Command {[pscustomobject]@{Source='C:\Fixture\curl.exe'}}
            Mock Invoke-PCNative {$script:probeCount++;[pscustomobject]@{exit_code=6;stdout='000'}}
            Mock Get-PCDnsDependency {[pscustomobject]@{status='local_resolver_configured';settings_changed=$false}}
        }
    }
    It 'identifies repeated name-resolution failures without changing DNS' {
        InModuleScope ProxyClean.Common {$r=Test-PCConnectivity;$r.status|Should -Be dns_resolution_failed;$r.direct_route_proven|Should -BeFalse;$r.dns.settings_changed|Should -BeFalse;Should -Invoke Invoke-PCNative -Times 2}
    }
    It 'does not claim DNS failure for mixed DNS and connection errors' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {$script:probeCount++;[pscustomobject]@{exit_code=if($script:probeCount -eq 1){6}else{28};stdout='000'}};(Test-PCConnectivity).status|Should -Be http_not_confirmed}
    }
    It 'accepts the second site without requiring the first site to work' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {$script:probeCount++;[pscustomobject]@{exit_code=if($script:probeCount -eq 1){6}else{0};stdout=if($script:probeCount -eq 1){'000'}else{'200'}}};$r=Test-PCConnectivity;$r.status|Should -Be http_reachable;$r.probes.Count|Should -Be 2;Should -Invoke Get-PCDnsDependency -Times 0}
    }
    It 'does not call an HTTP error successful connectivity' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {[pscustomobject]@{exit_code=0;stdout='403'}};(Test-PCConnectivity).status|Should -Be http_not_confirmed}
    }
    It 'uses bounded requests bypassing explicit proxies without claiming a TUN bypass' {
        InModuleScope ProxyClean.Common {[void](Test-PCConnectivity);Should -Invoke Invoke-PCNative -Times 2 -ParameterFilter {$ArgumentList -contains '--noproxy' -and $ArgumentList -contains '-4' -and $TimeoutSeconds -eq 8}}
    }
    It 'does not probe when the test tool is missing' {
        InModuleScope ProxyClean.Common {Mock Get-Command {$null};(Test-PCConnectivity).status|Should -Be not_available;Should -Invoke Invoke-PCNative -Times 0}
    }
    It 'does not misdiagnose an exception as DNS failure' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {throw 'fixture native failure'};(Test-PCConnectivity).status|Should -Be http_not_confirmed}
    }
}
Describe 'DNS cache and configuration observations remain scoped' {
    It 'flushes only the cache, not servers, adapters or proxy settings' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {[pscustomobject]@{exit_code=0}};Clear-PCClientDnsCache|Should -Be flushed;Should -Invoke Invoke-PCNative -Times 1 -ParameterFilter {$ArgumentList.Count -eq 1 -and $ArgumentList[0] -eq '/flushdns' -and $TimeoutSeconds -eq 8}}
    }
    It 'does not report a failed cache flush as completed' {
        InModuleScope ProxyClean.Common {Mock Invoke-PCNative {throw 'fixture flush failure'};Clear-PCClientDnsCache|Should -Be failed}
    }
    It 'recognizes loopback DNS without inferring independent upstreams' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetAdapter {[pscustomobject]@{HardwareInterface=$true;Status='Up';InterfaceIndex=19}}
            Mock Get-DnsClientServerAddress {[pscustomobject]@{InterfaceIndex=19;ServerAddresses=@('127.0.0.1','::1')}}
            $r=Get-PCDnsDependency;$r.status|Should -Be local_resolver_configured;$r.upstream_independent_of_proxy|Should -Be not_proven;$r.settings_changed|Should -BeFalse
        }
    }
    It 'does not mistake virtual-adapter DNS for physical-network DNS' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetAdapter {@([pscustomobject]@{HardwareInterface=$true;Status='Up';InterfaceIndex=19},[pscustomobject]@{HardwareInterface=$false;Status='Up';InterfaceIndex=99})}
            Mock Get-DnsClientServerAddress {@([pscustomobject]@{InterfaceIndex=19;ServerAddresses=@('192.0.2.53')},[pscustomobject]@{InterfaceIndex=99;ServerAddresses=@('127.0.0.1')})}
            (Get-PCDnsDependency).status|Should -Be external_resolver_configured
        }
    }
    It 'keeps unavailable observations unknown' {
        InModuleScope ProxyClean.Common {Mock Get-NetAdapter {throw 'fixture unavailable'};(Get-PCDnsDependency).status|Should -Be unknown}
    }
    It 'gives specific recovery advice rather than repeating proxy cleanup' {
        Get-PCConnectivityFailureMessage ([pscustomobject]@{status='dns_resolution_failed'})|Should -Match 'DNS.*上游.*重复清理'
        ConvertTo-PCFriendlyError 'PC_CLIENT_SERVICE_RESTORE_FAILED'|Should -Match '启动辅助服务未能恢复'
        ConvertTo-PCFriendlyError 'PC_CLIENT_RESTARTED'|Should -Match '又启动了核心'
    }
}

Describe 'Graceful exit races preserve one-click completion' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:windowIdentity=[pscustomobject]@{pid=991003;name='fixture'}
            Mock Test-PCClientProcess {$true}
            $script:windowCalls=0
            Mock Get-Process {$script:windowCalls++;if($script:windowCalls -eq 1){throw 'fixture exited'};return $null}
        }
    }
    It 'accepts a window process exiting before the close request' {
        InModuleScope ProxyClean.Common {{Request-PCClientWindowClose $script:windowIdentity}|Should -Not -Throw}
    }
    It 'retains an error while the window process remains present' {
        InModuleScope ProxyClean.Common {
            Mock Get-Process {$script:windowCalls++;if($script:windowCalls -eq 1){throw 'fixture window failure'};[pscustomobject]@{Id=991003}}
            {Request-PCClientWindowClose $script:windowIdentity}|Should -Throw '*window failure*'
        }
    }
    It 'does not access a window for a reused process identity' {
        InModuleScope ProxyClean.Common {
            Mock Test-PCClientProcess {throw 'Process identity changed.'}
            {Request-PCClientWindowClose $script:windowIdentity}|Should -Throw '*identity changed*'
            Should -Invoke Get-Process -Times 0
        }
    }
}
Describe 'Package entry includes every shared module dependency' {
    It 'checks the new policy module without creating a second daily launcher' {
        $root=Split-Path $PSScriptRoot -Parent
        $entry=[IO.File]::ReadAllText((Join-Path $root '00-打开 ProxyClean.vbs'))
        $module=[IO.File]::ReadAllText((Join-Path $root 'ProxyClean.Common.psm1'))
        foreach($file in @('ProxyClean.Operations.ps1','ProxyClean.Network.ps1','ProxyClean.ClientPolicy.ps1','ProxyClean.Clients.ps1','ProxyClean.Workflow.ps1')){
            $entry|Should -Match ([regex]::Escape($file))
            $module|Should -Match ([regex]::Escape($file))
            Test-Path (Join-Path $root $file)|Should -BeTrue
        }
    }
}
