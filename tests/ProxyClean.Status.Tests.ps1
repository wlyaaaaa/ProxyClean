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
        $r.client_inventory[0].saved_preferences.state|Should -Be 'observed';$r.client_inventory[0].saved_preferences.tun_enabled|Should -BeTrue
        $r.deviations.code|Should -Not -Contain 'dual_tun';$r.summary|Should -Match '保存TUN开/保存系统代理关'
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
    It 'flags inactive saved preferences without counting them as active TUN' {
        $flutter.patchClashConfig.tun.enable=$false;$flutter.networkProps.systemProxy=$true
        [IO.File]::WriteAllText((Join-Path $bird 'shared_preferences.json'),(@{'flutter.config'=($flutter|ConvertTo-Json -Depth 10 -Compress)}|ConvertTo-Json -Compress))
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.deviations.code|Should -Contain 'saved_tun_disabled';$r.deviations.code|Should -Contain 'saved_system_proxy_enabled'
        $r.deviations.code|Should -Not -Contain 'dual_tun';$r.client_inventory[0].running|Should -BeFalse
        @($r.deviations|Where-Object family -eq flyingbird)|Should -HaveCount 2
        (Get-PCClientStatus $snapshot -Processes $processes).deviations|Should -HaveCount 0
    }
    It 'distinguishes missing and invalid saved preferences: <Case>' -TestCases @(
        @{Case='bird missing field';Index=0;State='missing_field'},
        @{Case='bird wrong type';Index=0;State='invalid_format'},
        @{Case='bird malformed JSON';Index=0;State='invalid_format'},
        @{Case='bird missing file';Index=0;State='missing_file'},
        @{Case='clash duplicate';Index=1;State='invalid_format'},
        @{Case='clash quoted bool';Index=1;State='invalid_format'},
        @{Case='clash missing field';Index=1;State='missing_field'},
        @{Case='clash missing file';Index=1;State='missing_file'}
    ) {
        param($Case,$Index,$State)
        $path=Join-Path $bird 'shared_preferences.json';$verge=Join-Path $clash 'verge.yaml'
        switch($Case){
            'bird missing field' {$flutter.vpnProps.Remove('enable')}
            'bird wrong type' {$flutter.vpnProps.enable='NEVER_OUTPUT'}
            'bird malformed JSON' {[IO.File]::WriteAllText($path,'{NEVER_OUTPUT')}
            'bird missing file' {Remove-Item -LiteralPath $path}
            'clash duplicate' {[IO.File]::WriteAllText($verge,"enable_tun_mode: true`nenable_tun_mode: false`nenable_system_proxy: false")}
            'clash quoted bool' {[IO.File]::WriteAllText($verge,"enable_tun_mode: 'true'`nenable_system_proxy: false")}
            'clash missing field' {[IO.File]::WriteAllText($verge,'enable_system_proxy: false')}
            'clash missing file' {Remove-Item -LiteralPath $verge}
        }
        if($Case -in @('bird missing field','bird wrong type')){[IO.File]::WriteAllText($path,(@{'flutter.config'=($flutter|ConvertTo-Json -Depth 10 -Compress)}|ConvertTo-Json -Compress))}
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.client_inventory[$Index].saved_preferences.state|Should -Be $State
        $r.client_inventory[$Index].saved_preferences.tun_enabled|Should -BeNullOrEmpty
        $r.summary|Should -Not -Match '符合默认';($r|ConvertTo-Json -Depth 20)|Should -Not -Match 'NEVER_OUTPUT'
    }
    It 'does not substitute Apex preferences for the legacy FlyingBird format' {
        Mock Get-PCStatusInstallations -ModuleName ProxyClean.Common {@([pscustomobject]@{name='FlyingBird'},[pscustomobject]@{name='Clash Verge'})}
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.client_inventory[0].saved_preferences.state|Should -Be 'unsupported'
        $r.client_inventory[0].saved_preferences.tun_enabled|Should -BeNullOrEmpty
    }
    It 'does not select one of several Clash preference roots' {
        $other=Join-Path $env:APPDATA 'other-clash-verge';[IO.Directory]::CreateDirectory($other)|Out-Null
        Copy-Item -LiteralPath (Join-Path $clash 'verge.yaml') -Destination $other
        Copy-Item -LiteralPath (Join-Path $clash 'profiles.yaml') -Destination $other
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.client_inventory[1].saved_preferences.state|Should -Be 'ambiguous'
        $r.client_inventory[1].saved_preferences.tun_enabled|Should -BeNullOrEmpty
    }
    It 'distinguishes an unreadable preference location from an unknown format' {
        Mock Get-ChildItem -ModuleName ProxyClean.Common {throw [UnauthorizedAccessException]::new('NEVER_OUTPUT')} -ParameterFilter {$LiteralPath -eq $env:APPDATA}
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes
        $r.status|Should -Be 'unknown';$r.client_inventory[1].saved_preferences.state|Should -Be 'unavailable'
        ($r|ConvertTo-Json -Depth 20)|Should -Not -Match 'NEVER_OUTPUT'
    }
    It 'reports an absent configuration directory as missing files' {
        $r=Get-PCClientStatus $snapshot TunOnly -Processes $processes -AppDataPath (Join-Path $TestDrive 'absent-appdata')
        $r.status|Should -Be 'unknown'
        foreach($client in $r.client_inventory){$client.saved_preferences.state|Should -Be 'missing_file'}
    }
}
