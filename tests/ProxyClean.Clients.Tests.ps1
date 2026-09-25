#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    function New-ClientNode([int]$Id,[string]$Name,[int]$Parent=0,[int]$Session=(Get-Process -Id $PID).SessionId){
        [pscustomobject]@{ProcessId=$Id;Name=$Name+'.exe';ParentProcessId=$Parent;SessionId=$Session;ExecutablePath=('C:\Fixture\'+$Name+'.exe')}
    }
    function New-ClientSnapshot {
        $value=[pscustomobject][ordered]@{exists=$true;value='http=127.0.0.1:34561;https=127.0.0.1:34562;socks=remote.example.test:8443';kind='String'}
        [pscustomobject]@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;observedUtc=[DateTimeOffset]::UtcNow.ToString('O');isSystem=$false;sessionId=1
            availability=[pscustomobject]@{listeners='observed';adapters='observed';routes='observed';wininet='observed';environment='observed';git='observed';winhttp='not_inspected';docker='not_inspected'}
            systemProxy=[pscustomobject]@{enabled=$true;server=$value.value;pac='';values=[pscustomobject]@{ProxyEnable=[pscustomobject][ordered]@{exists=$true;value=1;kind='DWord'};ProxyServer=$value}}
            listeners=@();adapters=@();routes=@();environment=@();git=@();winhttp=$null;docker=$null}
    }
}
Describe 'Client selection is independent of a hard-coded port' {
    It 'recognizes <Name> as <Label>' -ForEach @(
        @{Name='FlyingBirdCore';Label='飞鸟'},@{Name='FlyingBirdHelperService';Label='飞鸟'},@{Name='clash-verge';Label='Clash Verge'},@{Name='verge-mihomo';Label='Clash Verge'},
        @{Name='mihomo';Label='Clash / Mihomo'},@{Name='clash';Label='Clash / Mihomo'},@{Name='sing-box';Label='sing-box'},@{Name='tag-mihomo';Label='TAG'}
    ) {(Get-PCClientFamily $Name).label|Should -Be $Label}
    It 'does not classify unrelated process names by a partial word' {
        Get-PCClientFamily 'my-clash-notes'|Should -BeNullOrEmpty
        Get-PCClientFamily 'powershell'|Should -BeNullOrEmpty
    }
    It 'groups the GUI, service and core into one FlyingBird choice' {
        $rows=@((New-ClientNode 10001 FlyingBird),(New-ClientNode 10002 FlyingBirdHelperService -Session 0),(New-ClientNode 10003 FlyingBirdCore -Parent 10002 -Session 0))
        $r=@(Get-PCClientInventory -Processes $rows)
        $r.Count|Should -Be 1;$r[0].label|Should -Be '飞鸟';$r[0].members.Count|Should -Be 3;$r[0].requires_admin|Should -BeTrue
    }
    It 'groups a generic core by its actual parent controller' {
        $rows=@((New-ClientNode 10001 clash-verge),(New-ClientNode 10002 mihomo -Parent 10001))
        $r=@(Get-PCClientInventory -Processes $rows)
        $r.Count|Should -Be 1;$r[0].label|Should -Be 'Clash Verge';$r[0].members.Count|Should -Be 2
    }
    It 'does not merge an unrelated standalone core into a running controller' {
        $rows=@((New-ClientNode 10001 clash-verge),(New-ClientNode 10002 mihomo))
        @(Get-PCClientInventory -Processes $rows).Count|Should -Be 2
    }
    It 'recognizes an arbitrary published port and deduplicates listener families' {
        $rows=@((New-ClientNode 10001 verge-mihomo))
        $listeners=@([pscustomobject]@{OwningProcess=10001;LocalAddress='127.0.0.1';LocalPort=41234},[pscustomobject]@{OwningProcess=10001;LocalAddress='::1';LocalPort=41234})
        $r=@(Get-PCClientInventory -Processes $rows -Listeners $listeners -Endpoints @(Get-ProxyEndpoints '127.0.0.1:41234'))
        $r[0].ports.Count|Should -Be 1;$r[0].ports[0]|Should -Be 41234;$r[0].published|Should -BeTrue
    }
    It 'keeps different clients separate and excludes another desktop session' {
        $session=(Get-Process -Id $PID).SessionId
        $rows=@((New-ClientNode 10001 FlyingBird),(New-ClientNode 10002 clash-verge),(New-ClientNode 10003 tag -Session ($session+100)))
        $r=@(Get-PCClientInventory -Processes $rows)
        $r.Count|Should -Be 2;@($r|ForEach-Object key)|Should -Not -Contain tag
    }
    It 'does not expose installation paths or command lines in the display model' {
        $r=@(Get-PCClientInventory -Processes @((New-ClientNode 10001 FlyingBird)))
        $text=ConvertTo-PCPublicClients $r|ConvertTo-Json -Depth 8
        $text|Should -Not -Match 'ExecutablePath|C:\\Fixture|members|CommandLine'
    }
}
Describe 'All selected client ports are one reversible settings operation' {
    BeforeEach {$s=New-ClientSnapshot}
    It 'removes both local mappings while preserving a remote mapping' {
        $p=Get-PCRepairPlan $s -Ports @(34561,34562)
        $p.steps.Count|Should -Be 1;$p.steps[0].name|Should -Be ProxyServer
        $p.steps[0].after.value|Should -Be 'socks=remote.example.test:8443'
        $p.steps[0].required_closed_ports.Count|Should -Be 2
    }
    It 'disables the proxy only when no mappings remain' {
        $s.systemProxy.server='http=127.0.0.1:34561;https=127.0.0.1:34562';$s.systemProxy.values.ProxyServer.value=$s.systemProxy.server
        $p=Get-PCRepairPlan $s -Ports @(34561,34562)
        $p.steps.Count|Should -Be 1;$p.steps[0].name|Should -Be ProxyEnable;$p.steps[0].after.value|Should -Be 0
    }
    It 'does not modify routes during client-scoped cleanup' {
        $p=Get-PCRepairPlan $s -Ports @(34561,34562)
        @($p.steps|Where-Object kind -eq 'Route').Count|Should -Be 0
    }
    It 'does not touch another local proxy' {
        $p=Get-PCRepairPlan $s -Ports @(45678)
        $p.steps.Count|Should -Be 0
    }
    It 'refuses cleanup if any selected port was occupied again' {
        $p=Get-PCRepairPlan $s -Ports @(34561,34562)
        InModuleScope ProxyClean.Common -Parameters @{Step=$p.steps[0]} {
            param($Step)
            Mock Get-PCRegistryValue {$Step.preview_server}
            Mock Get-NetTCPConnection {@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=34562})}
            {Assert-PCStepCondition $Step}|Should -Throw '*PC_PROXY_RESTARTED*'
        }
    }
}
Describe 'Normal close, forced close and partial results stay separate' {
    BeforeEach {
        $s=New-ClientSnapshot;$s.systemProxy.enabled=$false;$s.systemProxy.server=''
        InModuleScope ProxyClean.Common -Parameters @{Snapshot=$s} {
            param($Snapshot)
            $script:clientSnapshot=$Snapshot
            $script:clientPlan=[pscustomobject]@{schema='proxyclean.client-close.v1';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;key='clash-core';label='Clash / Mihomo';members=@([pscustomobject]@{pid=991231;name='clash';path='C:\Fixture\clash.exe';session=1;start_utc='fixture'});services=@();ports=@(34561,34562);observedUtc='fixture'}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='none';available=$false}}
            Mock Test-PCClientProcess {$false}
            Mock Request-PCClientWindowClose {}
            Mock Stop-PCClientService {}
            Mock Stop-Process {}
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCClientInventory {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCSnapshot {$script:clientSnapshot}
            Mock Test-PCConnectivity {[pscustomobject]@{status='http_reachable'}}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='applied';changed=1}}
            Mock Send-PCSettingsChanged {[pscustomobject]@{wininet_notified=$true}}
            Mock Get-CimInstance {@()}
        }
    }
    It 'does not force-kill in the normal-close path' {
        InModuleScope ProxyClean.Common {
            $r=Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false
            $r.status|Should -Be client_closed
            Should -Invoke Request-PCClientWindowClose -Times 1
            Should -Invoke Stop-Process -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 1 -ParameterFilter {$Plan.ports.Count -eq 2}
            Should -Invoke Test-PCConnectivity -Times 1
        }
    }
    It 'requires a separate force request before terminating an exact process' {
        InModuleScope ProxyClean.Common {
            $script:identityCalls=0
            Mock Test-PCClientProcess {$script:identityCalls++;$script:identityCalls -le 2}
            $r=Invoke-PCClientClose $script:clientPlan -Force -WaitSeconds 0 -Confirm:$false
            $r.status|Should -Be client_closed
            Should -Invoke Stop-Process -Times 1 -ParameterFilter {$Id -eq 991231 -and $Force}
        }
    }
    It 'keeps original port scope when normal closing leaves a GUI running' {
        InModuleScope ProxyClean.Common {
            Mock Test-PCClientProcess {$true}
            $r=Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false
            $r.status|Should -Be client_still_running;$r.previous_plan.ports.Count|Should -Be 2
            Should -Invoke Stop-Process -Times 0;Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'does not clear settings after an automatically restarted client appears' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCClientInventory {@([pscustomobject]@{key='clash-core'})}
            (Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_still_running
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'does not touch a new process which took over an old port' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCLocalPortListeners {@([pscustomobject]@{OwningProcess=991232})}
            (Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_still_running
            Should -Invoke Stop-Process -Times 0;Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'refuses a reused PID before any shutdown request' {
        InModuleScope ProxyClean.Common {
            Mock Test-PCClientProcess {throw 'Process identity changed.'}
            {Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false}|Should -Throw '*identity changed*'
            Should -Invoke Request-PCClientWindowClose -Times 0;Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'refuses to close clients before an unfinished recovery is handled' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='recovery_required';available=$true}}
            {Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false}|Should -Throw '*unfinished cleanup*'
            Should -Invoke Request-PCClientWindowClose -Times 0
        }
    }
    It 'honors WhatIf without closing programs or creating settings changes' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCClientClose $script:clientPlan -WhatIf).status|Should -Be preview
            Should -Invoke Request-PCClientWindowClose -Times 0;Should -Invoke Stop-PCClientService -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0;Should -Invoke Test-PCConnectivity -Times 0
        }
    }
    It 'does not label preserved PAC settings as successful direct access' {
        InModuleScope ProxyClean.Common {
            $script:clientSnapshot.systemProxy.pac='https://private.example.test/pac'
            $r=Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false
            $r.remaining|Should -Contain '自动代理脚本仍保留';$r.all_applications_direct|Should -Be not_proven
        }
    }
    It 'does not hide cleanup failure behind successful process shutdown' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='recovery_required'}}
            (Invoke-PCClientClose $script:clientPlan -WaitSeconds 0 -Confirm:$false).status|Should -Be client_settings_incomplete
            Should -Invoke Test-PCConnectivity -Times 0
        }
    }
}
Describe 'Home layout presents intents rather than a maintenance toolbox' {
    BeforeAll {
        [xml]$main=Get-Content (Join-Path $PSScriptRoot '..\ControlCenter.xaml') -Raw -Encoding UTF8
        [xml]$maintenance=Get-Content (Join-Path $PSScriptRoot '..\Maintenance.xaml') -Raw -Encoding UTF8
    }
    It 'does not contain any technical operation controls on the main page' {
        $main.OuterXml|Should -Not -Match 'PortInput|ClientCombo|WifiResetButton|IPv6EnableButton|ProcessExpander|AdvancedExpander|Recheck'
        $maintenance.OuterXml|Should -Match 'PortInput|WifiResetButton|IPv6EnableButton'
    }
    It 'has exactly one main action and one secondary disconnect action' {
        @($main.SelectNodes('//*[@*[local-name()="Name"]="Primary"]')).Count|Should -Be 1
        @($main.SelectNodes('//*[@*[local-name()="Name"]="DisconnectButton"]')).Count|Should -Be 1
    }
    It 'keeps one daily double-click entry at the project root' {
        $root=Split-Path $PSScriptRoot -Parent
        @(Get-ChildItem $root -File|Where-Object Extension -in '.bat','.vbs').Count|Should -Be 1
        Test-Path (Join-Path $root '00-打开 ProxyClean.vbs')|Should -BeTrue
    }
}

Describe 'Client previews preserve intent without executing shutdown' {
    BeforeEach {
        $s=New-ClientSnapshot
        InModuleScope ProxyClean.Common -Parameters @{Snapshot=$s} {
            param($Snapshot)
            $script:previewSnapshot=$Snapshot
            $script:previewGroup=[pscustomobject]@{key='clash-verge';label='Clash Verge';requires_admin=$false;published=$true;ports=@(34562);members=@([pscustomobject]@{ProcessId=991231;Name='clash-verge.exe';SessionId=1;CreationDate=[DateTime]'2026-01-01T00:00:00Z';ExecutablePath='C:\Fixture\clash-verge.exe'})}
            Mock Get-PCSnapshot {$script:previewSnapshot}
            Mock Get-PCClientInventory {@($script:previewGroup)}
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='none';available=$false}}
            Mock Test-PCAdministrator {$false}
            Mock Get-PCProcessIdentity {[pscustomobject]@{pid=991231;name='clash-verge';path='C:\Fixture\clash-verge.exe';session=1;start_utc='fixture'}}
            Mock Get-CimInstance {@()}
            Mock Stop-Process {}
            Mock Request-PCClientWindowClose {}
            Mock Invoke-PCRepairPlan {}
            Mock Invoke-PCNative {}
        }
    }
    It 'does not execute any effects while preparing a client preview' {
        InModuleScope ProxyClean.Common {
            $r=Get-PCClientClosePreview -ClientKey clash-verge
            $r.status|Should -Be client_preview;$r.plan.label|Should -Be 'Clash Verge'
            Should -Invoke Stop-Process -Times 0;Should -Invoke Request-PCClientWindowClose -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0;Should -Invoke Invoke-PCNative -Times 0
            ($r.public|ConvertTo-Json -Depth 10)|Should -Not -Match 'C:\\Fixture|start_utc|sid'
        }
    }
    It 'preserves old core ports when a normal exit already closed that core' {
        InModuleScope ProxyClean.Common {
            $prior=[pscustomobject]@{schema='proxyclean.client-close.v1';key='clash-verge';sid=$script:previewSnapshot.sid;ports=@(34561)}
            $r=Get-PCClientClosePreview -ClientKey clash-verge -PreviousPlan $prior
            $r.plan.ports.Count|Should -Be 2;$r.plan.ports|Should -Contain 34561;$r.plan.ports|Should -Contain 34562
        }
    }
    It 'rejects a continuation from another client' {
        InModuleScope ProxyClean.Common {
            $prior=[pscustomobject]@{schema='proxyclean.client-close.v1';key='flyingbird';sid=$script:previewSnapshot.sid;ports=@(34561)}
            {Get-PCClientClosePreview -ClientKey clash-verge -PreviousPlan $prior}|Should -Throw '*identity changed*'
        }
    }
    It 'asks for authorization before reading inaccessible process identities' {
        InModuleScope ProxyClean.Common {
            $script:previewGroup.requires_admin=$true
            (Get-PCClientClosePreview).status|Should -Be client_needs_admin
            Should -Invoke Get-PCProcessIdentity -Times 0
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
    It 'presents separate choices rather than silently closing multiple clients' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCClientInventory {@($script:previewGroup,[pscustomobject]@{key='flyingbird';label='飞鸟';requires_admin=$true;published=$false;ports=@(34563);members=@()})}
            $r=Get-PCClientClosePreview
            $r.status|Should -Be choose_client;$r.clients.Count|Should -Be 2
            Should -Invoke Get-PCProcessIdentity -Times 0
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'does not clear unknown proxy settings when no known client exists' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCClientInventory {@()}
            (Get-PCClientClosePreview).status|Should -Be no_client
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
    It 'stops only an exact verified service with a bounded native request' {
        InModuleScope ProxyClean.Common {
            Mock Get-CimInstance {@([pscustomobject]@{Name='fixture-proxy-service';State='Running';ProcessId=991231;PathName='C:\Fixture\helper.exe'})}
            Stop-PCClientService ([pscustomobject]@{name='fixture-proxy-service';pid=991231;path='C:\Fixture\helper.exe'})
            Should -Invoke Invoke-PCNative -Times 1 -ParameterFilter {$ArgumentList.Count -eq 2 -and $ArgumentList[0] -eq 'stop' -and $ArgumentList[1] -ceq 'fixture-proxy-service' -and $TimeoutSeconds -eq 10}
        }
    }
    It 'does not stop a service whose executable changed after confirmation' {
        InModuleScope ProxyClean.Common {
            Mock Get-CimInstance {@([pscustomobject]@{Name='fixture-proxy-service';State='Running';ProcessId=991231;PathName='C:\Other\helper.exe'})}
            {Stop-PCClientService ([pscustomobject]@{name='fixture-proxy-service';pid=991231;path='C:\Fixture\helper.exe'})}|Should -Throw '*identity changed*'
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
}

Describe 'Final client-close audit regressions' {
    It 'does not attach a core to a parent PID which was reused after its birth' {
        $parent=New-ClientNode 10001 clash-verge
        $child=New-ClientNode 10002 mihomo -Parent 10001
        $parent|Add-Member -NotePropertyName CreationDate -NotePropertyValue ([DateTime]'2026-01-02')
        $child|Add-Member -NotePropertyName CreationDate -NotePropertyValue ([DateTime]'2026-01-01')
        @(Get-PCClientInventory -Processes @($parent,$child)).Count|Should -Be 2
    }
    It 'does not repeat a stop request while the verified service is already stopping' {
        InModuleScope ProxyClean.Common {
            Mock Get-CimInstance {@([pscustomobject]@{Name='fixture-service';State='Stop Pending';ProcessId=991231;PathName='C:\Fixture\helper.exe'})}
            Mock Invoke-PCNative {}
            Stop-PCClientService ([pscustomobject]@{name='fixture-service';pid=991231;path='C:\Fixture\helper.exe'})
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
}

Describe 'Root launcher survives a fresh Git checkout' {
    It 'keeps UTF-16 launcher bytes outside Git text newline conversion' {
        $root=Split-Path $PSScriptRoot -Parent
        $attrs=Get-Content (Join-Path $root '.gitattributes') -Raw -Encoding UTF8
        $attrs|Should -Match '(?m)^\*\.vbs\s+-text\s*$'
        $bytes=[IO.File]::ReadAllBytes((Join-Path $root '00-打开 ProxyClean.vbs'))
        $bytes[0]|Should -Be 255;$bytes[1]|Should -Be 254
        $text=[Text.Encoding]::Unicode.GetString($bytes).TrimStart([char]0xFEFF)
        $text.StartsWith("Option Explicit`r`nDim sh")|Should -BeTrue
    }
}
