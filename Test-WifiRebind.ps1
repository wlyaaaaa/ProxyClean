param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot "WifiRebind.ps1")
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        $script:failures.Add($Message)
    }
}

Assert-True (Test-Path -LiteralPath $ScriptPath) "WifiRebind.ps1 should exist"

if (Test-Path -LiteralPath $ScriptPath) {
    $content = Get-Content -LiteralPath $ScriptPath -Raw
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)

    Assert-True ($errors.Count -eq 0) "WifiRebind.ps1 should parse without syntax errors"
    Assert-True ($content -match 'ValidateSet\("Diagnose",\s*"SoftReset",\s*"AdapterReset"\)') "Mode should be limited to Diagnose, SoftReset, and AdapterReset"
    Assert-True ($content -match '\$Mode\s*=\s*"Diagnose"') "Default mode should be Diagnose"
    Assert-True ($content -match 'Disable-NetAdapter') "AdapterReset should disable the selected WiFi adapter"
    Assert-True ($content -match 'Enable-NetAdapter') "AdapterReset should re-enable the selected WiFi adapter"
    Assert-True ($content -match 'ipconfig\s*/flushdns') "Soft reset should flush DNS"
    Assert-True ($content -notmatch 'route\s+delete') "Script should not delete routes"
    Assert-True ($content -notmatch 'Set-DnsClientServerAddress') "Script should not change DNS servers"
    Assert-True ($content -notmatch 'Stop-Service') "Script should not stop services"
    Assert-True ($content -notmatch 'Stop-Process') "Script should not kill processes"

    $hasBoundCurl = $content -match '--interface\s+\$wifiIp' -and $content -match '--noproxy\s+"\*"'
    Assert-True $hasBoundCurl "Diagnostics should include a WiFi-bound curl check that bypasses proxies"
    Assert-True ($content -match '模式') "User-facing script output should be Chinese"
    Assert-True ($content -match '检测到 WiFi 网卡') "Script should show the detected WiFi adapter in Chinese"
    Assert-True ($content -match '轻量刷新') "SoftReset user-facing text should be Chinese"
    Assert-True ($content -match '重启 WiFi 网卡') "AdapterReset user-facing text should be Chinese"

    $null = $ast
}

$batFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.bat"
$oneClickSoft = $batFiles |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'SoftReset' } |
    Select-Object -First 1
$oneClickAdapter = $batFiles |
    Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'AdapterReset' } |
    Select-Object -First 1

Assert-True ($null -ne $oneClickSoft) "SoftReset one-click .bat should exist"
Assert-True ($null -ne $oneClickAdapter) "AdapterReset one-click .bat should exist"

if ($oneClickSoft) {
    $softBat = Get-Content -LiteralPath $oneClickSoft.FullName -Raw -Encoding UTF8
    Assert-True ($softBat -match 'chcp 65001') "SoftReset one-click .bat should use UTF-8 code page"
    Assert-True ($softBat -match 'WifiRebind\.ps1') "SoftReset one-click .bat should call WifiRebind.ps1"
    Assert-True ($softBat -match 'SoftReset') "SoftReset one-click .bat should run SoftReset"
    Assert-True ($softBat -match '轻量刷新') "SoftReset one-click .bat should show Chinese text"
}

if ($oneClickAdapter) {
    $adapterBat = Get-Content -LiteralPath $oneClickAdapter.FullName -Raw -Encoding UTF8
    Assert-True ($adapterBat -match 'chcp 65001') "AdapterReset one-click .bat should use UTF-8 code page"
    Assert-True ($adapterBat -match 'WifiRebind\.ps1') "AdapterReset one-click .bat should call WifiRebind.ps1"
    Assert-True ($adapterBat -match 'AdapterReset') "AdapterReset one-click .bat should run AdapterReset"
    Assert-True ($adapterBat -match 'RunAs') "AdapterReset one-click .bat should request administrator rights"
    Assert-True ($adapterBat -match '重启 WiFi 网卡') "AdapterReset one-click .bat should show Chinese text"
}

if ($failures.Count -gt 0) {
    Write-Host "FAILED"
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "PASSED"
