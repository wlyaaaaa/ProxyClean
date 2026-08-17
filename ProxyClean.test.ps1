[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

function Assert-True([bool]$condition, [string]$message){
    if(-not $condition){ throw $message }
}

function Get-FunctionDefinitionText([string]$path, [string]$name){
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) "$path has parser errors: $(@($errors).Message -join '; ')"
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    Assert-True ($null -ne $definition) "$path does not define $name."
    return $definition.Extent.Text
}

foreach($name in 'ProxyClean.ps1','ProxyStatus.ps1','Stop-ProxyPort.ps1'){
    $path = Join-Path $root $name
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    Assert-True (@($errors).Count -eq 0) "$name has parser errors: $(@($errors).Message -join '; ')"
}

$clean = Get-Content -LiteralPath (Join-Path $root 'ProxyClean.ps1') -Raw
$status = Get-Content -LiteralPath (Join-Path $root 'ProxyStatus.ps1') -Raw
$fallback = Get-Content -LiteralPath (Join-Path $root 'fallback\config.yaml') -Raw
$runtimeScripts = $clean + "`n" + $status

Assert-True ($clean -notmatch '\$Airports') 'ProxyClean still contains the legacy fixed client-port table.'
Assert-True ($runtimeScripts -notmatch '(?<!\d)(?:7892|18090|18091)(?!\d)') 'A legacy client port remains in automatic runtime discovery.'
Assert-True ($clean -match 'Get-LocalProxyPorts') 'ProxyClean does not discover the current WinINET endpoint.'
Assert-True ($clean -match 'activeTunRoutes') 'ProxyClean does not discover active fake-ip TUN routes.'
Assert-True ($status -match 'published_by_system_proxy') 'ProxyStatus does not distinguish WinINET-published proxy endpoints.'
Assert-True ($status -match 'Get-DockerProxySnapshot') 'ProxyStatus does not audit Docker Desktop consumer proxy pins.'
Assert-True ($status -notmatch 'ConvertFrom-Json\s+-Depth') 'ProxyStatus uses a PowerShell 7-only ConvertFrom-Json parameter.'
Assert-True ($fallback -notmatch '(?<!\d)(?:7892|18090|18091)(?!\d)') 'The retired fallback still contains fixed proxy-client ports.'
Assert-True ($fallback -match 'MATCH,DIRECT') 'The retired fallback is not DIRECT-only.'

# 只导入函数定义，不执行会清代理/路由的主脚本。
$global:ProxyCleanTestAlivePorts = @()
$moduleSource = @(
    'function Test-PortAlive([int]$p){ return $global:ProxyCleanTestAlivePorts -contains $p }'
    'function Info($m){}'
    'function Ok($m){}'
    'function Warn($m){}'
    (Get-FunctionDefinitionText (Join-Path $root 'ProxyClean.ps1') 'Get-ProxyEndpoints')
    (Get-FunctionDefinitionText (Join-Path $root 'ProxyClean.ps1') 'Test-LocalProxyDead')
    (Get-FunctionDefinitionText (Join-Path $root 'ProxyClean.ps1') 'Clear-GitProxySettings')
    (Get-FunctionDefinitionText (Join-Path $root 'Stop-ProxyPort.ps1') 'Test-LocalProxyForPort')
    (Get-FunctionDefinitionText (Join-Path $root 'ProxyStatus.ps1') 'Get-LocalProxyPorts')
    'Export-ModuleMember -Function Get-ProxyEndpoints,Test-LocalProxyDead,Clear-GitProxySettings,Test-LocalProxyForPort,Get-LocalProxyPorts'
) -join "`n"
$testModule = New-Module -Name ("ProxyClean.UnitTests.{0}" -f [Guid]::NewGuid().ToString('N')) -ScriptBlock ([ScriptBlock]::Create($moduleSource))
Import-Module $testModule -Force

Assert-True (Test-LocalProxyDead 'http://127.0.0.1:65534') 'A dead local proxy should be detected.'
Assert-True (-not (Test-LocalProxyDead 'http=127.0.0.1:65534;https=proxy.example.test:443')) 'A mixed local/remote proxy must not be cleared as fully dead.'
Assert-True (-not (Test-LocalProxyDead 'https://proxy.example.test:443')) 'A remote proxy must not be treated as local.'
$global:ProxyCleanTestAlivePorts = @(7892)
Assert-True (-not (Test-LocalProxyDead 'http://localhost:7892')) 'A live local proxy must be preserved.'
$global:ProxyCleanTestAlivePorts = @()
Assert-True (Test-LocalProxyDead 'http://[::1]:65534') 'An IPv6 loopback proxy should be recognized.'

Assert-True (Test-LocalProxyForPort 'http=localhost:7892;https=proxy.example.test:443' 7892) 'The requested local endpoint should match.'
Assert-True (-not (Test-LocalProxyForPort 'http=proxy.example.test:7892;https=localhost:8080' 7892)) 'A remote port must not cross-match a different local endpoint.'
Assert-True (-not (Test-LocalProxyForPort 'http://mylocalhost:7892' 7892)) 'A hostname suffix must not be mistaken for localhost.'
Assert-True (@(Get-LocalProxyPorts 'http=mylocalhost:7892').Count -eq 0) 'ProxyStatus must not mistake a hostname suffix for localhost.'
Assert-True (@(Get-LocalProxyPorts 'http=[::1]:7892') -contains 7892) 'ProxyStatus should recognize an IPv6 loopback endpoint.'
Assert-True (@(Get-LocalProxyPorts 'http=localhost:99999').Count -eq 0) 'ProxyStatus must reject an invalid TCP port.'

$testConfigDir = Join-Path ([IO.Path]::GetTempPath()) 'Codex'
$testConfig = Join-Path $testConfigDir ("proxyclean-test-{0}.gitconfig" -f [Guid]::NewGuid().ToString('N'))
$previousGitConfigGlobal = [Environment]::GetEnvironmentVariable('GIT_CONFIG_GLOBAL', 'Process')
try {
    New-Item -ItemType Directory -Path $testConfigDir -Force | Out-Null
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $testConfig, 'Process')
    & git config --global http.proxy 'https://proxy.example.test:8443'
    & git config --global https.proxy 'http://127.0.0.1:65534'
    Assert-True ($LASTEXITCODE -eq 0) 'Failed to create isolated git proxy test configuration.'

    Clear-GitProxySettings
    $httpProxy = (& git config --global --get http.proxy) 2>$null
    $httpsProxy = (& git config --global --get https.proxy) 2>$null
    Assert-True ($httpProxy -eq 'https://proxy.example.test:8443') 'A valid remote git proxy should be preserved.'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$httpsProxy)) 'A dead local https.proxy should be cleared independently.'
}
finally {
    [Environment]::SetEnvironmentVariable('GIT_CONFIG_GLOBAL', $previousGitConfigGlobal, 'Process')
    if(Test-Path -LiteralPath $testConfig -PathType Leaf){ Remove-Item -LiteralPath $testConfig -Force }
}
Remove-Module $testModule -Force
Remove-Variable -Name ProxyCleanTestAlivePorts -Scope Global -ErrorAction SilentlyContinue

$statusJson = & (Join-Path $root 'ProxyStatus.ps1') -SkipExitProbe -Json
$statusSucceeded = $?
Assert-True $statusSucceeded 'ProxyStatus read-only JSON probe failed.'
$snapshot = $statusJson | ConvertFrom-Json
Assert-True ($snapshot.schema -eq 'proxyclean.dynamic-status.v1') 'ProxyStatus returned an unexpected schema.'
Assert-True ($snapshot.discovery -eq 'wininet_endpoint_plus_live_proxy_owned_listeners_and_active_routes') 'ProxyStatus returned an unexpected discovery strategy.'
Assert-True ($null -ne $snapshot.docker_proxy) 'ProxyStatus did not return Docker Desktop proxy evidence.'

[pscustomobject][ordered]@{
    status = 'pass'
    parser_files = 3
    fixed_runtime_client_ports = 0
    observed_system_proxy = $snapshot.system_proxy
    observed_tun_route_count = @($snapshot.tun_routes).Count
} | ConvertTo-Json -Depth 8 -Compress
