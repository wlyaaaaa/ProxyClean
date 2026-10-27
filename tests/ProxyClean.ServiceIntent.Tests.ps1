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
            $script:journalPath=Join-Path $script:fixtureRoot 'journal.json'
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
    It 'clears persisted intent for an absent core from the same service bin' {
        InModuleScope ProxyClean.Common {
            $core=Join-Path $script:fixtureRoot 'bin\verge-mihomo-alpha.exe';$script:plan.members=@()
            [IO.File]::WriteAllText($script:statePath,$script:original.Replace('C:\\Fixture\\verge-mihomo.exe',$core.Replace('\','\\')))
            $step=Get-PCClashVergeIntentStep $script:plan;Set-PCResourceValue $step $step.after
            ([IO.File]::ReadAllText($script:statePath)|ConvertFrom-Json).core_should_be_running|Should -BeFalse
        }
    }
    It 'does not infer an absent core belongs to another installation' {
        InModuleScope ProxyClean.Common {$script:plan.members=@();{Get-PCClashVergeIntentStep $script:plan}|Should -Throw '*OWNER_CHANGED*'}
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
    It 'persists a JSON preimage and restores it on failed operation recovery' {
        InModuleScope ProxyClean.Common {
            $step=Get-PCClashVergeIntentStep $script:plan
            $p=[pscustomobject]@{schema='proxyclean.plan.v1';id='intent-fixture';sid=$script:plan.sid;steps=@($step)}
            (Invoke-PCRepairPlan $p -Confirm:$false).status|Should -Be applied
            ((Read-PCJournalSlot $script:journalPath).steps[0].before)|Should -Be $script:original
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
    It 'uses ten seconds by default and detects a core appearing after six seconds of observations' {
        InModuleScope ProxyClean.Common {
            $parameter=(Get-Command Assert-PCClientStayedClosed).ScriptBlock.Ast.Find({param($n)$n -is [Management.Automation.Language.ParameterAst] -and $n.Name.VariablePath.UserPath -eq 'Milliseconds'},$true)
            $parameter.DefaultValue.Value|Should -Be 10000
            $script:elapsed=0
            Mock Start-Sleep {param($Milliseconds)$script:elapsed+=$Milliseconds}
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCClientInventory {if($script:elapsed -ge 6000){[pscustomobject]@{key='clash-verge'}}}
            {Assert-PCClientStayedClosed ([pscustomobject]@{key='clash-verge';ports=@()})}|Should -Throw '*CLIENT_RESTARTED*'
            $script:elapsed|Should -Be 6000
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
Describe 'JSON journal survives interrupted updates' {
    BeforeEach {
        InModuleScope ProxyClean.Common -Parameters @{Root=$TestDrive} {
            param($Root)
            $script:slotPath=Join-Path $Root ([Guid]::NewGuid().ToString('N')+'.json')
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
            ([IO.File]::ReadAllText($script:slotPath)|ConvertFrom-Json).phase|Should -Be applying
        }
    }
    It 'recovers from a truncated newest slot without discarding the earlier pending operation' {
        InModuleScope ProxyClean.Common {
            Save-PCJournal $script:record
            $script:record.phase='completed';Save-PCJournal $script:record
            [IO.File]::WriteAllText($script:slotPath+'.previous','partial JSON write')
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
    It 'migrates a legacy slot only when saving and preserves both JSON generations' -ForEach @(@{Suffix=''},@{Suffix='.previous'}) {
        InModuleScope ProxyClean.Common -Parameters @{Suffix=$Suffix} {
            param($Suffix)
            $legacy=[IO.Path]::ChangeExtension($script:slotPath,'.dpapi')+$Suffix
            $script:record|Add-Member -NotePropertyName original -NotePropertyValue 'http://fixture-user:fixture-secret@proxy.example.test:8443'
            $secure=ConvertTo-SecureString ($script:record|ConvertTo-Json -Compress) -AsPlainText -Force
            try{[IO.File]::WriteAllText($legacy,(ConvertFrom-SecureString $secure))}finally{$secure.Dispose()}
            (Get-PCJournal).phase|Should -Be applying
            Test-Path -LiteralPath $script:slotPath|Should -BeFalse
            Save-PCJournal $script:record
            (Get-PCJournal).storage_generation|Should -Be 1
            (Get-PCJournalSlots).Count|Should -Be 2
            foreach($slot in @($script:slotPath,($script:slotPath+'.previous'))){
                ([IO.File]::ReadAllText($slot)|ConvertFrom-Json).original|Should -Be $script:record.original
            }
            Test-Path -LiteralPath $legacy|Should -BeFalse
        }
    }
    It 'keeps legacy recovery readable if migration is interrupted before the second JSON slot' {
        InModuleScope ProxyClean.Common {
            $legacy=[IO.Path]::ChangeExtension($script:slotPath,'.dpapi')
            $secure=ConvertTo-SecureString ($script:record|ConvertTo-Json -Compress) -AsPlainText -Force
            try{[IO.File]::WriteAllText($legacy,(ConvertFrom-SecureString $secure))}finally{$secure.Dispose()}
            $script:writeJournalSlot=(Get-Command Write-PCJournalSlot).ScriptBlock
            Mock Write-PCJournalSlot {
                param($Path,$Journal)
                if($Path -eq $script:slotPath+'.previous'){throw 'Injected interrupted migration'}
                & $script:writeJournalSlot -Path $Path -Journal $Journal
            }
            {Save-PCJournal $script:record}|Should -Throw '*interrupted migration*'
            (Get-PCJournal).phase|Should -Be applying
            Test-Path -LiteralPath $legacy|Should -BeTrue
            ([IO.File]::ReadAllText($script:slotPath)|ConvertFrom-Json).phase|Should -Be applying
        }
    }
    It 'blocks a new operation when the newest legacy generation is unfinished, even with a torn JSON slot' {
        InModuleScope ProxyClean.Common {
            $legacy=[IO.Path]::ChangeExtension($script:slotPath,'.dpapi')
            foreach($item in @(@{Suffix='';Generation=8;Phase='completed'},@{Suffix='.previous';Generation=9;Phase='applying'})){
                $script:record.phase=$item.Phase
                $script:record|Add-Member -NotePropertyName storage_generation -NotePropertyValue $item.Generation -Force
                $secure=ConvertTo-SecureString ($script:record|ConvertTo-Json -Compress) -AsPlainText -Force
                try{[IO.File]::WriteAllText(($legacy+$item.Suffix),(ConvertFrom-SecureString $secure))}finally{$secure.Dispose()}
            }
            [IO.File]::WriteAllText($script:slotPath,'partial JSON write')
            (Get-PCJournal).storage_generation|Should -Be 9
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Set-PCResourceValue {throw 'Unexpected effect'}
            $p=[pscustomobject]@{schema='proxyclean.plan.v1';sid=$script:record.sid;steps=@((New-PCStep UserEnv HTTP_PROXY $null $null 'fixture'))}
            {Invoke-PCRepairPlan $p -Confirm:$false}|Should -Throw '*unfinished*'
            Should -Invoke Set-PCResourceValue -Times 0
            [IO.File]::ReadAllText($script:slotPath)|Should -Be 'partial JSON write'
        }
    }
    It 'preserves UTF-8 originals and date-shaped strings, and rejects another user record' {
        InModuleScope ProxyClean.Common {
            $original='合成记录：2026-10-28T02:02:00+08:00'
            $script:record|Add-Member -NotePropertyName original -NotePropertyValue $original
            $script:record|Add-Member -NotePropertyName timestamp -NotePropertyValue '2026-10-28T02:02:00+08:00'
            Save-PCJournal $script:record
            (Get-PCJournal).original|Should -Be $original
            (Get-PCJournal).timestamp|Should -Be '2026-10-28T02:02:00+08:00'
            $script:record.sid='S-1-5-21-100-200-300-999'
            [IO.File]::WriteAllText($script:slotPath,($script:record|ConvertTo-Json -Compress))
            {Read-PCJournalSlot $script:slotPath}|Should -Throw '*does not belong*'
        }
    }
}
