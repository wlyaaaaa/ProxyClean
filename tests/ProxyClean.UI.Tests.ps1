#Requires -Version 5.1
BeforeAll {
    $script:root=Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:root 'ProxyClean.Common.psm1') -Force
    # Exercise real handlers without constructing a desktop or invoking effects.
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root 'ControlCenter.ps1'),[ref]$tokens,[ref]$errors)
    foreach($name in @('Get-PCElevationOptions','Invoke-PCPrimary','Invoke-PCAdapterAction','Invoke-PCDnsAction','Show-PCInitialAction')){
        $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$false)
        if(-not $function){throw ('Missing GUI handler: '+$name)}
        . ([scriptblock]::Create($function.Extent.Text))
    }
    function Open-PCMaintenance {}
    function Request-PCElevation {param([string]$Action='Control')throw 'Unexpected elevation'}
    function Confirm-PCAction {param([string]$Message,[string]$Title)throw 'Unexpected confirmation'}
    function Start-PCWork {param([string]$Action,[hashtable]$Options=@{})throw 'Unexpected effect'}
    function Set-PCScreen {param([string]$Title,[string]$Message,[string]$Primary='重新检查',[string]$Intent='Inspect',[string]$Tone='good',[object[]]$Actions=@())}
}
Describe 'Guided GUI handoff keeps user intent without executing it' {
    BeforeEach {
        $adapter=[pscustomobject]@{SelectedItem=[pscustomobject]@{name='Fixture Wi-Fi'};broughtIntoView=$false}
        $adapter|Add-Member -MemberType ScriptMethod -Name BringIntoView -Value {$this.broughtIntoView=$true}
        $details=[pscustomobject]@{IsExpanded=$false;broughtIntoView=$false}
        $details|Add-Member -MemberType ScriptMethod -Name BringIntoView -Value {$this.broughtIntoView=$true}
        $script:pc=@{admin=$false;legacyClient='ClashVerge';intent='Inspect';resumeAction=$null;pending=$null;direct=$false;
            ui=@{PortInput=[pscustomobject]@{Text='34567'};AdapterCombo=$adapter;DetailsExpander=$details;AdvancedExpander=[pscustomobject]@{IsExpanded=$false};UndoButton=[pscustomobject]@{Visibility='Collapsed'}};
            inspection=[pscustomobject]@{view=[pscustomobject]@{blocked=$false};undo=[pscustomobject]@{available=$true}}}
        $script:Port=34567
        Mock Request-PCElevation {}
        Mock Confirm-PCAction {$true}
        Mock Start-PCWork {}
        Mock Set-PCScreen {}
        Mock Get-PCUndoSummary {[pscustomobject]@{available=$true;resources=@('WinInet:ProxyEnable')}}
    }
    It 'preserves the selected action, port, client, adapter and Windows identity' {
        $options=Get-PCElevationOptions StopPort
        $options.Action|Should -Be Control
        $options.InitialAction|Should -Be StopPort
        $options.ExpectedClient|Should -Be ClashVerge
        $options.Port|Should -Be 34567
        $options.InterfaceAlias|Should -Be 'Fixture Wi-Fi'
        $options.ExpectedSid|Should -Be ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $options.Elevated|Should -BeTrue
        Should -Invoke Start-PCWork -Times 0
    }
    It 'does not forward malformed or overflowing port input into an unrelated action' {
        $script:pc.ui.PortInput.Text='999999999999999999999'
        (Get-PCElevationOptions IPv6Enable).ContainsKey('Port')|Should -BeFalse
    }
    It 'requests the exact adapter action <Action>, never a substituted reset' -ForEach @(
        @{Action='WifiSoft'},@{Action='WifiReset'},@{Action='IPv6Enable'},@{Action='IPv6Disable'}
    ) {
        $expectedAction=$Action
        Invoke-PCAdapterAction $Action '测试网卡操作'
        Should -Invoke Request-PCElevation -Times 1 -ParameterFilter {$Action -eq $expectedAction}
        Should -Invoke Start-PCWork -Times 0
    }
    It 'does not elevate or modify when the user declines authorization' {
        Mock Confirm-PCAction {$false}
        Invoke-PCAdapterAction IPv6Disable '禁用 IPv6'
        Should -Invoke Request-PCElevation -Times 0
        Should -Invoke Start-PCWork -Times 0
    }
    It 'requires confirmation even in an already elevated window' {
        $script:pc.admin=$true
        Mock Confirm-PCAction {$false}
        Invoke-PCAdapterAction WifiReset '重启网卡'
        Should -Invoke Start-PCWork -Times 0
    }
    It 'runs only the selected adapter action after explicit confirmation' {
        $script:pc.admin=$true
        Invoke-PCAdapterAction IPv6Enable '启用 IPv6'
        Should -Invoke Start-PCWork -Times 1 -ParameterFilter {$Action -eq 'IPv6Enable' -and $Options.InterfaceAlias -eq 'Fixture Wi-Fi'}
    }
    It 'keeps a failed action when the user follows authorization guidance' {
        $script:pc.intent='Elevate';$script:pc.resumeAction='IPv6Disable'
        Invoke-PCPrimary
        Should -Invoke Request-PCElevation -Times 1 -ParameterFilter {$Action -eq 'IPv6Disable'}
        Should -Invoke Start-PCWork -Times 0
    }
    It 'requests elevation before a route undo can become a partial recovery' {
        $script:pc.intent='Undo'
        Mock Get-PCUndoSummary {[pscustomobject]@{available=$true;resources=@('WinInet:ProxyEnable','Route:12:0.0.0.0/0')}}
        Invoke-PCPrimary
        Should -Invoke Request-PCElevation -Times 1 -ParameterFilter {$Action -eq 'Undo'}
        Should -Invoke Start-PCWork -Times 0
    }
    It 'does not require elevation for ordinary current-user settings undo' {
        $script:pc.intent='Undo'
        Invoke-PCPrimary
        Should -Invoke Request-PCElevation -Times 0
        Should -Invoke Start-PCWork -Times 1 -ParameterFilter {$Action -eq 'Undo'}
    }
    It 'does not refresh DNS after a declined confirmation' {
        Mock Confirm-PCAction {$false}
        $script:pc.intent='FlushDns';Invoke-PCPrimary
        Should -Invoke Start-PCWork -Times 0
    }
    It 'shows <Action> guidance without executing a network change' -ForEach @(
        @{Action='WifiSoft'},@{Action='WifiReset'},@{Action='IPv6Enable'},@{Action='IPv6Disable'}
    ) {
        $expectedAction=$Action
        Show-PCInitialAction $Action
        $script:pc.ui.AdvancedExpander.IsExpanded|Should -BeTrue
        $script:pc.ui.AdapterCombo.broughtIntoView|Should -BeTrue
        Should -Invoke Set-PCScreen -Times 1 -ParameterFilter {$Intent -eq $expectedAction}
        Should -Invoke Start-PCWork -Times 0
    }
    It 'rebuilds a read-only stop preview with the original expected client' {
        Show-PCInitialAction StopPort
        Should -Invoke Start-PCWork -Times 1 -ParameterFilter {$Action -eq 'StopPreview' -and $Options.Port -eq 34567 -and $Options.ExpectedClient -eq 'ClashVerge'}
    }
    It 'never overrides an unfinished recovery with a requested adapter action' {
        $script:pc.inspection.view.blocked=$true
        Show-PCInitialAction WifiReset
        Should -Invoke Set-PCScreen -Times 0
        Should -Invoke Start-PCWork -Times 0
        $script:pc.ui.AdvancedExpander.IsExpanded|Should -BeFalse
    }
    It 'opens restore guidance without performing an undo' {
        Show-PCInitialAction Undo
        Should -Invoke Set-PCScreen -Times 1 -ParameterFilter {$Intent -eq 'Undo'}
        Should -Invoke Start-PCWork -Times 0
    }
    It 'supports every added handoff through the actual launcher <Action>' -ForEach @(
        @{Action='Undo'},@{Action='IPv6Enable'},@{Action='IPv6Disable'},@{Action='FlushDns'}
    ) {
        $options=Get-PCElevationOptions $Action
        $result=(& (Join-Path $script:root 'Launch-ProxyClean.ps1') @options -PreviewLaunch)|ConvertFrom-Json
        $result.arguments|Should -Contain $Action
        $result.arguments|Should -Contain 'Fixture Wi-Fi'
        $result.preview_first|Should -BeTrue
        $result.side_effects|Should -BeFalse
    }
}

Describe 'One-click close executes real GUI handlers against isolated worker mocks' {
    BeforeAll {
        $tokens=$null;$errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $script:root 'ControlCenter.ps1'),[ref]$tokens,[ref]$errors)
        foreach($name in @('Start-PCDisconnect','Continue-PCDisconnect')){
            $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$false)
            . ([scriptblock]::Create($f.Extent.Text))
        }
    }
    BeforeEach {
        $script:pc=@{job=$null;pending='stale';clientKey=$null;clientInstance=$null;disconnectRequested=$false;elevationAttempted=$false;admin=$false;legacyClient='Any';resumeAction=$null;
            ui=@{PortInput=[pscustomobject]@{Text=''};AdapterCombo=[pscustomobject]@{SelectedItem=$null}}}
        Mock Start-PCWork {}
        Mock Request-PCElevation {}
        Mock Set-PCScreen {}
        Mock Confirm-PCAction {throw 'No second in-app confirmation belongs in a close request'}
    }
    It 'a single click records close intent and queues a read-only preview' {
        Start-PCDisconnect
        $script:pc.disconnectRequested|Should -BeTrue
        $script:pc.pending|Should -BeNullOrEmpty
        Should -Invoke Start-PCWork -Times 1 -ParameterFilter {$Action -eq 'DisconnectPreview'}
        Should -Invoke Confirm-PCAction -Times 0
    }
    It 'continues a verified preview without another user action' {
        Start-PCDisconnect -SelectedClient clash-verge
        Continue-PCDisconnect ([pscustomobject]@{status='client_preview';plan=[pscustomobject]@{key='clash-verge'}})|Should -BeTrue
        Should -Invoke Start-PCWork -Times 1 -ParameterFilter {$Action -eq 'Disconnect' -and $Options.Plan.key -eq 'clash-verge'}
        $script:pc.disconnectRequested|Should -BeFalse
    }
    It 'ignores a second click while work is running' {
        $script:pc.job=@{action='Disconnect'}
        Start-PCDisconnect
        Should -Invoke Start-PCWork -Times 0
    }
    It 'does not apply a preview opened without explicit close intent' {
        Continue-PCDisconnect ([pscustomobject]@{status='client_preview';plan=[pscustomobject]@{key='clash-verge'}})|Should -BeFalse
        Should -Invoke Start-PCWork -Times 0
    }
    It 'binds UAC continuation to the original client and process instance' {
        Start-PCDisconnect -SelectedClient clash-verge
        Continue-PCDisconnect ([pscustomobject]@{status='client_needs_admin';key='clash-verge';instance=('a'*64)})|Should -BeTrue
        $o=Get-PCElevationOptions Disconnect
        $o.ResumeDisconnect|Should -BeTrue;$o.ExpectedClientInstance|Should -Be ('a'*64);$o.ClientKey|Should -Be clash-verge
        Should -Invoke Request-PCElevation -Times 1 -ParameterFilter {$Action -eq 'Disconnect'}
        $launch=(& (Join-Path $script:root 'Launch-ProxyClean.ps1') @o -PreviewLaunch)|ConvertFrom-Json
        $launch.arguments|Should -Contain '-ResumeDisconnect';$launch.preview_first|Should -BeFalse;$launch.side_effects|Should -BeFalse
    }
    It 'stops instead of looping when authorization remains insufficient' {
        $script:pc.disconnectRequested=$true;$script:pc.elevationAttempted=$true
        Continue-PCDisconnect ([pscustomobject]@{status='client_needs_admin'})|Should -BeTrue
        Should -Invoke Request-PCElevation -Times 0
        Should -Invoke Start-PCWork -Times 0
        $script:pc.disconnectRequested|Should -BeFalse
    }
    It 'does not close all clients when a choice is required' {
        $script:pc.disconnectRequested=$true
        Continue-PCDisconnect ([pscustomobject]@{status='choose_client'})|Should -BeFalse
        Should -Invoke Start-PCWork -Times 0
    }
    It 'clears retained intent when discovery fails' {
        $script:pc.disconnectRequested=$true
        Continue-PCDisconnect ([pscustomobject]@{status='failed'})|Should -BeFalse
        $script:pc.disconnectRequested|Should -BeFalse
        Should -Invoke Start-PCWork -Times 0
    }
    It 'rejects an incomplete UAC-resume command before any launch' {
        {& (Join-Path $script:root 'Launch-ProxyClean.ps1') -InitialAction Disconnect -ResumeDisconnect -Elevated -PreviewLaunch}|Should -Throw '*Invalid client disconnect continuation*'
    }
}
