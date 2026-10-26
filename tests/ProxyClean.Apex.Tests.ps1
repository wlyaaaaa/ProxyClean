#Requires -Version 5.1
# Fake process tables only; every lifecycle effect is mocked.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    $script:apexHash='a'*64
    $script:apexGui='C:\Program Files (x86)\飞鸟-极速版\Apex.exe'
    $script:apexBroker='C:\ProgramData\uanetfbclientappapexHelperService\helper-service.exe'
    $script:apexCore='C:\ProgramData\ApexHelperCoreCache-v1\fixture\'+$script:apexHash+'.exe'
    $script:apexSidecar='E:\Data\PCConfig\FlyingBirdAutostart\sidecar\fb-ai-entry.exe'
    function New-ApexNode([int]$Id,[string]$Name,[string]$Path,[int]$Parent=0,[int]$Session=(Get-Process -Id $PID).SessionId) {
        [pscustomobject]@{ProcessId=$Id;Name=$Name+'.exe';ExecutablePath=$Path;ParentProcessId=$Parent;SessionId=$Session;CreationDate=[DateTime]'2026-01-01T00:00:00Z'}
    }
    function New-ApexRows {
        @((New-ApexNode 887001 Apex $script:apexGui),
          (New-ApexNode 887002 helper-service $script:apexBroker -Session 0),
          (New-ApexNode 887003 $script:apexHash $script:apexCore -Parent 887002 -Session 0),
          (New-ApexNode 887004 fb-ai-entry $script:apexSidecar))
    }
}
Describe 'Apex FlyingBird identity requires the installed executable path' {
    It 'classifies the GUI, launch broker, cached core and sidecar with explicit roles' {
        $rows=New-ApexRows;$roles=@('controller','broker','core','core')
        for($i=0;$i -lt $rows.Count;$i++) {
            Get-PCFlyingBirdRole -Name $rows[$i].Name -Path $rows[$i].ExecutablePath|Should -Be $roles[$i]
            (Get-PCClientFamily -Name $rows[$i].Name -Path $rows[$i].ExecutablePath).key|Should -Be flyingbird
        }
        Test-PCClientController -Name Apex -Path $script:apexGui|Should -BeTrue
        Test-PCClientBroker -Name helper-service -Path $script:apexBroker|Should -BeTrue
        Test-PCClientBroker -Name helper-service -Path 'C:\Other\helper-service.exe'|Should -BeFalse
    }
    It 'rejects lookalike names, directory prefixes, malformed hashes and nested cache paths' {
        $bad=@(
            @{Name='Apex';Path='C:\Other\Apex.exe'},
            @{Name='helper-service';Path='C:\ProgramData\uanetfbclientappapexHelperService-copy\helper-service.exe'},
            @{Name='fb-ai-entry';Path='E:\Data\PCConfig\FlyingBirdAutostart\sidecar-copy\fb-ai-entry.exe'},
            @{Name=$script:apexHash;Path=('C:\ProgramData\ApexHelperCoreCache-v1-copy\fixture\'+$script:apexHash+'.exe')},
            @{Name=$script:apexHash;Path=('C:\Other\'+$script:apexHash+'.exe')},
            @{Name=('b'*63);Path=('C:\ProgramData\ApexHelperCoreCache-v1\fixture\'+('b'*63)+'.exe')},
            @{Name=('g'*64);Path=('C:\ProgramData\ApexHelperCoreCache-v1\fixture\'+('g'*64)+'.exe')},
            @{Name=$script:apexHash;Path=('C:\ProgramData\ApexHelperCoreCache-v1\fixture\nested\'+$script:apexHash+'.exe')})
        foreach($entry in $bad) {
            Get-PCFlyingBirdRole @entry|Should -BeNullOrEmpty
            Get-PCClientFamily @entry|Should -BeNullOrEmpty
        }
        foreach($name in @('Apex','helper-service',$script:apexHash,'fb-ai-entry','my-Apex-notes')) {
            Get-PCClientFamily -Name $name|Should -BeNullOrEmpty
        }
    }
}
Describe 'Apex and its sidecar form one FlyingBird choice independently of parent lifetime' {
    It 'groups SYSTEM helper children and includes actual core ports without the helper control port' {
        $rows=New-ApexRows
        $listeners=@([pscustomobject]@{OwningProcess=887002;LocalAddress='127.0.0.1';LocalPort=47890},
                     [pscustomobject]@{OwningProcess=887003;LocalAddress='127.0.0.1';LocalPort=45671},
                     [pscustomobject]@{OwningProcess=887003;LocalAddress='::';LocalPort=1053},
                     [pscustomobject]@{OwningProcess=887004;LocalAddress='127.0.0.1';LocalPort=18900})
        $clients=@(Get-PCClientInventory -Processes $rows -Listeners $listeners)
        $clients|Should -HaveCount 1;$clients[0].key|Should -Be flyingbird;$clients[0].label|Should -Be '飞鸟'
        $clients[0].members|Should -HaveCount 4;$clients[0].requires_admin|Should -BeTrue
        $clients[0].ports|Should -HaveCount 3
        foreach($port in @(45671,1053,18900)){$clients[0].ports|Should -Contain $port}
        $clients[0].ports|Should -Not -Contain 47890
    }
    It 'recognizes an orphan cached hash core and its independent sidecar as the same family' {
        $rows=New-ApexRows;$rows[2].ParentProcessId=889999
        $clients=@(Get-PCClientInventory -Processes @($rows[2],$rows[3]))
        $clients|Should -HaveCount 1;$clients[0].key|Should -Be flyingbird
        $clients[0].members.ProcessId|Should -Contain 887003
        $clients[0].members.ProcessId|Should -Contain 887004
    }
    It 'keeps Apex, Clash and an independent Mihomo in their own choices even with a Clash ancestor' {
        $rows=New-ApexRows;$rows[3].ParentProcessId=887010
        $rows+=@((New-ApexNode 887010 clash-verge 'C:\Fixture\clash-verge.exe'),
                 (New-ApexNode 887011 mihomo 'C:\Fixture\mihomo.exe' -Parent 887010),
                 (New-ApexNode 887012 mihomo 'C:\Other\mihomo.exe'))
        $clients=@(Get-PCClientInventory -Processes $rows)
        $clients|Should -HaveCount 3
        $bird=@($clients|Where-Object key -eq flyingbird)[0];$bird.members|Should -HaveCount 4
        $clash=@($clients|Where-Object key -eq clash-verge)[0];$clash.members.ProcessId|Should -Contain 887011
        $clash.members.ProcessId|Should -Not -Contain 887004
        @($clients|Where-Object family_key -eq clash-core)[0].members.ProcessId|Should -Contain 887012
    }
    It 'does not accept an arbitrary hash child just because the real broker is its parent' {
        $rows=New-ApexRows;$rows[2].ExecutablePath='C:\Other\'+$script:apexHash+'.exe'
        @(Get-PCClientInventory -Processes @($rows[1],$rows[2]))|Should -HaveCount 0
    }
    It 'does not offer an idle Apex broker as an active proxy' {
        $rows=New-ApexRows
        @(Get-PCClientInventory -Processes @($rows[1]))|Should -HaveCount 0
    }
}
Describe 'Apex listener diagnostics expose the FlyingBird family without installation paths' {
    It 'labels a hash core and sidecar, excludes the broker, and caches repeated listener owners' {
        $rows=New-ApexRows
        InModuleScope ProxyClean.Common -Parameters @{Rows=$rows} {
            param($Rows)
            $script:apexDiagnosticRows=@{};foreach($p in $Rows){$script:apexDiagnosticRows[[int]$p.ProcessId]=$p}
            Mock Get-Process {param($Id) $p=$script:apexDiagnosticRows[[int]@($Id)[0]];[pscustomobject]@{ProcessName=($p.Name -replace '\.exe$','');Path=$p.ExecutablePath}}
            $listeners=@([pscustomobject]@{OwningProcess=887003;LocalAddress='127.0.0.1';LocalPort=45671},
                         [pscustomobject]@{OwningProcess=887003;LocalAddress='::';LocalPort=1053},
                         [pscustomobject]@{OwningProcess=887004;LocalAddress='127.0.0.1';LocalPort=18900},
                         [pscustomobject]@{OwningProcess=887002;LocalAddress='127.0.0.1';LocalPort=47890})
            $found=@(Get-PCListenerCandidates -Listeners $listeners)
            $found|Should -HaveCount 3
            foreach($candidate in $found){$candidate.client_label|Should -Be '飞鸟';$candidate.client_family|Should -Be flyingbird;$candidate.http_proxy_confirmed|Should -BeFalse}
            ($found|ConvertTo-Json -Depth 5)|Should -Not -Match 'ExecutablePath|ApexHelperCoreCache|FlyingBirdAutostart|ProgramData'
            Should -Invoke Get-Process -Times 1 -ParameterFilter {$Id -eq 887003}
            Mock Get-PCInterruptedStageNotice {}
            $snapshot=[pscustomobject]@{availability=[pscustomobject]@{};system_proxy=[pscustomobject]@{enabled=$false;pac_configured=$false};endpoints=@();listener_candidates=$found;tun_routes=@();conclusion=[pscustomobject]@{consumer_local_proxy_pin_present=$false};environment=@()}
            Format-PCInspection $snapshot|Should -Match '端口 18900：飞鸟'
        }
    }
}
Describe 'Opaque SYSTEM processes require a complete close preview before selection' {
    BeforeEach {
        $rows=New-ApexRows;$rows[2].ExecutablePath=$null
        InModuleScope ProxyClean.Common -Parameters @{Rows=$rows} {
            param($Rows)
            $script:opaqueApexRows=$Rows
            Mock Test-PCAdministrator {$false}
            Mock Get-CimInstance {$script:opaqueApexRows}
            Mock Get-PCSnapshot {[pscustomobject]@{systemProxy=$null;listeners=@()}}
            Mock Invoke-PCAdminCall {[pscustomobject]@{status='client_preview'}}
            Mock Get-PCProcessIdentity {throw 'Incomplete discovery must not authorize a process'}
        }
    }
    It 'uses hidden names only as a request to re-read with permission, never as identified members' {
        InModuleScope ProxyClean.Common {
            $clients=@(Get-PCClientInventory -Processes $script:opaqueApexRows)
            $clients[0].members.ProcessId|Should -Not -Contain 887003
            Should -Invoke Invoke-PCAdminCall -Times 0
            {Get-PCClientInventory -Processes $script:opaqueApexRows -RequireComplete}|Should -Throw '*PC_CLIENT_PATH_NEEDS_ADMIN*'
            (Get-PCClientClosePreview -ClientKey flyingbird -ExpectedClientInstance expected).status|Should -Be client_preview
            Should -Invoke Invoke-PCAdminCall -Times 1 -ParameterFilter {$Name -eq 'Get-PCClientClosePreview' -and $Parameters.ClientKey -eq 'flyingbird' -and $Parameters.ExpectedClientInstance -eq 'expected'}
            Should -Invoke Get-PCProcessIdentity -Times 0
        }
    }
    It 'fails an incomplete administrator read instead of repeatedly elevating or closing a partial group' {
        InModuleScope ProxyClean.Common {
            Mock Test-PCAdministrator {$true}
            {Get-PCClientClosePreview}|Should -Throw '*Process identity unavailable*'
            Should -Invoke Invoke-PCAdminCall -Times 0
            Should -Invoke Get-PCProcessIdentity -Times 0
        }
    }
}
Describe 'Apex close preserves its original launch broker and closes both cores' {
    BeforeEach {
        $rows=New-ApexRows
        InModuleScope ProxyClean.Common -Parameters @{Rows=$rows} {
            param($Rows)
            $script:apexEvents=New-Object 'Collections.Generic.List[string]';$script:apexState='Running'
            $script:apexAlive=@{};foreach($p in $Rows){$script:apexAlive[[int]$p.ProcessId]=$true}
            $script:apexService=[pscustomobject]@{name='uanetfbclientappapexHelperService';pid=887002;path=$Rows[1].ExecutablePath}
            $members=@($Rows|ForEach-Object {[pscustomobject]@{pid=$_.ProcessId;name=($_.Name -replace '\.exe$','');path=$_.ExecutablePath;session=$_.SessionId;start_utc='fixture'}})
            $script:apexPlan=[pscustomobject]@{schema='proxyclean.client-close.v1';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;key='flyingbird';family_key='flyingbird';label='飞鸟';ports=@(45671,18900);services=@($script:apexService);members=$members}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCUndoSummary {[pscustomobject]@{phase='none'}}
            Mock Test-PCClientProcess {param($Identity) $script:apexAlive[[int]$Identity.pid]}
            Mock Request-PCClientWindowClose {}
            Mock Wait-PCClientExit {param($Plan) @($Plan.members|Where-Object {$script:apexAlive[[int]$_.pid]})}
            Mock Stop-PCClientProcess {param($Identity) if($script:apexAlive[[int]$Identity.pid]){$script:apexEvents.Add('process-'+$Identity.pid);$script:apexAlive[[int]$Identity.pid]=$false}}
            Mock Get-CimInstance {[pscustomobject]@{Name=$script:apexService.name;ProcessId=887002;PathName=$script:apexService.path;State=$script:apexState}}
            Mock Stop-PCClientService {$script:apexEvents.Add('service-stop');$script:apexState='Stopped';$script:apexAlive[887002]=$false}
            Mock Restore-PCClientService {$script:apexEvents.Add('service-restore');$script:apexState='Running'}
            Mock Clear-PCClientRunIntent {}
            Mock Assert-PCClientStayedClosed {}
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCClientInventory {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-PCSnapshot {[pscustomobject]@{fixture=$true}}
            Mock Get-PCRepairPlan {[pscustomobject]@{steps=@();ports=@(45671,18900)}}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='no_changes';changed=0}}
            Mock ConvertTo-PCPublicSnapshot {[pscustomobject]@{availability=[pscustomobject]@{listeners='observed'};system_proxy=[pscustomobject]@{enabled=$false;pac_configured=$false};tun_routes=@();conclusion=[pscustomobject]@{consumer_local_proxy_pin_present=$false};environment=@();git_proxy=@();winhttp=[pscustomobject]@{mode='direct'}}}
            Mock Stop-Process {throw 'Unexpected process effect'}
            Mock Start-Service {throw 'Unexpected service effect'}
            Mock Set-Service {throw 'Unexpected service configuration effect'}
            Mock Invoke-PCNative {throw 'Unexpected native effect'}
            Mock Test-PCConnectivity {throw 'Unexpected network effect'}
        }
    }
    It 'stops the Apex GUI before its broker and both cores before broker recovery' {
        InModuleScope ProxyClean.Common {
            (Invoke-PCClientClose $script:apexPlan -WaitSeconds 0 -SkipConnectivityChecks -Confirm:$false).status|Should -Be client_closed
            $script:apexEvents[0]|Should -Be process-887001
            $script:apexEvents[1]|Should -Be service-stop
            $script:apexEvents|Should -Contain process-887003;$script:apexEvents|Should -Contain process-887004
            $script:apexEvents[$script:apexEvents.Count-1]|Should -Be service-restore
            Should -Invoke Restore-PCClientService -Times 1
        }
    }
    It 'does not restore an Apex helper which was already stopped' {
        InModuleScope ProxyClean.Common {
            $script:apexState='Stopped';$script:apexAlive[887002]=$false
            (Invoke-PCClientClose $script:apexPlan -WaitSeconds 0 -SkipConnectivityChecks -Confirm:$false).status|Should -Be client_closed
            Should -Invoke Restore-PCClientService -Times 0
        }
    }
}
