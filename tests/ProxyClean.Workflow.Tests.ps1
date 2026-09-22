#Requires -Version 5.1
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    $script:root=Split-Path $PSScriptRoot -Parent
    function New-WorkflowSnapshot {
        $value=[pscustomobject][ordered]@{exists=$true;value='http://127.0.0.1:34567';kind='String'}
        [pscustomobject]@{
            sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            observedUtc=[DateTimeOffset]::UtcNow.ToString('O');isSystem=$false;sessionId=1
            availability=[pscustomobject]@{listeners='observed';adapters='observed';routes='observed';wininet='observed';environment='observed';git='observed';winhttp='not_inspected';docker='not_inspected'}
            systemProxy=[pscustomobject]@{enabled=$true;server=$value.value;pac='';values=[pscustomobject]@{ProxyEnable=[pscustomobject][ordered]@{exists=$true;value=1;kind='DWord'};ProxyServer=$value}}
            listeners=@();adapters=@();routes=@();environment=@();git=@();winhttp=$null;docker=$null
        }
    }
}
Describe 'Readable inspection decisions reflect actual evidence' {
    BeforeEach {
        $s=New-WorkflowSnapshot
        $plan=Get-PCRepairPlan -Snapshot $s
        $public=ConvertTo-PCPublicSnapshot $s
        $undo=[pscustomobject]@{available=$false;phase='none'}
    }
    It 'makes the actual repair the primary action, not an unexplained preview button' {
        $v=Get-PCCheckView -Snapshot $public -Plan $plan -Undo $undo
        $v.intent|Should -Be Repair
        $v.primary|Should -Be '修复这些设置'
        $v.actions|Should -Contain 'Windows 手动代理设置'
        $v.change_count|Should -Be 1
    }
    It 'keeps healthy inspection distinct from internet connectivity' {
        $plan.steps=@()
        $v=Get-PCCheckView $public $plan $undo
        $v.intent|Should -Be Connectivity
        $v.title|Should -Be '没有发现可清理的失效代理'
        $v.message|Should -Match '不代表'
    }
    It 'does not call unknown layers healthy' {
        $plan.steps=@();$public.availability.listeners='unknown'
        $v=Get-PCCheckView $public $plan $undo
        $v.title|Should -Be '部分检查未完成'
        $v.intent|Should -Be Inspect
    }
    It 'still discloses incomplete layers when some repairs are available' {
        $public.availability.routes='unknown'
        (Get-PCCheckView $public $plan $undo).message|Should -Match '部分检查未完成'
    }
    It 'prioritizes unfinished recovery over new repairs' {
        $undo=[pscustomobject]@{available=$true;phase='recovery_required'}
        $v=Get-PCCheckView $public $plan $undo
        $v.blocked|Should -BeTrue;$v.intent|Should -Be Undo
    }
    It 'blocks new effects when the encrypted restore record cannot be read' {
        $undo=[pscustomobject]@{available=$false;phase='unreadable'}
        $v=Get-PCCheckView $public $plan $undo
        $v.blocked|Should -BeTrue;$v.intent|Should -Be Inspect
        $v.title|Should -Match '无法读取'
    }
    It 'labels explicit direct mode as a requested change, not a fault' {
        $plan.mode='manual-user-direct'
        $v=Get-PCCheckView $public $plan $undo
        $v.title|Should -Match '将调整';$v.message|Should -Match '主动选择'
    }
    It 'requires elevation only when the plan actually contains routes' {
        (Get-PCCheckView $public $plan $undo).requires_admin|Should -BeFalse
        $plan.steps+=@(New-PCStep Route fixture $null $null fixture)
        (Get-PCCheckView $public $plan $undo).requires_admin|Should -BeTrue
    }
    It 'keeps conditions and original credentials out of public plans' {
        $s.systemProxy.server='http://fixture-user:fixture-secret@localhost:34567'
        $s.systemProxy.values.ProxyServer.value=$s.systemProxy.server
        $p=Get-PCRepairPlan $s
        $text=ConvertTo-PCPublicPlan $p|ConvertTo-Json -Depth 15
        $text|Should -Not -Match 'fixture-secret|fixture-user|preview_server|required_dead_values|before|after'
    }
    It 'renders a Chinese inspection rather than showing the raw snapshot' {
        $text=Format-PCInspection $public
        $text|Should -Match 'Windows 手动代理：已开启'
        $text|Should -Match '对应本机端口未运行'
        $text|Should -Not -Match '"schema"|"availability"|"context"'
    }
}
Describe 'Endpoint safety is revalidated immediately before effects' {
    BeforeEach {
        $s=New-WorkflowSnapshot;$plan=Get-PCRepairPlan $s
        InModuleScope ProxyClean.Common -Parameters @{FixturePlan=$plan} {
            param($FixturePlan)
            $script:wfPlan=$FixturePlan
            Mock Get-PCRegistryValue {$script:wfPlan.steps[0].preview_server}
            Mock Get-NetTCPConnection {@()}
        }
    }
    It 'permits the still-dead exact local endpoint' {
        InModuleScope ProxyClean.Common {{Assert-PCStepCondition $script:wfPlan.steps[0]}|Should -Not -Throw}
    }
    It 'refuses an endpoint that has restarted after preview' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetTCPConnection {@([pscustomobject]@{LocalPort=34567;LocalAddress='127.0.0.1'})}
            {Assert-PCStepCondition $script:wfPlan.steps[0]}|Should -Throw '*PC_PROXY_RESTARTED*'
        }
    }
    It 'refuses a listener lookup failure rather than interpreting it as dead' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetTCPConnection {throw 'fixture query failure'}
            {Assert-PCStepCondition $script:wfPlan.steps[0]}|Should -Throw '*PC_LISTENER_UNKNOWN*'
        }
    }
    It 'checks ProxyServer even when the modified field is only ProxyEnable' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCRegistryValue {[pscustomobject][ordered]@{exists=$true;value='http://127.0.0.1:45678';kind='String'}}
            {Assert-PCStepCondition $script:wfPlan.steps[0]}|Should -Throw '*PC_PROXY_SERVER_CHANGED*'
        }
    }
    It 'keeps an existing undo record when condition revalidation rejects the whole plan' {
        InModuleScope ProxyClean.Common {
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCJournal {[pscustomobject]@{phase='completed'}}
            Mock Save-PCJournal {}
            Mock Set-PCResourceValue {}
            Mock Get-NetTCPConnection {@([pscustomobject]@{LocalPort=34567;LocalAddress='127.0.0.1'})}
            $r=Invoke-PCRepairPlan $script:wfPlan -Confirm:$false
            $r.status|Should -Be plan_changed;$r.changed|Should -Be 0
            Should -Invoke Save-PCJournal -Times 0
            Should -Invoke Set-PCResourceValue -Times 0
        }
    }
    It 'preserves an IPv6 wildcard listener whose IPv4 acceptance is unknown' {
        InModuleScope ProxyClean.Common {
            Mock Get-NetTCPConnection {@([pscustomobject]@{LocalPort=34567;LocalAddress='::'})}
            {Assert-PCStepCondition $script:wfPlan.steps[0]}|Should -Throw '*PC_PROXY_RESTARTED*'
        }
    }
    It 'does not let an automatically restarted process lose its port references' {
        $portPlan=Get-PCRepairPlan $s -Port 34567
        InModuleScope ProxyClean.Common -Parameters @{Step=$portPlan.steps[0]} {
            param($Step)
            Mock Get-NetTCPConnection {@([pscustomobject]@{LocalPort=34567;LocalAddress='0.0.0.0'})}
            {Assert-PCStepCondition $Step}|Should -Throw '*PC_PROXY_RESTARTED*'
        }
    }
    It 'allows explicit direct selection without pretending a live proxy is dead' {
        $directPlan=Get-PCRepairPlan $s -Direct
        InModuleScope ProxyClean.Common -Parameters @{Step=$directPlan.steps[0]} {
            param($Step)
            Mock Get-NetTCPConnection {throw 'must not query for explicit direct intent'}
            {Assert-PCStepCondition $Step}|Should -Not -Throw
            Should -Invoke Get-NetTCPConnection -Times 0
        }
    }
}
Describe 'GUI and CLI share the same controlled workflow' {
    BeforeEach {
        $s=New-WorkflowSnapshot
        InModuleScope ProxyClean.Common -Parameters @{Snapshot=$s} {
            param($Snapshot)
            $script:wfSnapshot=$Snapshot
            Mock Get-PCSnapshot {Write-PCProgress $Progress 'fixture' '正在检查测试设置…';$script:wfSnapshot}
            Mock Get-PCUndoSummary {[pscustomobject]@{available=$false;phase='none'}}
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='applied';changed=1}}
            Mock Invoke-PCUndo {[pscustomobject]@{status='recovered'}}
            Mock Invoke-PCStopPlan {[pscustomobject]@{status='closed';settings=[pscustomobject]@{status='no_changes'}}}
            Mock Invoke-PCWifiReset {[pscustomobject]@{status='adapter_ready'}}
            Mock Invoke-PCIPv6Change {[pscustomobject]@{status='binding_verified'}}
            Mock Get-PCWifiAdapter {[pscustomobject]@{Name='Fixture Wi-Fi'}}
            Mock Test-PCConnectivity {[pscustomobject]@{status='http_not_confirmed'}}
            Mock Send-PCSettingsChanged {[pscustomobject]@{wininet_notified=$true}}
            Mock Invoke-PCNative {throw 'Unexpected DNS/network command'}
            Mock Save-PCJournal {}
        }
    }
    It 'inspection never mutates, probes the Internet or writes an undo journal' {
        InModuleScope ProxyClean.Common {
            $r=Invoke-PCWorkflow Inspect
            $r.status|Should -Be inspected;$r.view.primary|Should -Be '修复这些设置'
            Should -Invoke Invoke-PCRepairPlan -Times 0
            Should -Invoke Save-PCJournal -Times 0
            Should -Invoke Test-PCConnectivity -Times 0
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
    It 'does not overwrite unreadable undo records with a new repair recommendation' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCUndoSummary {throw 'fixture encrypted record unreadable'}
            $r=Invoke-PCWorkflow Inspect
            $r.undo.phase|Should -Be unreadable;$r.view.blocked|Should -BeTrue
        }
    }
    It 'emits Chinese stage callbacks and keeps default GUI connectivity opt-in' {
        InModuleScope ProxyClean.Common {
            $messages=[Collections.Generic.List[string]]::new()
            $callback={param($Stage,$Message)$messages.Add($Message)}.GetNewClosure()
            $r=Invoke-PCWorkflow Repair -Plan (Get-PCRepairPlan $script:wfSnapshot) -Progress $callback -SkipConnectivityChecks -Confirm:$false
            $r.status|Should -Be applied;$r.connectivity.status|Should -Be not_tested
            @($messages)|Should -Contain '设置已核验，正在通知 Windows 使用新设置…'
            Should -Invoke Test-PCConnectivity -Times 0
            Should -Invoke Invoke-PCNative -Times 0
            $r.dns_cache|Should -Be not_changed
        }
    }
    It 'does not change the repair result when a requested HTTP test fails' {
        InModuleScope ProxyClean.Common {
            $r=Invoke-PCWorkflow Repair -Plan (Get-PCRepairPlan $script:wfSnapshot) -Confirm:$false
            $r.status|Should -Be applied;$r.connectivity.status|Should -Be http_not_confirmed
            Should -Invoke Test-PCConnectivity -Times 1
        }
    }
    It 'reports notification failure separately from verified configuration writes' {
        InModuleScope ProxyClean.Common {
            Mock Send-PCSettingsChanged {throw 'notification fixture'}
            $r=Invoke-PCWorkflow Repair -Plan (Get-PCRepairPlan $script:wfSnapshot) -SkipConnectivityChecks -Confirm:$false
            $r.status|Should -Be applied;$r.notification.wininet_notified|Should -BeFalse
        }
    }
    It 'has no notification, DNS or Internet effect when no changes are needed' {
        InModuleScope ProxyClean.Common {
            Mock Invoke-PCRepairPlan {[pscustomobject]@{status='no_changes';changed=0}}
            $r=Invoke-PCWorkflow Repair -Plan (Get-PCRepairPlan $script:wfSnapshot) -SkipConnectivityChecks -Confirm:$false
            $r.status|Should -Be no_changes
            Should -Invoke Send-PCSettingsChanged -Times 0
            Should -Invoke Invoke-PCNative -Times 0
            Should -Invoke Test-PCConnectivity -Times 0
        }
    }
    It 'honors WhatIf for the shared <Action> workflow' -ForEach @(
        @{Action='Repair'},@{Action='Undo'},@{Action='Stop'},@{Action='WifiSoft'},@{Action='WifiReset'},@{Action='IPv6Enable'},@{Action='IPv6Disable'},@{Action='FlushDns'}
    ) {
        InModuleScope ProxyClean.Common -Parameters @{Action=$Action} {
            param($Action)
            (Invoke-PCWorkflow $Action -WhatIf).status|Should -Be preview
            Should -Invoke Invoke-PCRepairPlan -Times 0
            Should -Invoke Invoke-PCUndo -Times 0
            Should -Invoke Invoke-PCStopPlan -Times 0
            Should -Invoke Invoke-PCWifiReset -Times 0
            Should -Invoke Invoke-PCIPv6Change -Times 0
            Should -Invoke Invoke-PCNative -Times 0
        }
    }
    It 'returns a safe Chinese failure without copying arbitrary private exception text' {
        InModuleScope ProxyClean.Common {
            Mock Get-PCSnapshot {throw 'fixture-secret http://private.example.test/?key=private-value'}
            $r=Invoke-PCWorkflow Inspect
            $r.status|Should -Be failed;$r.message|Should -Match '操作没有完成'
            ($r|ConvertTo-Json)|Should -Not -Match 'fixture-secret|private.example|private-value'
        }
    }
    It 'cooperatively cancels inspection without starting effects' {
        InModuleScope ProxyClean.Common {
            $r=Invoke-PCWorkflow Inspect -Progress {throw 'PC_CANCELLED'}
            $r.status|Should -Be cancelled
            Should -Invoke Invoke-PCRepairPlan -Times 0
        }
    }
}
Describe 'Double-click entries cannot silently execute network changes' {
    It 'routes legacy <Action> into a non-elevated preview-first GUI' -ForEach @(
        @{Action='Control'},@{Action='Clean'},@{Action='Direct'},@{Action='Status'},@{Action='StopPort'},@{Action='WifiSoft'},@{Action='WifiReset'},@{Action='IPv6Toggle'},@{Action='IPv6Status'}
    ) {
        $r=(& (Join-Path $script:root 'Launch-ProxyClean.ps1') -Action $Action -PreviewLaunch)|ConvertFrom-Json
        $r.elevate|Should -BeFalse;$r.side_effects|Should -BeFalse;$r.preview_first|Should -BeTrue
        $r.arguments|Should -Contain (Join-Path $script:root 'ControlCenter.ps1')
        $r.arguments|Should -Contain '-STA'
        $r.arguments|Should -Not -Contain '-NoExit'
    }
    It 'preserves exact port/client and same-user constraints across the launcher' {
        $r=(& (Join-Path $script:root 'Launch-ProxyClean.ps1') -Action StopPort -Port 34567 -ExpectedClient ClashVerge -ExpectedSid 'fixture-sid' -PreviewLaunch)|ConvertFrom-Json
        $r.arguments|Should -Contain '34567';$r.arguments|Should -Contain 'ClashVerge';$r.arguments|Should -Contain 'fixture-sid'
        $r.argument_line|Should -Match '"[^\"]*ControlCenter.ps1"'
    }
    It 'does not trust a legacy port when a different client has claimed it' {
        $plan=[pscustomobject]@{processes=@([pscustomobject]@{name='fixture-unrelated'})}
        {Assert-PCExpectedClient $plan ClashVerge}|Should -Throw '*PC_LEGACY_CLIENT_CHANGED*'
        {Assert-PCExpectedClient $plan Any}|Should -Not -Throw
    }
    It 'recognizes the intended legacy process without adding other process names' {
        $plan=[pscustomobject]@{processes=@([pscustomobject]@{name='verge-mihomo'})}
        {Assert-PCExpectedClient $plan ClashVerge}|Should -Not -Throw
        {Assert-PCExpectedClient $plan FlyingBird}|Should -Throw '*PC_LEGACY_CLIENT_CHANGED*'
    }
}
Describe 'Final audit regression cases' {
    It 'does not label an explicitly selected active tunnel route as dead' {
        $step=New-PCStep Route fixture $null $null fixture
        $step|Add-Member -NotePropertyName allow_active_fake -NotePropertyValue $true
        (Get-PCStepLabel $step)|Should -Be '代理隧道的默认网络路由（将移除）'
        (Get-PCStepLabel $step)|Should -Not -Match '已失效'
    }
    It 'preserves the previous undo record when a user variable changed after preview' {
        InModuleScope ProxyClean.Common {
            $before=[pscustomobject][ordered]@{exists=$true;value='http://localhost:34567';kind='String'}
            $after=[pscustomobject][ordered]@{exists=$false;value=$null;kind=$null}
            $plan=[pscustomobject]@{schema='proxyclean.plan.v1';id='fixture';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;steps=@(New-PCStep UserEnv HTTP_PROXY $before $after fixture)}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCJournal {[pscustomobject]@{phase='completed'}}
            Mock Get-PCResourceValue {[pscustomobject][ordered]@{exists=$true;value='http://changed.example.test:8443';kind='String'}}
            Mock Save-PCJournal {}
            Mock Set-PCResourceValue {}
            (Invoke-PCRepairPlan $plan -Confirm:$false).status|Should -Be plan_changed
            Should -Invoke Save-PCJournal -Times 0
            Should -Invoke Set-PCResourceValue -Times 0
        }
    }
    It 'repeats the condition check after journaling and before the first effect' {
        $s=New-WorkflowSnapshot;$plan=Get-PCRepairPlan $s
        InModuleScope ProxyClean.Common -Parameters @{Plan=$plan} {
            param($Plan)
            $script:latePlan=$Plan;$script:conditionCalls=0
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Get-PCJournal {$null}
            Mock Get-PCResourceValue {$script:latePlan.steps[0].before}
            Mock Save-PCJournal {}
            Mock Set-PCResourceValue {}
            Mock Assert-PCStepCondition {$script:conditionCalls++;if($script:conditionCalls -gt 1){throw 'PC_PROXY_RESTARTED'}}
            $r=Invoke-PCRepairPlan $Plan -Confirm:$false
            $r.status|Should -Be failed_rolled_back
            Should -Invoke Assert-PCStepCondition -Times 2
            Should -Invoke Set-PCResourceValue -Times 0
        }
    }
}
