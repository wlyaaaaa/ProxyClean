# Show IPv6 binding state per active adapter and reported IPv6 default routes.
$ErrorActionPreference = 'SilentlyContinue'
Write-Host ""
Write-Host "  IPv6 Status" -ForegroundColor Cyan
Write-Host "  --------------------------------------"
Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object Name | ForEach-Object {
    $on  = (Get-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6).Enabled
    $txt = if ($on -eq $true) { 'ON ' } elseif ($on -eq $false) { 'OFF' } else { 'UNKNOWN' }
    $col = 'Cyan'
    Write-Host ("    {0,-26} IPv6 = {1}" -f $_.Name, $txt) -ForegroundColor $col
}
Write-Host ""
if (Get-NetRoute -DestinationPrefix '::/0') {
    Write-Host "  IPv6 default route (::/0): PRESENT" -ForegroundColor Cyan
} else {
    Write-Host "  IPv6 default route (::/0): none reported" -ForegroundColor Cyan
}
Write-Host "  Proxy use and Internet reachability: not tested."
Write-Host ""
