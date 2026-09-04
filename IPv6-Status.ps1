# Show IPv6 ON/OFF per active adapter, and whether IPv6 has an internet default route.
$ErrorActionPreference = 'SilentlyContinue'
Write-Host ""
Write-Host "  IPv6 Status" -ForegroundColor Cyan
Write-Host "  --------------------------------------"
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object Name | ForEach-Object {
    $on  = (Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6).Enabled
    $txt = if ($on) { 'ON ' } else { 'OFF' }
    $col = if ($on) { 'Yellow' } else { 'Green' }
    Write-Host ("    {0,-26} IPv6 = {1}" -f $_.Name, $txt) -ForegroundColor $col
}
Write-Host ""
if (Get-NetRoute -DestinationPrefix '::/0') {
    Write-Host "  Internet IPv6 route (::/0): YES  -> apps may use IPv6 (Google etc. can leak)" -ForegroundColor Yellow
} else {
    Write-Host "  Internet IPv6 route (::/0): NONE -> everything uses IPv4 (via proxy)" -ForegroundColor Green
}
Write-Host ""
