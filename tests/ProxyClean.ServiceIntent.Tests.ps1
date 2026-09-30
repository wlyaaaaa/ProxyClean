#Requires -Version 5.1
BeforeAll {Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force}
Describe 'Clash Verge persisted run intent is scoped and recoverable' {
    BeforeEach {
        InModuleScope ProxyClean.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:fixtureRoot=Join-Path $Root ([Guid]::NewGuid().ToString('N'))
            $key='a'*64
            [void][IO.Directory]::CreateDirectory((Join-Path $script:fixtureRoot ('users\'+$key)))
            $script:ownerPath=Join-Path $script:fixtureRoot 'active-owner.json'
            $script:statePath=Join-Path $script:fixtureRoot ('users\'+$key+'\desired-state.json')
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            [IO.File]::WriteAllText($script:ownerPath,(@{owner_key=$key;identity=@{Windows=@{sid=$sid}};generation=3;session_token_hash='fixture'}|ConvertTo-Json -Compress))
            $script:original='{"core_should_be_running":true,"generation":23,"last_clash_config":{"core_config":{"core_path":"C:\\Fixture\\verge-mihomo.exe"}},"future":{"preserved":[1,2,3]}}'
            [IO.File]::WriteAllText($script:statePath,$script:original)
            $script:service=[pscustomobject]@{name='clash_verge_service';pid=987651;path=(Join-Path $script:fixtureRoot 'bin\clash-verge-service.exe')}
            $script:plan=[pscustomobject]@{key='clash-verge';sid=$sid;services=@($script:service);members=@([pscustomobject]@{pid=987652;name='verge-mihomo';path='\\?\C:\Fixture\verge-mihomo.exe'})}
            $script:journalPath=Join-Path $script:fixtureRoot 'journal.dpapi'
            Mock Get-PCJournalPath {$script:journalPath}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-CimInstance {[pscustomobject]@{Name=$script:service.name;PathName=$script:service.path;State='Stopped'}}
        }
    }
    It 'changes only the run boolean and retains unknown fields byte for byte' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            Set-PCResourceValue $step $step.after
            [IO.File]::ReadAllText($script:statePath)|Should -Be ($script:original.Replace(':true,',':false,'))
            $step.before|Should -Be $script:original
        }
    }
    It 'does not modify the active owner identity or session' {
        InModuleScope ProxyClean.Common {
            $before=[IO.File]::ReadAllText($script:ownerPath)
            $step=Get-PCClashVergeIntentStep $script:plan;Set-PCResourceValue $step $step.after
            [IO.File]::ReadAllText($script:ownerPath)|Should -Be $before
        }
    }
    It 'does not infer ownership from the client name' {
        InModuleScope ProxyClean.Common {
            $script:plan.sid='other-user'
            {Get-PCClashVergeIntentStep $script:plan}|Should -Throw '*OWNER_CHANGED*'
            [IO.File]::ReadAllText($script:statePath)|Should -Be $script:original
        }
    }
    It 'rejects a different core installation' {
        InModuleScope ProxyClean.Common {
            $script:plan.members[0].path='C:\Other\verge-mihomo.exe'
            {Get-PCClashVergeIntentStep $script:plan}|Should -Throw '*OWNER_CHANGED*'
        }
    }
    It 'does nothing for a different client or older installation' {
        InModuleScope ProxyClean.Common {
            $script:plan.key='flyingbird';Get-PCClashVergeIntentStep $script:plan|Should -BeNullOrEmpty
            $script:plan.key='clash-verge';$script:service.path='C:\Fixture\clash-verge-service.exe'
            Get-PCClashVergeIntentStep $script:plan|Should -BeNullOrEmpty
        }
    }
    It 'does nothing when normal shutdown already cleared run intent' {
        InModuleScope ProxyClean.Common {
            [IO.File]::WriteAllText($script:statePath,$script:original.Replace(':true,',':false,'))
            Get-PCClashVergeIntentStep $script:plan|Should -BeNullOrEmpty
        }
    }
    It 'rejects an unknown field type without writing' {
        InModuleScope ProxyClean.Common {
            [IO.File]::WriteAllText($script:statePath,$script:original.Replace(':true,',':"true",'))
            {Get-PCClashVergeIntentStep $script:plan}|Should -Throw '*STATE_UNSUPPORTED*'
        }
    }
    It 'refuses a running or stop-pending service' -ForEach @(@{State='Running'},@{State='Stop Pending'}) {
        InModuleScope ProxyClean.Common -Parameters @{State=$State} {
            param($State)
            $script:fixtureState=$State
            Mock Get-CimInstance {[pscustomobject]@{Name=$script:service.name;PathName=$script:service.path;State=$script:fixtureState}}
            $step=Get-PCClashVergeIntentStep $script:plan
            {Set-PCResourceValue $step $step.after}|Should -Throw '*identity changed*'
        }
    }
    It 'preserves changes made since inspection' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            [IO.File]::WriteAllText($script:statePath,$script:original.Replace('23','24'))
            {Set-PCResourceValue $step $step.after}|Should -Throw '*Configuration changed*'
            ([IO.File]::ReadAllText($script:statePath)|ConvertFrom-Json).generation|Should -Be 24
        }
    }
    It 'rejects an owner change immediately before writing' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            [IO.File]::WriteAllText($script:ownerPath,'{}')
            {Set-PCResourceValue $step $step.after}|Should -Throw '*OWNER_CHANGED*'
        }
    }
    It 'persists an encrypted preimage and restores it on failed operation recovery' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            $p=[pscustomobject]@{schema='proxyclean.plan.v1';id='intent-fixture';sid=$script:plan.sid;steps=@($step)}
            (Invoke-PCRepairPlan $p -Confirm:$false).status|Should -Be applied
            [IO.File]::ReadAllText($script:journalPath)|Should -Not -Match 'core_should_be_running|Fixture'
            (Restore-PCJournal (Get-PCJournal)).status|Should -Be recovered
            [IO.File]::ReadAllText($script:statePath)|Should -Be $script:original
        }
    }
    It 'does not rearm a successfully committed client close during undo' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            $p=[pscustomobject]@{schema='proxyclean.plan.v1';id='intent-fixture';sid=$script:plan.sid;steps=@($step)}
            [void](Invoke-PCRepairPlan $p -Confirm:$false)
            $j=Get-PCJournal;$j.steps[0].phase='committed';Save-PCJournal $j
            (Get-PCUndoSummary).available|Should -BeFalse
            [void](Invoke-PCUndo -Confirm:$false)
            ([IO.File]::ReadAllText($script:statePath)|ConvertFrom-Json).core_should_be_running|Should -BeFalse
        }
    }
}
Describe 'Broker restart verification is bounded and precedes cleanup' {
    It 'detects a core appearing only after the first observation' {
        InModuleScope ProxyClean.Common {
            $script:observations=0
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCClientInventory {$script:observations++;if($script:observations -gt 1){[pscustomobject]@{key='clash-verge'}}}
            {Assert-PCClientStayedClosed ([pscustomobject]@{key='clash-verge';ports=@()}) -Milliseconds 500}|Should -Throw '*CLIENT_RESTARTED*'
        }
    }
    It 'does not confuse another running client with the client being closed' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCClientInventory {[pscustomobject]@{key='flyingbird'}}
            {Assert-PCClientStayedClosed ([pscustomobject]@{key='clash-verge';ports=@(12345)}) -Milliseconds 0}|Should -Not -Throw
        }
    }
    It 'recognizes the supported alpha core as part of Verge' {
        (Get-PCClientFamily 'verge-mihomo-alpha.exe').key|Should -Be 'clash-verge'
        {Assert-PCExpectedClient ([pscustomobject]@{processes=@([pscustomobject]@{name='verge-mihomo-alpha'})}) -ExpectedClient ClashVerge}|Should -Not -Throw
    }
    It 'allows a known replacement client to take over the old port without clearing it' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCLocalPortListeners {[pscustomobject]@{OwningProcess=891001;LocalPort=12345}}
            Mock Get-PCClientInventory {[pscustomobject]@{key='flyingbird';members=@([pscustomobject]@{ProcessId=891001})}}
            $p=[pscustomobject]@{key='clash-verge';ports=@(12345)}
            {Assert-PCClientStayedClosed $p -Milliseconds 0}|Should -Not -Throw
            $state=Get-PCClientPortState $p -Inventory @(Get-PCClientInventory)
            $state.closed.Count|Should -Be 0
            $state.reassigned|Should -Contain 12345
        }
    }
}
Describe 'Encrypted journal survives interrupted updates' {
    BeforeEach {
        InModuleScope ProxyClean.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:slotPath=Join-Path $Root ([Guid]::NewGuid().ToString('N')+'.dpapi')
            Mock Get-PCJournalPath {$script:slotPath}
            $script:record=[pscustomobject]@{schema='proxyclean.undo.v1';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;id='fixture';phase='applying';steps=@();remaining=@()}
        }
    }
    It 'reads the latest flushed slot and retains the previous valid generation' {
        InModuleScope ProxyClean.Common {
            Save-PCJournal $script:record
            $script:record.phase='completed';Save-PCJournal $script:record
            (Get-PCJournal).phase|Should -Be completed
            (Get-PCJournalSlots).Count|Should -Be 2
            [IO.File]::ReadAllText($script:slotPath)|Should -Not -Match 'fixture|applying'
        }
    }
    It 'recovers from a truncated newest slot without discarding the earlier pending operation' {
        InModuleScope ProxyClean.Common {
            Save-PCJournal $script:record
            $script:record.phase='completed';Save-PCJournal $script:record
            [IO.File]::WriteAllText($script:slotPath+'.previous','partial encrypted write')
            (Get-PCJournal).phase|Should -Be applying
            Save-PCJournal $script:record
            (Get-PCJournal).phase|Should -Be completed
        }
    }
    It 'does not mistake two unreadable slots for an absent journal' {
        InModuleScope ProxyClean.Common {
            [IO.File]::WriteAllText($script:slotPath,'damaged')
            [IO.File]::WriteAllText($script:slotPath+'.previous','damaged')
            {Get-PCJournal}|Should -Throw '*unreadable*'
        }
    }
    It 'imports a legacy single-slot record before assigning storage generations' {
        InModuleScope ProxyClean.Common {
            $secure=ConvertTo-SecureString ($script:record|ConvertTo-Json -Compress) -AsPlainText -Force
            try{[IO.File]::WriteAllText($script:slotPath,(ConvertFrom-SecureString $secure))}finally{$secure.Dispose()}
            (Get-PCJournal).phase|Should -Be applying
            Save-PCJournal $script:record
            (Get-PCJournal).storage_generation|Should -Be 1
        }
    }
}
