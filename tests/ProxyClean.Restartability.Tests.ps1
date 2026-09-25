#Requires -Version 5.1
# All process, service, registry and network effects below are mocked.
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force }
Describe 'Closing a client preserves its launch broker' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:serviceState='Running';$script:restored=$false;$script:alive=$false
            $script:broker=[pscustomobject]@{name='fixture-broker';pid=882312;path='C:\Fixture\clash-verge-service.exe'}
            $script:plan=[pscustomobject]@{schema='proxyclean.client-close.v1';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;key='clash-verge';label='Fixture';ports=@(34567);services=@($script:broker);members=@(
                [pscustomobject]@{pid=882311;name='clash-verge';path='C:\Fixture\clash-verge.exe';session=1;start_utc='fixture'},
                [pscustomobject]@{pid=882312;name='clash-verge-service';path='C:\Fixture\clash-verge-service.exe';session=0;start_utc='fixture'})}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='none'}}
            Mock Test-PCClientProcess {$script:alive}
            Mock Request-PCClientWindowClose {}
            Mock Get-CimInstance {@([pscustomobject]@{Name='fixture-broker';ProcessId=882312;PathName='C:\Fixture\clash-verge-service.exe';State=$script:serviceState})}
            Mock Stop-PCClientService {$script:serviceState='Stopped'}
            Mock Restore-PCClientService {$script:serviceState='Running';$script:restored=$true}
            Mock Start-Service {throw 'Unexpected real service action'}
            Mock Stop-Process {$script:alive=$false}
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCClientInventory {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCSnapshot {[pscustomobject]@{fixture=$true}}
            Mock Get-PCRepairPlan {[pscustomobject]@{steps=@();ports=@(34567)}}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='no_changes';changed=0}}
            Mock Send-PCSettingsChanged {}
            Mock Clear-PCClientDnsCache {'flushed'}
            Mock Invoke-PCNative {throw 'Unexpected native network effect in isolated test'}
            Mock Test-PCConnectivity {[pscustomobject]@{status='http_reachable'}}
            Mock ConvertTo-PCPublicSnapshot {[pscustomobject]@{availability=[pscustomobject]@{listeners='observed'};system_proxy=[pscustomobject]@{enabled=$false;pac_configured=$false};tun_routes=@();conclusion=[pscustomobject]@{consumer_local_proxy_pin_present=$false};environment=@();git_proxy=@();winhttp=[pscustomobject]@{mode='direct'}}}
        }
    }
    It 'restores the broker after successful normal exit' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_closed
            Should -Invoke Stop-PCClientService -Times 1
            Should -Invoke Restore-PCClientService -Times 1
            $script:serviceState|Should -Be Running
        }
    }
    It 'automatically handles residual processes in the same requested operation' {
        InModuleScope ProxyClean.Common {
            $script:alive=$true
            $r=Invoke-PCClientClose $script:plan -ForceFallback -WaitSeconds 0 -Confirm:$false
            $r.status|Should -Be client_closed
            Should -Invoke Stop-Process -Times 1 -ParameterFilter {$Id -eq 882311 -and $Force}
            Should -Invoke Restore-PCClientService -Times 1
        }
    }
    It 'does not force a client that already exited gracefully' {
        InModuleScope ProxyClean.Common {
            [void](Invoke-PCClientClose $script:plan -ForceFallback -WaitSeconds 0 -Confirm:$false)
            Should -Invoke Stop-Process -Times 0
        }
    }
    It 'restores the broker when original processes refuse to exit' {
        InModuleScope ProxyClean.Common {
            $script:alive=$true
            (Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_still_running
            Should -Invoke Restore-PCClientService -Times 1
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'restores the broker after a settings failure' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='recovery_required'}}
            (Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_settings_incomplete
            Should -Invoke Restore-PCClientService -Times 1
        }
    }
    It 'restores the broker when an exception interrupts closing' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCRepairPlan {throw 'fixture interrupted repair'}
            {Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false}|Should -Throw '*interrupted repair*'
            Should -Invoke Restore-PCClientService -Times 1
        }
    }
    It 'recovers a stop request that took effect before it reported failure' {
        InModuleScope ProxyClean.Common {
            Mock Stop-PCClientService {$script:serviceState='Stopped';throw 'fixture stop response lost'}
            {Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false}|Should -Throw '*response lost*'
            Should -Invoke Restore-PCClientService -Times 1
        }
    }
    It 'does not start a broker which was stopped before this operation' {
        InModuleScope ProxyClean.Common {
            $script:serviceState='Stopped'
            [void](Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false)
            Should -Invoke Restore-PCClientService -Times 0
        }
    }
    It 'does not restart a standalone proxy-core service' {
        InModuleScope ProxyClean.Common {
            $script:plan.members[1].name='mihomo'
            [void](Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false)
            Should -Invoke Restore-PCClientService -Times 0
        }
    }
    It 'does not emit a successful close before broker recovery succeeds' {
        InModuleScope ProxyClean.Common {
            Mock Restore-PCClientService {throw 'fixture cannot start service'}
            $received=New-Object 'Collections.Generic.List[object]'
            try{Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false|ForEach-Object{$received.Add($_)}}catch{$_.Exception.Message|Should -Be PC_CLIENT_SERVICE_RESTORE_FAILED}
            $received.Count|Should -Be 0
        }
    }
    It 'detects a broker which unexpectedly relaunched an active core' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCClientInventory {if($script:restored){[pscustomobject]@{key='clash-verge'}}}
            {Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false}|Should -Throw '*PC_CLIENT_RESTARTED*'
        }
    }
    It 'does not probe the real network when connectivity checks are skipped' {
        InModuleScope ProxyClean.Common {
            $r=Invoke-PCClientClose $script:plan -SkipConnectivityChecks -WaitSeconds 0 -Confirm:$false
            $r.connectivity.status|Should -Be not_tested
            Should -Invoke Test-PCConnectivity -Times 0
        }
    }
    It 'refreshes the cache after exit even when the GUI already cleared its proxy settings' {
        InModuleScope ProxyClean.Common {
            $script:plan|Add-Member -NotePropertyName refresh_dns_cache -NotePropertyValue $true
            $r=Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false
            $r.settings.status|Should -Be no_changes
            $r.dns_cache|Should -Be flushed
            Should -Invoke Clear-PCClientDnsCache -Times 1
        }
    }
    It 'reports cache and DNS failures without hiding a verified client exit' {
        InModuleScope ProxyClean.Common {
            $script:plan|Add-Member -NotePropertyName refresh_dns_cache -NotePropertyValue $true
            Mock Clear-PCClientDnsCache {'failed'}
            Mock Test-PCConnectivity {[pscustomobject]@{status='dns_resolution_failed'}}
            $r=Invoke-PCClientClose $script:plan -WaitSeconds 0 -Confirm:$false
            $r.status|Should -Be client_closed
            $r.remaining|Should -Contain '旧域名缓存未能刷新'
            ($r.remaining -join ';')|Should -Match 'DNS 解析失败'
            $r.all_applications_direct|Should -Be not_proven
        }
    }
    It 'does not stop or restore anything in WhatIf mode' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCClientClose $script:plan -WhatIf).status|Should -Be preview
            Should -Invoke Stop-PCClientService -Times 0
            Should -Invoke Restore-PCClientService -Times 0
            Should -Invoke Stop-Process -Times 0
        }
    }
    It 'fails identity checks before any service operation' {
        InModuleScope ProxyClean.Common {
            Mock Test-PCClientProcess {throw 'Process identity changed.'}
            {Invoke-PCClientClose $script:plan -Confirm:$false}|Should -Throw '*identity changed*'
            Should -Invoke Stop-PCClientService -Times 0
            Should -Invoke Restore-PCClientService -Times 0
        }
    }
}
Describe 'Broker identity and one-click policy are explicit' {
    It 'does not show an idle launch broker as an active proxy' {
        $rows=@([pscustomobject]@{ProcessId=882312;ParentProcessId=0;Name='clash-verge-service.exe';SessionId=0;ExecutablePath='C:\Fixture\clash-verge-service.exe'})
        @(Get-PCClientInventory -Processes $rows).Count|Should -Be 0
    }
    It 'does not confuse remote access services or generic cores with brokers' {
        foreach($name in @('sunshine','cloudflared','tailscaled','mihomo','powershell','my-clash-verge-service')){Test-PCClientBroker $name|Should -BeFalse}
    }
    It 'keeps previews read-only without a close request' {
        Get-PCDisconnectTransition client_preview $false $true $false|Should -Be display
    }
    It 'uses one UAC handoff and continues without another confirmation' {
        Get-PCDisconnectTransition client_needs_admin $true $false $false|Should -Be elevate
        Get-PCDisconnectTransition client_preview $true $true $true|Should -Be apply
    }
    It 'does not enter an authorization loop' {
        Get-PCDisconnectTransition client_needs_admin $true $false $true|Should -Be permission_failed
    }
    It 'requires an explicit choice when multiple clients exist' {
        Get-PCDisconnectTransition choose_client $true $false $false|Should -Be choose
    }
    It 'binds continuation to process start time, session, PID and user' {
        $client=[pscustomobject]@{key='clash-verge';members=@([pscustomobject]@{ProcessId=882311;Name='clash-verge.exe';SessionId=1;CreationDate=[DateTime]'2026-01-01T00:00:00Z'})}
        $before=Get-PCClientInstance $client 'fixture-sid'
        $before|Should -Match '^[a-f0-9]{64}$'
        Get-PCClientInstance $client 'other-sid'|Should -Not -Be $before
        $client.members[0].CreationDate=[DateTime]'2026-01-02T00:00:00Z'
        Get-PCClientInstance $client 'fixture-sid'|Should -Not -Be $before
    }
    It 'refuses to infer a missing start time' {
        $client=[pscustomobject]@{key='clash-verge';members=@([pscustomobject]@{ProcessId=882311;Name='clash-verge.exe';SessionId=1})}
        {Get-PCClientInstance $client 'fixture-sid'}|Should -Throw '*identity unavailable*'
    }
}
