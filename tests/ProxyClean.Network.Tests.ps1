#Requires -Version 5.1
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force }
Describe 'WiFi selection does not assume a working connection' {
    It 'selects an explicitly named disconnected adapter with no IP metadata' {
        $a=Get-PCWifiAdapter -InterfaceAlias 'Custom adapter' -Adapters @([pscustomobject]@{Name='Custom adapter';HardwareInterface=$true;Status='Down';InterfaceIndex=3})
        $a.Name|Should -Be 'Custom adapter';$a.Status|Should -Be 'Down'
    }
    It 'does not pick the first of multiple wireless adapters' {
        {Get-PCWifiAdapter -Adapters @([pscustomobject]@{Name='Wi-Fi';HardwareInterface=$true;Status='Up'},[pscustomobject]@{Name='Wi-Fi 2';HardwareInterface=$true;Status='Down'})}|Should -Throw '*Exactly one*'
    }
    It 'excludes virtual adapters even when explicitly named' {
        {Get-PCWifiAdapter -InterfaceAlias 'Wi-Fi fake' -Adapters @([pscustomobject]@{Name='Wi-Fi fake';HardwareInterface=$false;Status='Up'})}|Should -Throw
    }
}
Describe 'Network reset effects have checked failure paths' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:fixtureWifi=[pscustomobject]@{Name='Wi-Fi fixture';HardwareInterface=$true;Status='Up';InterfaceIndex=3}
            Mock Get-PCWifiAdapter {$script:fixtureWifi}
            Mock Test-PCAdministrator {$true}
            Mock Disable-NetAdapter {}
            Mock Enable-NetAdapter {}
            Mock Start-Sleep {}
            Mock Get-PCWifiSnapshot {[pscustomobject]@{status='Up';ipv4_address_count=1}}
            Mock Get-NetIPInterface {[pscustomobject]@{Dhcp='Enabled'}}
            Mock Invoke-PCNative {[pscustomobject]@{exit_code=0;stdout='';stderr=''}}
        }
    }
    It 'never disables an adapter during WhatIf' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCWifiReset -Adapter $script:fixtureWifi -Mode AdapterReset -WhatIf).status|Should -Be 'preview'
            Should -Invoke Disable-NetAdapter -Times 0
        }
    }
    It 're-enables the adapter even when interrupted after disable' {
        InModuleScope ProxyClean.Common {
            Mock Start-Sleep {throw 'Injected interruption'}
            {Invoke-PCWifiReset -Adapter $script:fixtureWifi -Mode AdapterReset -Confirm:$false}|Should -Throw
            Should -Invoke Disable-NetAdapter -Times 1
            Should -Invoke Enable-NetAdapter -Times 1
        }
    }
    It 'does not report success when re-enable fails' {
        InModuleScope ProxyClean.Common {
            Mock Enable-NetAdapter {throw 'Injected enable failure'}
            {Invoke-PCWifiReset -Adapter $script:fixtureWifi -Mode AdapterReset -Confirm:$false}|Should -Throw
        }
    }
    It 'attempts lease renewal even after a failed release command' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCNative {param($FilePath,$ArgumentList) if($ArgumentList[0] -eq '/release'){throw 'Injected release failure'};[pscustomobject]@{exit_code=0;stdout='';stderr=''}}
            {Invoke-PCWifiReset -Adapter $script:fixtureWifi -Mode SoftReset -Confirm:$false}|Should -Throw
            Should -Invoke Invoke-PCNative -Times 1 -ParameterFilter {$ArgumentList[0] -eq '/renew'}
        }
    }
    It 'preserves static addressing instead of releasing it' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetIPInterface {[pscustomobject]@{Dhcp='Disabled'}}
            {Invoke-PCWifiReset -Adapter $script:fixtureWifi -Mode SoftReset -Confirm:$false}|Should -Throw '*static*'
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
}
Describe 'Closing a port is not closing a guessed client family' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:fixtureListeners=@(
                [pscustomobject]@{LocalPort=34567;LocalAddress='127.0.0.1';OwningProcess=501},
                [pscustomobject]@{LocalPort=34567;LocalAddress='192.0.2.10';OwningProcess=502}
            )
            $script:fixtureIdentityChanged=$false
            Mock Get-NetTCPConnection {$script:fixtureListeners}
            Mock Get-PCProcessIdentity {param($ProcessId) [pscustomobject]@{pid=$ProcessId;name='fixture-client';start_utc=if($script:fixtureIdentityChanged){'2026-01-02'}else{'2026-01-01'};path='C:\fixture\client.exe';session=1}}
            Mock Stop-Process {param($Id) $script:fixtureListeners=@($script:fixtureListeners|Where-Object { $_.OwningProcess -notin @($Id) })}
            Mock Get-PCSnapshot {[pscustomobject]@{
                sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;observedUtc='fixture';systemProxy=$null;environment=@();git=@();listeners=@();adapters=@();routes=@()
                availability=[pscustomobject]@{wininet='observed';environment='observed';git='observed';listeners='observed';routes='observed';adapters='observed'}
            }}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='no_changes'}}
            Mock Set-PCResourceValue {throw 'No real resource writes are allowed by this test.'}
            Mock Send-PCSettingsChanged {}
        }
    }
    It 'does not select a LAN-only listener at the same port' {
        InModuleScope ProxyClean.Common {
            $plan=Get-PCStopPlan -Port 34567
            $plan.processes|Should -HaveCount 1;$plan.processes[0].pid|Should -Be 501
        }
    }
    It 'does not guess any process names when the port is closed' {
        InModuleScope ProxyClean.Common {
            $script:fixtureListeners=@()
            Mock Get-Process {throw 'Unexpected process-name lookup'}
            (Get-PCStopPlan -Port 18090).processes|Should -HaveCount 0
            Should -Invoke Get-Process -Times 0
        }
    }
    It 'does not stop a reused PID or clean settings after an identity conflict' {
        InModuleScope ProxyClean.Common {
            $plan=Get-PCStopPlan -Port 34567
            $script:fixtureIdentityChanged=$true;$script:fixtureListeners=@()
            (Invoke-PCStopPlan -Plan $plan -Confirm:$false).status|Should -Be 'incomplete'
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'closes only the selected local listener and then uses a per-port plan' {
        InModuleScope ProxyClean.Common {
            $plan=Get-PCStopPlan -Port 34567
            $result=Invoke-PCStopPlan -Plan $plan -Confirm:$false
            $result.status|Should -Be 'closed'
            Should -Invoke Stop-Process -Times 1 -ParameterFilter {$Id -eq 501}
            Should -Invoke Stop-Process -Times 0 -ParameterFilter {$Id -eq 502}
            Should -Invoke Invoke-PCRepairPlan -Times 1 -ParameterFilter {$Plan.port -eq 34567 -and $Plan.mode -eq 'port'}
        }
    }
    It 'previews without stopping anything or changing configuration' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCStopPlan -Plan (Get-PCStopPlan -Port 34567) -WhatIf).status|Should -Be 'preview'
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
}
Describe 'IPv6 remains scoped to physical adapters' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:fixtureAdapters=@([pscustomobject]@{Name='Physical fixture';InterfaceIndex=1;Status='Up';HardwareInterface=$true},[pscustomobject]@{Name='Unknown virtual';InterfaceIndex=2;Status='Up';HardwareInterface=$false},[pscustomobject]@{Name='natpierce';InterfaceIndex=3;Status='Up';HardwareInterface=$true})
            $script:fixtureBindings=@{'Physical fixture'=$true;'Unknown virtual'=$true;'natpierce'=$true}
            Mock Get-NetAdapter {param($Name) if($Name){$script:fixtureAdapters|Where-Object Name -eq $Name}else{$script:fixtureAdapters}}
            Mock Get-NetAdapterBinding {param($Name) [pscustomobject]@{Enabled=$script:fixtureBindings[[string]@($Name)[0]]}}
            Mock Enable-NetAdapterBinding {param($Name) foreach($n in @($Name)){$script:fixtureBindings[[string]$n]=$true}}
            Mock Disable-NetAdapterBinding {param($Name) foreach($n in @($Name)){$script:fixtureBindings[[string]$n]=$false}}
            Mock Test-PCAdministrator {$true}
        }
    }
    It 'does not modify virtual or excluded tunnel adapters' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCIPv6Change -Mode Disable -Confirm:$false).changed|Should -Be 1
            $script:fixtureBindings['Unknown virtual']|Should -BeTrue
            $script:fixtureBindings['natpierce']|Should -BeTrue
        }
    }
    It 'WhatIf has no binding effects' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCIPv6Change -Mode Disable -WhatIf).status|Should -Be 'preview'
            Should -Invoke Disable-NetAdapterBinding -Times 0
        }
    }
    It 'restores the original binding when a write fails' {
        InModuleScope ProxyClean.Common {
            Mock Disable-NetAdapterBinding {param($Name) foreach($n in @($Name)){$script:fixtureBindings[[string]$n]=$false};throw 'Injected failure after effect'}
            {Invoke-PCIPv6Change -Mode Disable -Confirm:$false}|Should -Throw '*restored*'
            $script:fixtureBindings['Physical fixture']|Should -BeTrue
        }
    }
}
