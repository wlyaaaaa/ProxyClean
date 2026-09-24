#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
}
Describe 'Empty proxy endpoints do not hide running clients' {
    BeforeEach {
        InModuleScope ProxyClean.Common {
            $script:emptyEndpointSession=(Get-Process -Id $PID).SessionId
            $script:emptyEndpointNode=[pscustomobject]@{ProcessId=880111;Name='clash.exe';ParentProcessId=0;SessionId=$script:emptyEndpointSession;ExecutablePath='C:\Fixture\clash.exe'}
            $script:emptyEndpointListeners=@([pscustomobject]@{OwningProcess=880111;LocalAddress='127.0.0.1';LocalPort=41234})
            $script:emptyEndpointSnapshot=[pscustomobject]@{
                sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;observedUtc=[DateTimeOffset]::UtcNow.ToString('O');isSystem=$false;sessionId=$script:emptyEndpointSession
                availability=[pscustomobject]@{listeners='observed';adapters='observed';routes='observed';wininet='observed';environment='observed';git='observed';winhttp='not_inspected';docker='not_inspected'}
                systemProxy=[pscustomobject]@{enabled=$false;server='127.0.0.1:41234';pac='';values=[pscustomobject]@{ProxyEnable=[pscustomobject]@{exists=$true;value=0;kind='DWord'};ProxyServer=[pscustomobject]@{exists=$true;value='127.0.0.1:41234';kind='String'}}}
                listeners=$script:emptyEndpointListeners;adapters=@();routes=@();environment=@();git=@();winhttp=$null;docker=$null
            }
            Mock Get-PCSnapshot {$script:emptyEndpointSnapshot}
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='none';available=$false}}
            Mock Get-CimInstance {if($ClassName -eq 'Win32_Process'){$script:emptyEndpointNode}}
            Mock Get-Process {[pscustomobject]@{Id=$Id;ProcessName='clash';SessionId=$script:emptyEndpointSession}}
            Mock Get-PCProcessIdentity {[pscustomobject]@{pid=880111;name='clash';path='C:\Fixture\clash.exe';session=$script:emptyEndpointSession;start_utc='fixture'}}
            Mock Stop-Process {}
            Mock Request-PCClientWindowClose {}
            Mock Invoke-PCRepairPlan {}
            Mock Test-PCConnectivity {}
        }
    }
    It 'inventory handles <Shape> while preserving real listeners' -ForEach @(
        @{Shape='Empty';Published=$false},@{Shape='Null';Published=$false},@{Shape='NullOnly';Published=$false},@{Shape='Mixed';Published=$true},@{Shape='Matched';Published=$true}
    ) {
        InModuleScope ProxyClean.Common -Parameters @{Shape=$Shape;Published=$Published} {
            param($Shape,$Published)
            $endpoints=@()
            switch($Shape){
                'Null' {$endpoints=$null}
                'NullOnly' {$endpoints=@($null)}
                'Mixed' {$endpoints=@($null)+@(Get-ProxyEndpoints '127.0.0.1:41234')+@($null)}
                'Matched' {$endpoints=@(Get-ProxyEndpoints '127.0.0.1:41234')}
            }
            $r=@(Get-PCClientInventory -Processes @($script:emptyEndpointNode) -Listeners $script:emptyEndpointListeners -Endpoints $endpoints)
            $r.Count|Should -Be 1
            $r[0].ports|Should -Contain 41234
            $r[0].published|Should -Be $Published
        }
    }
    It 'listener diagnostics handle <Shape> without inventing an endpoint' -ForEach @(
        @{Shape='Empty';Published=$false},@{Shape='Null';Published=$false},@{Shape='NullOnly';Published=$false},@{Shape='Mixed';Published=$true},@{Shape='Matched';Published=$true}
    ) {
        InModuleScope ProxyClean.Common -Parameters @{Shape=$Shape;Published=$Published} {
            param($Shape,$Published)
            $endpoints=@()
            switch($Shape){
                'Null' {$endpoints=$null}
                'NullOnly' {$endpoints=@($null)}
                'Mixed' {$endpoints=@($null)+@(Get-ProxyEndpoints '127.0.0.1:41234')+@($null)}
                'Matched' {$endpoints=@(Get-ProxyEndpoints '127.0.0.1:41234')}
            }
            $r=@(Get-PCListenerCandidates -Listeners $script:emptyEndpointListeners -Endpoints $endpoints)
            $r.Count|Should -Be 1
            $r[0].published_by_system_proxy|Should -Be $Published
            $r[0].http_proxy_confirmed|Should -BeFalse
        }
    }
    It '<Action> works through real inventory with <State>' -ForEach @(
        @{Action='Inspect';State='DisabledStored'},@{Action='DisconnectPreview';State='DisabledStored'},
        @{Action='Inspect';State='DisabledEmpty'},@{Action='DisconnectPreview';State='DisabledEmpty'},
        @{Action='Inspect';State='EnabledEmpty'},@{Action='DisconnectPreview';State='EnabledEmpty'},
        @{Action='Inspect';State='Unavailable'},@{Action='DisconnectPreview';State='Unavailable'},
        @{Action='Inspect';State='EnabledMatched'},@{Action='DisconnectPreview';State='EnabledMatched'}
    ) {
        InModuleScope ProxyClean.Common -Parameters @{Action=$Action;State=$State} {
            param($Action,$State)
            switch($State){
                'DisabledEmpty' {$script:emptyEndpointSnapshot.systemProxy.server=''}
                'EnabledEmpty' {$script:emptyEndpointSnapshot.systemProxy.enabled=$true;$script:emptyEndpointSnapshot.systemProxy.server=''}
                'Unavailable' {$script:emptyEndpointSnapshot.systemProxy=$null;$script:emptyEndpointSnapshot.availability.wininet='unknown'}
                'EnabledMatched' {$script:emptyEndpointSnapshot.systemProxy.enabled=$true;$script:emptyEndpointSnapshot.systemProxy.values.ProxyEnable.value=1}
            }
            $r=Invoke-PCWorkflow -Action $Action -Confirm:$false
            if($Action -eq 'Inspect'){
                $r.status|Should -Be inspected
                $r.client_observation|Should -Be observed
                $r.clients.Count|Should -Be 1
                $r.clients[0].published|Should -Be ($State -eq 'EnabledMatched')
                $r.snapshot.listener_candidates.Count|Should -Be 1
            }else{
                $r.status|Should -Be client_preview
                $r.plan.key|Should -Be clash-core
                $r.plan.ports|Should -Contain 41234
            }
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Request-PCClientWindowClose -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0
            Should -Invoke Test-PCConnectivity -Times 0
        }
    }
    It 'still offers a choice when several clients run without a system proxy' {
        InModuleScope ProxyClean.Common {
            Mock Get-CimInstance {
                if($ClassName -eq 'Win32_Process'){
                    $script:emptyEndpointNode
                    [pscustomobject]@{ProcessId=880112;Name='FlyingBird.exe';ParentProcessId=0;SessionId=$script:emptyEndpointSession;ExecutablePath='C:\Fixture\FlyingBird.exe'}
                }
            }
            $r=Invoke-PCWorkflow DisconnectPreview -Confirm:$false
            $r.status|Should -Be choose_client
            $r.clients.Count|Should -Be 2
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'does not weaken the required endpoint contract or classify null as dead' {
        {Get-PCListenerState -Endpoint $null -Listeners @()}|Should -Throw
    }
}