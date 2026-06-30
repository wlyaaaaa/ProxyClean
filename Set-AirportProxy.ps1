# Point HTTP_PROXY/HTTPS_PROXY at the currently-running airport (FlyingBird 7892,
# ClashVerge 7897, or TAG 7890),
# so env-only apps (Antigravity / Go / git / curl / Node) use the LIVE proxy.
# Clears them if no airport is up. No admin needed (User-level env). Restart the app afterwards.

$ports   = [ordered]@{ 'FlyingBird(飞鸟)' = 7892; 'ClashVerge' = 7897; 'TAG' = 7890 }
$vars    = 'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'

# ── Helper functions for fast registry set + non-blocking broadcast ──
$User32Sig = @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd,
    uint Msg,
    System.IntPtr wParam,
    string lParam,
    uint fuFlags,
    uint uTimeout,
    out System.IntPtr lpdwResult
);
'@

if (-not ([System.Management.Automation.PSTypeName]'User32.NativeMethods').Type) {
    Add-Type -Namespace User32 -Name NativeMethods -MemberDefinition $User32Sig
}

function Set-UserEnvFast([string]$name, [string]$value){
    $regPath = "HKCU:\Environment"
    if ($value -eq $null -or $value -eq "") {
        if (Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
        }
    } else {
        Set-ItemProperty -Path $regPath -Name $name -Value $value -Type String
    }
}

function Broadcast-EnvChange(){
    $result = [IntPtr]::Zero
    # HWND_BROADCAST = 0xffff, WM_SETTINGCHANGE = 0x001A, SMTO_ABORTIFHUNG = 0x0002, timeout = 200ms
    [User32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, "Environment", 2, 200, [ref]$result) | Out-Null
}

$live = $null; $liveName = $null
$listeners = try { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() } catch { $null }
foreach($k in $ports.Keys){
    $p = $ports[$k]
    $isAlive = $false
    if($listeners){
        $isAlive = [bool]($listeners | Where-Object { $_.Port -eq $p })
    } else {
        $isAlive = [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
    }
    if($isAlive){
        $live = $p; $liveName = $k; break
    }
}

Write-Host ""
if($live){
    $p = "http://127.0.0.1:$live"
    $vars | ForEach-Object { Set-UserEnvFast $_ $p }
    Broadcast-EnvChange
    Write-Host ("Conclusion: command-line env proxy now points to {0} ({1})." -f $p, $liveName) -ForegroundColor Green
    Write-Host "Details:" -ForegroundColor White
    Write-Host ("  env proxy  ->  {0}   ({1} is running)" -f $p, $liveName) -ForegroundColor Green
    Write-Host "  >>> RESTART the app (Antigravity / terminal) so it picks up the new value." -ForegroundColor Yellow
} else {
    $vars | ForEach-Object { Set-UserEnvFast $_ $null }
    Broadcast-EnvChange
    Write-Host "Conclusion: no proxy ports are alive; command-line env proxy was cleared." -ForegroundColor Gray
    Write-Host "Details:" -ForegroundColor White
    Write-Host "  No airport on 7892/7897/7890  ->  cleared env proxy (direct)." -ForegroundColor Gray
}
Write-Host ""
