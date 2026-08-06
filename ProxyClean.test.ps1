[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSCommandPath

function Assert-True([bool]$condition, [string]$message){
    if(-not $condition){ throw $message }
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
Assert-True ($fallback -notmatch '(?<!\d)(?:7892|18090|18091)(?!\d)') 'The retired fallback still contains fixed proxy-client ports.'
Assert-True ($fallback -match 'MATCH,DIRECT') 'The retired fallback is not DIRECT-only.'

$statusJson = & (Join-Path $root 'ProxyStatus.ps1') -SkipExitProbe -Json
$statusSucceeded = $?
Assert-True $statusSucceeded 'ProxyStatus read-only JSON probe failed.'
$snapshot = $statusJson | ConvertFrom-Json -Depth 12
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
