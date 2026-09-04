# Toggle IPv6 on the physical internet NIC(s) only.
# Excludes natpierce (public NAT-traversal needs its IPv6) and all virtual adapters.
# Run elevated (the .bat self-elevates).
$ErrorActionPreference = 'Stop'
$exclude = 'VMware|vEthernet|Loopback|Tailscale|WSL|FlyingBird|natpierce'
$nics = Get-NetAdapter | Where-Object {
    $_.Status -eq 'Up' -and
    $_.HardwareInterface -eq $true -and
    $_.Name -notmatch $exclude
}

if (-not $nics) { Write-Host "  No internet NIC found to toggle." -ForegroundColor Red; Start-Sleep 3; exit }

$anyOn = $false
foreach ($n in $nics) { if ((Get-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6).Enabled) { $anyOn = $true } }

Write-Host ""
if ($anyOn) {
    foreach ($n in $nics) { Disable-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6 }
    ipconfig /flushdns | Out-Null
    Write-Host "  IPv6 -> OFF   (all traffic uses IPv4 / proxy; Google & VPN stable). natpierce untouched." -ForegroundColor Green
} else {
    foreach ($n in $nics) { Enable-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6 }
    ipconfig /flushdns | Out-Null
    Write-Host "  IPv6 -> ON    (IPv6 direct works; but Google etc. may leak over IPv6 and time out)." -ForegroundColor Yellow
}
foreach ($n in $nics) {
    $on = (Get-NetAdapterBinding -Name $n.Name -ComponentID ms_tcpip6).Enabled
    Write-Host ("    {0,-26} IPv6 = {1}" -f $n.Name, $(if ($on) { 'ON' } else { 'OFF' }))
}
Write-Host ""
