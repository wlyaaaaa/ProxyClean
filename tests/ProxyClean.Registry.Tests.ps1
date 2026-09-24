#Requires -Version 5.1
# Exercise the real registry provider under a disposable key, never live proxy settings.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ProxyClean.Common.psm1') -Force
    $registryRoot='HKCU:\Software\ProxyClean.Tests\'+[Guid]::NewGuid().ToString('N')
    New-Item -Path $registryRoot -Force -ErrorAction Stop|Out-Null
}
AfterAll {
    if($registryRoot -and (Test-Path -LiteralPath $registryRoot)){
        Remove-Item -LiteralPath $registryRoot -Recurse -Force -ErrorAction Stop
    }
}
Describe 'Registry effects use writable operations, not read-only Get-Item handles' {
    BeforeEach {
        $caseRoot=Join-Path $registryRoot ([Guid]::NewGuid().ToString('N'))
        $wininet=Join-Path $caseRoot 'WinInet';$userenv=Join-Path $caseRoot 'UserEnv'
        New-Item -Path $wininet -Force|Out-Null
        New-Item -Path $userenv -Force|Out-Null
        InModuleScope ProxyClean.Common -Parameters @{WinInet=$wininet;UserEnv=$userenv} {
            param($WinInet,$UserEnv)
            $script:registryFixturePaths=@{WinInet=$WinInet;UserEnv=$UserEnv}
            Mock Get-PCRegistryPath {param($Area) $script:registryFixturePaths[$Area]}
        }
    }
    It 'writes and reads back a WinINET DWORD' {
        New-ItemProperty -LiteralPath $wininet -Name ProxyEnable -Value 1 -PropertyType DWord|Out-Null
        $after=[pscustomobject][ordered]@{exists=$true;value=0;kind='DWord'}
        Set-PCResourceValue -Step ([pscustomobject]@{kind='WinInet';name='ProxyEnable'}) -Value $after
        Test-PCSameValue (Get-PCRegistryValue WinInet ProxyEnable) $after|Should -BeTrue
    }
    It 'updates a mapping without erasing unrelated values' {
        New-ItemProperty -LiteralPath $wininet -Name ProxyServer -Value 'localhost:34567' -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $wininet -Name AutoConfigURL -Value 'https://fixture.example.test/pac' -PropertyType String|Out-Null
        $after=[pscustomobject][ordered]@{exists=$true;value='https=proxy.example.test:443';kind='String'}
        Set-PCResourceValue -Step ([pscustomobject]@{kind='WinInet';name='ProxyServer'}) -Value $after
        Test-PCSameValue (Get-PCRegistryValue WinInet ProxyServer) $after|Should -BeTrue
        (Get-ItemPropertyValue -LiteralPath $wininet -Name AutoConfigURL)|Should -Be 'https://fixture.example.test/pac'
    }
    It 'deletes only the selected user proxy value' {
        New-ItemProperty -LiteralPath $userenv -Name HTTP_PROXY -Value 'localhost:34567' -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $userenv -Name NO_PROXY -Value 'fixture.example.test' -PropertyType String|Out-Null
        Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='HTTP_PROXY'}) -Value ([pscustomobject]@{exists=$false;value=$null;kind=$null})
        (Get-PCRegistryValue UserEnv HTTP_PROXY).exists|Should -BeFalse
        (Get-ItemPropertyValue -LiteralPath $userenv -Name NO_PROXY)|Should -Be 'fixture.example.test'
    }
    It 'preserves literal expandable strings and their registry type' {
        $after=[pscustomobject][ordered]@{exists=$true;value='http://%PROXYCLEAN_FIXTURE_HOST%:34567';kind='ExpandString'}
        Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='HTTPS_PROXY'}) -Value $after
        Test-PCSameValue (Get-PCRegistryValue UserEnv HTTPS_PROXY) $after|Should -BeTrue
    }
    It 'treats an already missing value as an idempotent deletion' {
        {Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='ALL_PROXY'}) -Value ([pscustomobject]@{exists=$false})}|Should -Not -Throw
    }
    It 'creates a missing environment key only for a requested value' {
        Remove-Item -LiteralPath $userenv -Recurse -Force
        $after=[pscustomobject][ordered]@{exists=$true;value='localhost:34567';kind='String'}
        Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='ALL_PROXY'}) -Value $after
        Test-PCSameValue (Get-PCRegistryValue UserEnv ALL_PROXY) $after|Should -BeTrue
    }
    It 'does not create a missing key for deletion' {
        Remove-Item -LiteralPath $userenv -Recurse -Force
        Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='ALL_PROXY'}) -Value ([pscustomobject]@{exists=$false})
        Test-Path -LiteralPath $userenv|Should -BeFalse
    }
    It 'retains the existing field allowlist' {
        {Set-PCResourceValue -Step ([pscustomobject]@{kind='WinInet';name='AutoConfigURL'}) -Value ([pscustomobject]@{exists=$false})}|Should -Throw '*Unsupported*'
        {Set-PCResourceValue -Step ([pscustomobject]@{kind='UserEnv';name='NO_PROXY'}) -Value ([pscustomobject]@{exists=$false})}|Should -Throw '*Unsupported*'
    }
}
Describe 'Mocked client shutdown completes real isolated settings writes and undo' {
    BeforeEach {
        $caseRoot=Join-Path $registryRoot ([Guid]::NewGuid().ToString('N'))
        $wininet=Join-Path $caseRoot 'WinInet';$userenv=Join-Path $caseRoot 'UserEnv'
        New-Item -Path $wininet -Force|Out-Null;New-Item -Path $userenv -Force|Out-Null
        New-ItemProperty -LiteralPath $wininet -Name ProxyEnable -Value 1 -PropertyType DWord|Out-Null
        New-ItemProperty -LiteralPath $wininet -Name ProxyServer -Value '127.0.0.1:34567' -PropertyType String|Out-Null
        New-ItemProperty -LiteralPath $userenv -Name HTTP_PROXY -Value 'http://127.0.0.1:34567' -PropertyType String|Out-Null
        InModuleScope ProxyClean.Common -Parameters @{WinInet=$wininet;UserEnv=$userenv;Journal=(Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.dpapi'))} {
            param($WinInet,$UserEnv,$Journal)
            $script:registryFixturePaths=@{WinInet=$WinInet;UserEnv=$UserEnv};$script:registryFixtureJournal=$Journal
            Mock Get-PCRegistryPath {param($Area) $script:registryFixturePaths[$Area]}
            Mock Get-PCJournalPath {$script:registryFixtureJournal}
            Mock Enter-PCLock {[Threading.Mutex]::new($true)}
            Mock Test-PCClientProcess {$false}
            Mock Request-PCClientWindowClose {}
            Mock Stop-PCClientService {}
            Mock Stop-Process {throw 'Real process termination is prohibited in this test.'}
            Mock Invoke-PCNative {throw 'Native process execution is prohibited in this test.'}
            Mock Get-NetTCPConnection {@()}
            Mock Get-PCClientInventory {@()}
            Mock Get-PCLocalPortListeners {@()}
            Mock Get-CimInstance {@()}
            Mock Test-PCConnectivity {[pscustomobject]@{status='http_reachable'}}
            Mock Send-PCSettingsChanged {[pscustomobject]@{wininet_notified=$true}}
            Mock Get-PCSnapshot {
                $enabled=Get-PCRegistryValue WinInet ProxyEnable;$server=Get-PCRegistryValue WinInet ProxyServer;$envValue=Get-PCRegistryValue UserEnv HTTP_PROXY
                [pscustomobject]@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;observedUtc=[DateTimeOffset]::UtcNow.ToString('O');isSystem=$false;sessionId=1
                    availability=[pscustomobject]@{listeners='observed';adapters='observed';routes='observed';wininet='observed';environment='observed';git='observed';winhttp='not_inspected';docker='not_inspected'}
                    systemProxy=[pscustomobject]@{enabled=([bool]$enabled.value);server=$server.value;pac='';values=[pscustomobject]@{ProxyEnable=$enabled;ProxyServer=$server}}
                    environment=@([pscustomobject]@{scope='User';name='HTTP_PROXY';value=$envValue.value;registry=$envValue})
                    listeners=@();adapters=@();routes=@();git=@();winhttp=$null;docker=$null}
            }
        }
    }
    It 'cleans and restores <Label> settings (force=<Force>) without live shutdown' -ForEach @(
        @{Key='flyingbird';Label='FlyingBird';Force=$false},@{Key='flyingbird';Label='FlyingBird';Force=$true},
        @{Key='clash-verge';Label='Clash Verge';Force=$false},@{Key='clash-verge';Label='Clash Verge';Force=$true}
    ) {
        InModuleScope ProxyClean.Common -Parameters @{Key=$Key;Label=$Label;Force=$Force} {
            param($Key,$Label,$Force)
            $plan=[pscustomobject]@{schema='proxyclean.client-close.v1';sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;key=$Key;label=$Label;members=@([pscustomobject]@{pid=991231;name='fixture';path='C:\Fixture\proxy.exe';session=1;start_utc='fixture'});services=@();ports=@(34567);observedUtc='fixture'}
            $result=Invoke-PCClientClose -Plan $plan -Force:$Force -WaitSeconds 0 -Confirm:$false
            $result.status|Should -Be client_closed;$result.settings.status|Should -Be applied;$result.settings.changed|Should -Be 2
            (Get-PCRegistryValue WinInet ProxyEnable).value|Should -Be 0
            (Get-PCRegistryValue UserEnv HTTP_PROXY).exists|Should -BeFalse
            (Get-PCJournal).phase|Should -Be completed
            (Invoke-PCUndo -Confirm:$false).status|Should -Be recovered
            (Get-PCRegistryValue WinInet ProxyEnable).value|Should -Be 1
            (Get-PCRegistryValue UserEnv HTTP_PROXY).value|Should -Be 'http://127.0.0.1:34567'
            (Get-PCJournal).phase|Should -Be undone
            Should -Invoke Stop-Process -Times 0;Should -Invoke Invoke-PCNative -Times 0
            Should -Invoke Request-PCClientWindowClose -Times 1
        }
    }
}
