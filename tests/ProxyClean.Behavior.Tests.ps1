#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    function New-FixtureSnapshot {
        param([string]$Proxy='http=127.0.0.1:34567;https=proxy.example.test:443',[object[]]$Listeners=@())
        $value=[pscustomobject][ordered]@{exists=$true;value=$Proxy;kind='String'}
        [pscustomobject]@{
            sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;observedUtc=[DateTimeOffset]::UtcNow.ToString('O');isSystem=$false;sessionId=1
            availability=[pscustomobject]@{wininet='observed';environment='observed';git='observed';listeners='observed';adapters='observed';routes='observed';winhttp='not_inspected';docker='not_inspected'}
            systemProxy=[pscustomobject]@{enabled=$true;server=$Proxy;pac='';values=[pscustomobject]@{ProxyEnable=[pscustomobject][ordered]@{exists=$true;value=1;kind='DWord'};ProxyServer=$value}}
            listeners=$Listeners;adapters=@();routes=@();environment=@();git=@();winhttp=$null;docker=$null
        }
    }
}
Describe 'One parser for all proxy operations' {
    It 'classifies exact endpoints: <value>' -ForEach @(
        @{value='http://127.0.0.1:34567';local=$true;port=34567}
        @{value='http://[::1]:34567';local=$true;port=34567}
        @{value='http://localhost:34567';local=$true;port=34567}
        @{value='http://127.0.0.2:34567';local=$true;port=34567}
        @{value='http://mylocalhost:34567';local=$false;port=34567}
        @{value='http://127.0.0.1:34567@proxy.example.test:8443';local=$false;port=8443}
        @{value='https=proxy.example.test:443';local=$false;port=443}
    ) {
        $e=@(Get-ProxyEndpoints $value);$e|Should -HaveCount 1
        $e[0].local|Should -Be $local;$e[0].port|Should -Be $port
    }
    It 'preserves a remote mapping when removing one local endpoint' {
        $r=Remove-PCProxyEndpoint 'http=localhost:34567;https=proxy.example.test:443' 34567
        $r.changed|Should -BeTrue;$r.value|Should -BeExactly 'https=proxy.example.test:443'
    }
    It 'does not cross-match a remote URI user-info fragment' {
        $r=Remove-PCProxyEndpoint 'http://127.0.0.1:34567@proxy.example.test:8443' 34567
        $r.changed|Should -BeFalse
    }
    It 'safely represents removal of the last endpoint' {
        (Remove-PCProxyEndpoint 'http://localhost:34567' 34567).value|Should -BeNullOrEmpty
    }
    It 'preserves malformed mixed settings' {
        $r=Remove-PCProxyEndpoint 'http=;https=localhost:34567' 34567
        $r.changed|Should -BeFalse
    }
    It 'never displays credentials, path parameters or private remote hostnames' {
        $safe=Get-PCSafeProxyValue 'https://fixture-user:fixture-secret@proxy.example.test:8443/private?token=fixture-secret#private'
        $safe|Should -Not -Match 'fixture|example|private|token|@'
        $safe|Should -Match '<remote>:8443'
    }
}
Describe 'Listener matching includes address family and exact binding' {
    It 'classifies <endpoint> against <binding> as <expected>' -ForEach @(
        @{endpoint='http://127.0.0.1:34567';binding='192.0.2.10';expected='dead'}
        @{endpoint='http://127.0.0.1:34567';binding='127.0.0.1';expected='listening'}
        @{endpoint='http://127.0.0.1:34567';binding='0.0.0.0';expected='listening'}
        @{endpoint='http://127.0.0.1:34567';binding='::1';expected='dead'}
        @{endpoint='http://127.0.0.1:34567';binding='::';expected='unknown'}
        @{endpoint='http://[::1]:34567';binding='::';expected='listening'}
        @{endpoint='http://[::1]:34567';binding='0.0.0.0';expected='dead'}
        @{endpoint='http://127.0.0.2:34567';binding='127.0.0.1';expected='dead'}
    ) {
        $e=@(Get-ProxyEndpoints $endpoint)[0]
        Get-PCListenerState $e @([pscustomobject]@{LocalPort=34567;LocalAddress=$binding})|Should -Be $expected
    }
    It 'does not turn a listener query failure into a dead endpoint' {
        Test-LocalProxyDead -Value 'http://localhost:34567' -Listeners @() -QuerySucceeded:$false|Should -BeFalse
    }
    It 'does not clear a mixture of dead local and valid remote proxies' {
        Test-LocalProxyDead 'http=localhost:34567;https=proxy.example.test:443' -Listeners @()|Should -BeFalse
    }
}
Describe 'Repair planning and public diagnostics are consistent' {
    It 'plans a scoped mapping change rather than disabling the whole mixed proxy' {
        $plan=Get-PCRepairPlan -Snapshot (New-FixtureSnapshot) -Port 34567
        $plan.steps|Should -HaveCount 1
        $plan.steps[0].name|Should -Be 'ProxyServer'
        $plan.steps[0].after.value|Should -Be 'https=proxy.example.test:443'
    }
    It 'does not clean a fully live endpoint' {
        $s=New-FixtureSnapshot -Proxy 'http://127.0.0.1:34567' -Listeners @([pscustomobject]@{LocalPort=34567;LocalAddress='127.0.0.1'})
        (Get-PCRepairPlan $s).steps|Should -HaveCount 0
    }
    It 'does not report a LAN-only listener as a published local proxy' {
        $s=New-FixtureSnapshot -Proxy 'http://127.0.0.1:34567' -Listeners @([pscustomobject]@{LocalPort=34567;LocalAddress='192.0.2.4'})
        $public=ConvertTo-PCPublicSnapshot $s
        $public.listeners|Should -HaveCount 0;$public.endpoints[0].state|Should -Be 'dead'
    }
    It 'does not remove any route without a physical fallback' {
        $s=New-FixtureSnapshot -Proxy ''
        $s.adapters=@([pscustomobject]@{InterfaceIndex=2;HardwareInterface=$false;Status='Up'})
        $s.routes=@([pscustomobject]@{InterfaceIndex=2;DestinationPrefix='0.0.0.0/0';NextHop='198.18.0.1';RouteMetric=1})
        @((Get-PCRepairPlan $s -Direct).steps|Where-Object kind -eq 'Route')|Should -HaveCount 0
    }
    It 'preserves active TUN routes unless direct mode is explicit' {
        $s=New-FixtureSnapshot -Proxy ''
        $s.adapters=@([pscustomobject]@{InterfaceIndex=1;HardwareInterface=$true;Status='Up'},[pscustomobject]@{InterfaceIndex=2;HardwareInterface=$false;Status='Up'})
        $s.routes=@([pscustomobject]@{InterfaceIndex=1;DestinationPrefix='0.0.0.0/0';NextHop='192.0.2.1';RouteMetric=10},[pscustomobject]@{InterfaceIndex=2;DestinationPrefix='0.0.0.0/0';NextHop='198.18.0.1';RouteMetric=1})
        @((Get-PCRepairPlan $s).steps|Where-Object kind -eq 'Route')|Should -HaveCount 0
        @((Get-PCRepairPlan $s -Direct).steps|Where-Object kind -eq 'Route')|Should -HaveCount 1
    }
    It 'keeps a down fake-ip adapter out of active TUN evidence' {
        $s=New-FixtureSnapshot -Proxy ''
        $s.adapters=@([pscustomobject]@{InterfaceIndex=2;HardwareInterface=$false;Status='Down'})
        $s.routes=@([pscustomobject]@{InterfaceIndex=2;InterfaceAlias='fixture';DestinationPrefix='0.0.0.0/0';NextHop='198.18.0.1';RouteMetric=1})
        (ConvertTo-PCPublicSnapshot $s).tun_routes|Should -HaveCount 0
    }
    It 'keeps preimages out of public plans' {
        $plan=Get-PCRepairPlan -Snapshot (New-FixtureSnapshot -Proxy 'http://fixture-user:fixture-secret@localhost:34567') -Direct
        (ConvertTo-PCPublicPlan $plan|ConvertTo-Json -Depth 10)|Should -Not -Match 'fixture-secret|fixture-user|before|after'
    }
    It 'WhatIf never creates an undo journal or performs resource writes' {
        $plan=Get-PCRepairPlan -Snapshot (New-FixtureSnapshot -Proxy 'localhost:34567')
        Mock Save-PCJournal -ModuleName ProxyClean.Common {throw 'Unexpected journal write'}
        Mock Set-PCResourceValue -ModuleName ProxyClean.Common {throw 'Unexpected resource write'}
        (Invoke-PCRepairPlan $plan -WhatIf).status|Should -Be 'preview'
        Should -Invoke Save-PCJournal -ModuleName ProxyClean.Common -Times 0
        Should -Invoke Set-PCResourceValue -ModuleName ProxyClean.Common -Times 0
    }
}
Describe 'Durable one-operation undo with injected failures' {
    BeforeEach {
        InModuleScope ProxyClean.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:fixtureJournal=Join-Path $Root ([Guid]::NewGuid().ToString('N')+'.dpapi')
            $script:fixtureValues=@{
                HTTP_PROXY=[pscustomobject][ordered]@{exists=$true;value='http://fixture-secret@localhost:34567';kind='String'}
                HTTPS_PROXY=[pscustomobject][ordered]@{exists=$true;value='http://localhost:34568';kind='String'}
            }
            $script:fixtureFailApply=$false;$script:fixtureFailRestore=$false
            Mock Get-PCJournalPath {$script:fixtureJournal}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCResourceValue {param($Step) $script:fixtureValues[$Step.name]}
            Mock Set-PCResourceValue {
                param($Step,$Value)
                if($script:fixtureFailApply -and $Step.name -eq 'HTTPS_PROXY' -and -not $Value.exists){throw 'Injected second effect failure'}
                if($script:fixtureFailRestore -and $Step.name -eq 'HTTP_PROXY' -and $Value.exists){throw 'Injected inverse failure'}
                $script:fixtureValues[$Step.name]=$Value
            }
            $absent=[pscustomobject][ordered]@{exists=$false;value=$null;kind=$null}
            $script:fixturePlan=[pscustomobject]@{schema='proxyclean.plan.v1';id=[Guid]::NewGuid().ToString('N');sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;steps=@(
                (New-PCStep 'UserEnv' 'HTTP_PROXY' $script:fixtureValues.HTTP_PROXY $absent 'fixture'),
                (New-PCStep 'UserEnv' 'HTTPS_PROXY' $script:fixtureValues.HTTPS_PROXY $absent 'fixture')
            )}
        }
    }
    It 'applies and verifies, then restores both exact preimages' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false).status|Should -Be 'applied'
            (Get-PCJournal).phase|Should -Be 'completed'
            [IO.File]::ReadAllText($script:fixtureJournal)|Should -Not -Match 'fixture-secret|HTTP_PROXY'
            (Invoke-PCUndo -Confirm:$false).status|Should -Be 'recovered'
            $script:fixtureValues.HTTP_PROXY.exists|Should -BeTrue
            (Get-PCJournal).phase|Should -Be 'undone'
        }
    }
    It 'rolls back earlier changes if a later effect fails' {
        InModuleScope ProxyClean.Common {
            $script:fixtureFailApply=$true
            (Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false).status|Should -Be 'failed_rolled_back'
            $script:fixtureValues.HTTP_PROXY.exists|Should -BeTrue
            (Get-PCJournal).phase|Should -Be 'undone'
        }
    }
    It 'retains incomplete recovery and blocks a new cleanup until repaired' {
        InModuleScope ProxyClean.Common {
            $script:fixtureFailApply=$true;$script:fixtureFailRestore=$true
            (Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false).status|Should -Be 'recovery_required'
            (Get-PCJournal).phase|Should -Be 'recovery_required'
            {Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false}|Should -Throw '*unfinished*'
            $script:fixtureFailRestore=$false
            (Invoke-PCUndo -Confirm:$false).status|Should -Be 'recovered'
        }
    }
    It 'preserves another program changes rather than forcing undo over them' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false).status|Should -Be 'applied'
            $script:fixtureValues.HTTP_PROXY=[pscustomobject][ordered]@{exists=$true;value='http://new.example.test:8443';kind='String'}
            (Invoke-PCUndo -Confirm:$false).status|Should -Be 'recovery_required'
            $script:fixtureValues.HTTP_PROXY.value|Should -Be 'http://new.example.test:8443'
        }
    }
    It 'refuses stale plans before their first effect' {
        InModuleScope ProxyClean.Common {
            $script:fixtureValues.HTTP_PROXY=[pscustomobject][ordered]@{exists=$true;value='http://new.example.test:8443';kind='String'}
            (Invoke-PCRepairPlan $script:fixturePlan -Confirm:$false).status|Should -Be 'plan_changed'
            Should -Invoke Set-PCResourceValue -Times 0
        }
    }
}
Describe 'Atomic Git proxy writes use isolated configuration' {
    It 'preserves unrelated Git settings and restores the original proxy list' {
        $old=$env:GIT_CONFIG_GLOBAL
        $path=Join-Path $TestDrive 'isolated config.gitconfig'
        try{
            $env:GIT_CONFIG_GLOBAL=$path
            $git=Get-PCGitPath
            [void](Invoke-PCNative $git @('config','--global','user.name','Fixture Name'))
            [void](Invoke-PCNative $git @('config','--global','--add','http.proxy','http://localhost:34567'))
            [void](Invoke-PCNative $git @('config','--global','--add','http.proxy','https://proxy.example.test:443'))
            $target=Get-PCGitWriteTarget -Key http.proxy
            $before=@(Get-PCGitValues http.proxy)
            $step=New-PCStep Git http.proxy $before @('https://proxy.example.test:443') 'fixture'
            $step|Add-Member -NotePropertyName target_file -NotePropertyValue $target
            Set-PCGitAtomicValues -Step $step -Values @($step.after)
            @(Get-PCGitValues http.proxy)|Should -HaveCount 1
            (Invoke-PCNative $git @('config','--global','--get','user.name')).stdout.Trim()|Should -Be 'Fixture Name'
            Set-PCGitAtomicValues -Step $step -Values @($step.before)
            @(Get-PCGitValues http.proxy)|Should -HaveCount 2
            Test-Path -LiteralPath ($path+'.lock')|Should -BeFalse
        }finally{$env:GIT_CONFIG_GLOBAL=$old}
    }
}
