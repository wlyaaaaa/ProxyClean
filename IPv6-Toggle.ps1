# Toggle IPv6 bindings on active physical NIC(s) only.
# Excludes natpierce (public NAT-traversal needs its IPv6) and all virtual adapters.
# Run elevated (the .bat self-elevates).
$ErrorActionPreference = 'Stop'
$exclude = 'VMware|vEthernet|Loopback|Tailscale|WSL|FlyingBird|natpierce'
$nics = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and
    $_.HardwareInterface -eq $true -and
    $_.Name -notmatch $exclude
}

if (-not $nics) { Write-Host "  No active physical NIC found to toggle." -ForegroundColor Red; Start-Sleep 3; exit }

$anyOn = $false
foreach ($n in $nics) { if ((Get-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6).Enabled) { $anyOn = $true } }

Write-Host ""
if ($anyOn) {
    foreach ($n in $nics) { Disable-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6 }
    ipconfig /flushdns | Out-Null
    Write-Host "  IPv6 bindings disabled on selected physical adapters. natpierce untouched." -ForegroundColor Cyan
} else {
    foreach ($n in $nics) { Enable-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6 }
    ipconfig /flushdns | Out-Null
    Write-Host "  IPv6 bindings enabled on selected physical adapters. natpierce untouched." -ForegroundColor Cyan
}
foreach ($n in $nics) {
    $on = (Get-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6).Enabled
    Write-Host ("    {0,-26} IPv6 = {1}" -f $n.Name, $(if ($on -eq $true) { 'ON' } elseif ($on -eq $false) { 'OFF' } else { 'UNKNOWN' }))
}
Write-Host "  Proxy use and Internet reachability: not tested."
Write-Host ""
