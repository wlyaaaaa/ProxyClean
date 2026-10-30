#Requires -Version 5.1
BeforeAll { Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force }
Describe 'Read-only status reports both installed clients and TunOnly deviations' {
    BeforeEach {
        $script:previousAppData=$env:APPDATA;$env:APPDATA=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $clash=Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev';[IO.Directory]::CreateDirectory($clash)|Out-Null
        [IO.File]::WriteAllText((Join-Path $clash 'verge.yaml'),"enable_tun_mode: true`nenable_system_proxy: false`nsecret: NEVER_OUTPUT")
        [IO.File]::WriteAllText((Join-Path $clash 'profiles.yaml'),@'
current: active
items:
- uid: rules1
  type: rules
  file: rules1.yaml
- uid: active
  type: remote
  name: fixture subscription
  file: active.yaml
  url: https://example.invalid/NEVER_OUTPUT
  option:
    rules: rules1
'@)
        $bird=Join-Path $env:APPDATA 'com.fbapp.clients.apex\飞鸟-极速版';[IO.Directory]::CreateDirectory($bird)|Out-Null
        $flutter=@{networkProps=@{systemProxy=$false;proxyPassword='NEVER_OUTPUT'};vpnProps=@{enable=$true;systemProxy=$false};patchClashConfig=@{tun=@{enable=$true;device='FlyingBird'}};subscription='NEVER_OUTPUT'}
        [IO.File]::WriteAllText((Join-Path $bird 'shared_preferences.json'),(@{'flutter.config'=($flutter|ConvertTo-Json -Depth 10 -Compress)}|ConvertTo-Json -Compress))
        Mock Get-PCStatusInstallations -ModuleName ProxyClean.Common { @([pscustomobject]@{name='飞鸟-极速版'},[pscustomobject]@{name='Clash Verge'}) }
        Mock Get-CimInstance -ModuleName ProxyClean.Common { throw 'Status fixtures must never query live processes' }
        Mock Invoke-PCNative -ModuleName ProxyClean.Common { throw 'Status fixtures must never request a network or external program' }
        $script:snapshot=[pscustomobject]@{availability=[pscustomobject]@{adapters='observed';listeners='observed';routes='observed';wininet='observed'};systemProxy=[pscustomobject]@{enabled=$false;server='127.0.0.1:34567'};adapters=@([pscustomobject]@{Name='Meta';Status='Up';InterfaceIndex=21},[pscustomobject]@{Name='FlyingBird';Status='Down';InterfaceIndex=22});listeners=@([pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=34567;OwningProcess=501},[pscustomobject]@{LocalAddress='127.0.0.1';LocalPort=34568;OwningProcess=502})}
        $script:processes=@([pscustomobject]@{ProcessId=501;Name='verge-mihomo.exe';ExecutablePath='X:\Fixture\verge-mihomo.exe';SessionId=(Get-Process -Id $PID).SessionId;ParentProcessId=0;CreationDate=(Get-Date).AddMinutes(-5)})
    }
    AfterEach {$env:APPDATA=$script:previousAppData}
    It 'keeps the inactive installed client and assigns ports by PID' {
        $processes[0].SessionId=500
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'pass';$r.client_inventory|Should -HaveCount 2
        $r.client_inventory[0].installed|Should -BeTrue;$r.client_inventory[0].running|Should -BeFalse
        $r.client_inventory[1].listeners|Should -HaveCount 1;$r.client_inventory[1].listeners[0].LocalPort|Should -Be 34567
        $r.client_inventory[1].settings.profiles[0].name|Should -Be 'fixture subscription';$r.client_inventory[1].settings.rule_files[0].active|Should -BeTrue
        ($r|ConvertTo-Json -Depth 20)|Should -Not -Match 'NEVER_OUTPUT'
        $r.summary|Should -Match '飞鸟=已装未运行';$r.summary|Should -Match '符合默认'
    }
    It 'flags an enabled system proxy even when its listener works' {
        $snapshot.systemProxy.enabled=$true;$r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.deviations|Should -HaveCount 1;$r.deviations[0].code|Should -Be 'system_proxy_enabled';$r.deviations[0].repair|Should -Not -BeNullOrEmpty
    }
    It 'flags two TUN adapters and preserves zero clients separately' {
        $snapshot.adapters[1].Status='Up';$r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.deviations.code|Should -Contain 'dual_tun'
        $snapshot.adapters[0].Status='Down';$snapshot.adapters[1].Status='Down';$r=Get-PCClientStatus $snapshot TunOnly -Processes @()
        $r.deviations.code|Should -Contain 'no_tun';$r.deviations.code|Should -Contain 'no_client'
    }
    It 'does not count a launch helper as a running proxy core' {
        $processes[0].Name='clash-verge-service.exe';$processes[0].ExecutablePath='X:\Fixture\clash-verge-service.exe'
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.deviations.code|Should -Contain 'no_client'
    }
    It 'does not count a shared application entry as FlyingBird running' {
        $processes[0].Name='fb-ai-entry.exe';$processes[0].ExecutablePath='X:\Fixture\fb-ai-entry.exe'
        Mock Get-PCClientInventory -ModuleName ProxyClean.Common {param($Processes) [pscustomobject]@{family_key='flyingbird';members=$Processes}}
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.client_inventory[0].helpers|Should -HaveCount 1;$r.deviations.code|Should -Contain 'no_client'
    }
    It 'keeps failed collection unknown instead of declaring healthy or absent' {
        $snapshot.availability.adapters='unknown';$r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.deviations|Should -HaveCount 0
        $processes[0].Name='Apex.exe';$processes[0].ExecutablePath=$null;$snapshot.availability.adapters='observed'
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.collection_errors|Should -Contain 'client_identity_unavailable'
    }
    It 'does not apply expectations unless explicitly selected' {
        $snapshot.systemProxy.enabled=$true;$r=Get-PCClientStatus $snapshot -Processes @()
        $r.deviations|Should -HaveCount 0;$r.expect_mode|Should -BeNullOrEmpty
    }
}
