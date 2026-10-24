#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    function New-IdentityNode([int]$Id,[string]$Name,[int]$Parent=0,[string]$Path=('C:\Fixture\'+$Name+'.exe')) {
        [pscustomobject]@{ProcessId=$Id;Name=$Name+'.exe';ParentProcessId=$Parent;SessionId=(Get-Process -Id $PID).SessionId;ExecutablePath=$Path;CreationDate=[DateTime]'2026-01-01T00:00:00Z'}
    }
}
Describe 'Client identity survives real host JSON conversion' {
    It 'recognizes the unchanged current process after native JSON round trip' {
        $identity=Get-PCProcessIdentity -ProcessId $PID
        $roundTrip=$identity|ConvertTo-Json -Depth 8|ConvertFrom-Json
        Test-PCClientProcess $roundTrip|Should -BeTrue
        $roundTrip.start_utc=([DateTimeOffset]$identity.start_utc).AddTicks(1).UtcDateTime.ToString('O')
        {Test-PCClientProcess $roundTrip}|Should -Throw '*identity changed*'
    }
    It 'keeps date-shaped strings unchanged in the elevated transport result' {
        InModuleScope ProxyClean.Common {
            $script:transportIdentity=[pscustomobject]@{start_utc='2026-01-01T00:00:00.1234567Z';observedUtc='2026-01-01T08:00:00.1234567+08:00';nested=[pscustomobject]@{CreationDate='2026-01-01T00:00:00Z'}}
            $script:transportJson=$script:transportIdentity|ConvertTo-Json -Depth 8
            Mock Invoke-ProjectElevated {$global:LASTEXITCODE=0;$script:transportJson}
            $result=Invoke-PCAdminCall Get-PCProcessIdentity @{ProcessId=$PID}
            $result.start_utc|Should -BeOfType string
            $result.start_utc|Should -BeExactly $script:transportIdentity.start_utc
            $result.observedUtc|Should -BeExactly $script:transportIdentity.observedUtc
            $result.nested.CreationDate|Should -BeExactly $script:transportIdentity.nested.CreationDate
        }
    }
    It 'hashes UTC objects and equivalent offset strings as the same client instance' {
        $client=[pscustomobject]@{key='fixture';members=@((New-IdentityNode 881001 xray))}
        $instance=Get-PCClientInstance $client fixture-sid
        $client.members[0].CreationDate='2026-01-01T08:00:00.0000000+08:00'
        Get-PCClientInstance $client fixture-sid|Should -BeExactly $instance
        $roundTrip=$client|ConvertTo-Json -Depth 8|ConvertFrom-Json
        Get-PCClientInstance $roundTrip fixture-sid|Should -BeExactly $instance
    }
}
Describe 'Known installed core paths identify orphaned client members' {
    It 'combines only orphan cores from the same family and path with every port and a stable key' {
        $rows=@((New-IdentityNode 881001 mihomo 889997),(New-IdentityNode 881002 mihomo 889998));$listeners=@(881001,881002|ForEach-Object {[pscustomobject]@{OwningProcess=$_;LocalAddress='127.0.0.1';LocalPort=(45000+$_-881000)}})
        $clients=@(Get-PCClientInventory -Processes $rows -Listeners $listeners);$clients.Count|Should -Be 1
        $clients[0].members|Should -HaveCount 2;$clients[0].ports|Should -HaveCount 2
        $reversed=@(Get-PCClientInventory -Processes @($rows[1],$rows[0]));$reversed[0].key|Should -BeExactly $clients[0].key
        $rows[1].ExecutablePath='C:\OtherFixture\mihomo.exe';@(Get-PCClientInventory -Processes $rows).Count|Should -Be 2
    }
    It 'merges an orphan with the managed core path and keeps a different installation separate' {
        $rows=@((New-IdentityNode 881001 FlyingBird),(New-IdentityNode 881002 FlyingBirdHelperService),(New-IdentityNode 881003 FlyingBirdCore 881002),(New-IdentityNode 881004 FlyingBirdCore 889999),(New-IdentityNode 881005 FlyingBirdCore 0 'C:\OtherFixture\FlyingBirdCore.exe'))
        $listeners=@(881003,881004,881005|ForEach-Object {[pscustomobject]@{OwningProcess=$_;LocalAddress='127.0.0.1';LocalPort=(45000+$_-881000)}})
        $clients=@(Get-PCClientInventory -Processes $rows -Listeners $listeners)
        $clients.Count|Should -Be 2
        $managed=@($clients|Where-Object key -eq flyingbird)[0]
        $managed.members.ProcessId|Should -Contain 881004
        $managed.members.ProcessId|Should -Not -Contain 881005
        $managed.ports|Should -HaveCount 2
    }
    It 'keeps a same-path core separate when its independent parent is still present' {
        $rows=@((New-IdentityNode 881001 clash-verge),(New-IdentityNode 881002 mihomo 881001),(New-IdentityNode 881003 mihomo 881004),(New-IdentityNode 881004 powershell))
        @(Get-PCClientInventory -Processes $rows).Count|Should -Be 2
    }
    It 'finds a known generic core path after its controller exits without requiring a listener' {
        $plan=[pscustomobject]@{key='clash-verge';family_key='clash-verge';members=@([pscustomobject]@{name='mihomo';path='C:\Fixture\mihomo.exe'})}
        $orphan=[pscustomobject]@{key='clash-core@881001@fixture';family_key='clash-core';members=@((New-IdentityNode 881001 mihomo))}
        Test-PCSelectedClientPresent -Plan $plan -Inventory @($orphan)|Should -BeTrue
        $orphan.members[0].ExecutablePath='C:\OtherFixture\mihomo.exe'
        Test-PCSelectedClientPresent -Plan $plan -Inventory @($orphan)|Should -BeFalse
    }
}
