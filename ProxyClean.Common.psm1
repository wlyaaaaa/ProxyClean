#Requires -Version 5.1
Set-StrictMode -Version 3
$ErrorActionPreference='Stop'
# Resolve the inbox security module from this host, not a parent shell's
# PSModulePath (a PowerShell 7 parent may otherwise expose its Core DLL to 5.1).
Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop

function Get-PCValue {
    param($Object,[string]$Name,$Default=$null)
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]){return $Object.$Name}
    return $Default
}
function ConvertTo-PCArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows native argv quoting; no shell is used by Invoke-PCNative.
    return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-PCNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath,[string[]]$ArgumentList=@(),[int[]]$AllowedExitCodes=@(0),[ValidateRange(1,300)][int]$TimeoutSeconds=20)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$FilePath;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding=New-Object Text.UTF8Encoding($false)
    $info.Arguments=($ArgumentList|ForEach-Object{ConvertTo-PCArgument ([string]$_)}) -join ' '
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw 'Command did not start.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){
            try{if($PSVersionTable.PSEdition -eq 'Core'){$process.Kill($true)}else{$process.Kill()};[void]$process.WaitForExit(3000)}catch{}
            throw 'Command timed out; its raw output was not disclosed.'
        }
        if(-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),3000)){throw 'Command output streams did not close.'}
        if($process.ExitCode -notin $AllowedExitCodes){throw "Command failed (exit $($process.ExitCode)); raw output suppressed."}
        [pscustomobject]@{exit_code=$process.ExitCode;stdout=$stdout.Result;stderr=$stderr.Result}
    }finally{$process.Dispose()}
}
function Get-PCGitPath {
    $command=Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
    if($command){return $command.Source};return $null
}
function Get-PCGitValues {
    param([Parameter(Mandatory)][string]$Key)
    $git=Get-PCGitPath;if(-not $git){throw 'Git is unavailable.'}
    $r=Invoke-PCNative -FilePath $git -ArgumentList @('config','--global','--get-all',$Key) -AllowedExitCodes @(0,1)
    if($r.exit_code -eq 1){return @()}
    return @($r.stdout.TrimEnd([char[]]@("`r","`n")) -split '\r?\n')
}
function Get-ProxyEndpoints {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return @()}
    foreach($part in ($Value -split ';')){
        $raw=$part.Trim();if(-not $raw){continue}
        $mapping=$null;$endpoint=$raw
        if($raw -match '^([a-z][a-z0-9+.-]*)=(.*)$'){$mapping=$Matches[1];$endpoint=$Matches[2].Trim()}
        $candidate=if($endpoint -match '^[a-z][a-z0-9+.-]*://'){$endpoint}else{'http://'+$endpoint}
        [Uri]$uri=$null
        $parsed=[Uri]::TryCreate($candidate,[UriKind]::Absolute,[ref]$uri) -and $uri -and $uri.Host -and $uri.Port -ge 1 -and $uri.Port -le 65535
        $hostName=$null;$local=$false;$family=$null;$address=$null
        if($parsed){
            $hostName=([string]$uri.Host).Trim([char[]]@('[',']'))
            [Net.IPAddress]$ip=$null
            if([Net.IPAddress]::TryParse($hostName,[ref]$ip)){$local=[Net.IPAddress]::IsLoopback($ip);$family=[string]$ip.AddressFamily;$address=$ip.ToString()}
            elseif($hostName.TrimEnd('.') -ieq 'localhost'){$local=$true;$family='localhost'}
        }
        [pscustomobject]@{parsed=[bool]$parsed;local=$local;host=$hostName;port=if($parsed){[int]$uri.Port}else{$null}
            family=$family;address=$address;scheme=if($parsed){$uri.Scheme}else{$null};mapping=$mapping;raw=$raw
            credentials_present=[bool]($parsed -and $uri.UserInfo);parameters_present=[bool]($parsed -and ($uri.Query -or $uri.Fragment))}
    }
}
function Get-LocalProxyPorts {
    param([string]$Value)
    @(Get-ProxyEndpoints $Value|Where-Object{$_.parsed -and $_.local}|Select-Object -ExpandProperty port -Unique)
}
function Get-PCSafeProxyValue {
    param([AllowNull()][string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $parts=@(foreach($e in @(Get-ProxyEndpoints $Value)){
        if(-not $e.parsed){'<configured;unparsed>'}
        else{
            $hostText=if($e.local){if($e.family -eq 'InterNetworkV6'){'['+$e.host+']'}else{$e.host}}else{'<remote>'}
            $prefix=if($e.mapping){$e.mapping+'='}else{''}
            $prefix+$e.scheme+'://'+$hostText+':'+$e.port
        }
    })
    $parts -join ';'
}
function Get-PCListenerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Endpoint,[AllowEmptyCollection()][object[]]$Listeners=@(),[bool]$QuerySucceeded=$true)
    if(-not $QuerySucceeded){return 'unknown'}
    if(-not $Endpoint.parsed){return 'unknown'}
    if(-not $Endpoint.local){return 'remote'}
    $dualStackUnknown=$false
    foreach($row in @($Listeners)){
        if([int]$row.LocalPort -ne [int]$Endpoint.port){continue}
        [Net.IPAddress]$ip=$null
        if(-not [Net.IPAddress]::TryParse([string]$row.LocalAddress,[ref]$ip)){continue}
        $a=$ip.ToString()
        if($Endpoint.family -eq 'localhost'){
            if($a -in @('127.0.0.1','::1','0.0.0.0','::')){return 'listening'}
        }elseif($Endpoint.family -eq 'InterNetwork'){
            if($a -eq $Endpoint.address -or $a -eq '0.0.0.0'){return 'listening'}
            if($a -eq '::'){$dualStackUnknown=$true}
        }elseif($Endpoint.family -eq 'InterNetworkV6'){
            if($a -eq $Endpoint.address -or $a -eq '::'){return 'listening'}
        }
    }
    if($dualStackUnknown){return 'unknown'}
    return 'dead'
}
function Test-LocalProxyDead {
    [CmdletBinding()]
    param([string]$Value,[AllowNull()][object[]]$Listeners=$null,[bool]$QuerySucceeded=$true)
    if(-not $PSBoundParameters.ContainsKey('Listeners')){
        try{$Listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop)}catch{$QuerySucceeded=$false;$Listeners=@()}
    }
    $endpoints=@(Get-ProxyEndpoints $Value)
    if(-not $endpoints.Count){return $false}
    foreach($e in $endpoints){if((Get-PCListenerState -Endpoint $e -Listeners $Listeners -QuerySucceeded $QuerySucceeded) -ne 'dead'){return $false}}
    return $true
}
function Remove-PCProxyEndpoint {
    param([string]$Value,[int]$Port)
    $endpoints=@(Get-ProxyEndpoints $Value)
    if(@($endpoints|Where-Object{-not $_.parsed}).Count){return [pscustomobject]@{changed=$false;value=$Value;reason='unparsed_preserved'}}
    $remaining=@($endpoints|Where-Object{-not ($_.local -and $_.port -eq $Port)})
    [pscustomobject]@{changed=$remaining.Count -ne $endpoints.Count;value=(@($remaining | ForEach-Object { $_.raw }) -join ';');reason='exact_local_endpoint_only'}
}
function Test-PCPhysicalRoute {
    param($Route,[AllowEmptyCollection()][object[]]$Adapters=@())
    $index=Get-PCValue $Route 'InterfaceIndex' (Get-PCValue $Route 'ifIndex')
    $adapter=@($Adapters|Where-Object{(Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $index})
    return $adapter.Count -eq 1 -and (Get-PCValue $adapter[0] 'HardwareInterface') -eq $true -and $adapter[0].Status -eq 'Up' -and
        $Route.DestinationPrefix -eq '0.0.0.0/0' -and $Route.NextHop -and $Route.NextHop -ne '0.0.0.0' -and $Route.NextHop -notmatch '^198\.1[89]\.'
}
function Get-PCWinHttpSnapshot {
    if(-not ('ProxyClean.WinHttp' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ProxyClean {
 [StructLayout(LayoutKind.Sequential)] public struct ProxyInfo { public uint AccessType; public IntPtr Proxy; public IntPtr Bypass; }
 public static class WinHttp {
  [DllImport("winhttp.dll", SetLastError=true)] public static extern bool WinHttpGetDefaultProxyConfiguration(out ProxyInfo info);
  [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr memory);
 }
}
'@
    }
    $info=New-Object ProxyClean.ProxyInfo
    if(-not [ProxyClean.WinHttp]::WinHttpGetDefaultProxyConfiguration([ref]$info)){throw 'WinHTTP configuration unavailable.'}
    try{[pscustomobject]@{mode=if($info.AccessType -eq 1){'direct'}elseif($info.AccessType -eq 3){'named_proxy'}else{'unknown'};proxy=Get-PCSafeProxyValue ([Runtime.InteropServices.Marshal]::PtrToStringUni($info.Proxy))}}
    finally{if($info.Proxy -ne [IntPtr]::Zero){[void][ProxyClean.WinHttp]::GlobalFree($info.Proxy)};if($info.Bypass -ne [IntPtr]::Zero){[void][ProxyClean.WinHttp]::GlobalFree($info.Bypass)}}
}
function Get-PCDockerSnapshot {
    $path=Join-Path $env:APPDATA 'Docker\settings-store.json'
    if(-not(Test-Path -LiteralPath $path)){return [pscustomobject]@{exists=$false;status='not_installed';local_manual_pin_present=$false;runtime_mode='not_inspected'}}
    $settings=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
    $pins=@()
    foreach($section in @(@{mode='ProxyHTTPMode';keys=@('OverrideProxyHTTP','OverrideProxyHTTPS')},@{mode='ContainersProxyHTTPMode';keys=@('ContainersOverrideProxyHTTP','ContainersOverrideProxyHTTPS')})){
        if((Get-PCValue $settings $section.mode) -ne 'manual'){continue}
        foreach($key in $section.keys){$value=[string](Get-PCValue $settings $key);if(@(Get-ProxyEndpoints $value|Where-Object{$_.parsed -and $_.local}).Count){$pins+=@([pscustomobject]@{setting=$key;endpoint=Get-PCSafeProxyValue $value})}}
    }
    $runtime=Get-PCDockerRuntimeSnapshot
    $runtimePin=$runtime.runtime_evidence_current -and $runtime.runtime_mode -eq 'manual' -and $runtime.runtime_local_endpoint
    $systemConfigured=(Get-PCValue $settings 'ProxyHTTPMode') -eq 'system' -and (Get-PCValue $settings 'ContainersProxyHTTPMode') -eq 'system'
    [pscustomobject]@{exists=$true;status='observed';desktop_mode=Get-PCValue $settings 'ProxyHTTPMode';containers_mode=Get-PCValue $settings 'ContainersProxyHTTPMode';local_manual_pin_present=($pins.Count -gt 0 -or [bool]$runtimePin);local_overrides=$pins;runtime_mode=$runtime.runtime_mode;runtime_local_endpoint=$runtime.runtime_local_endpoint;runtime_evidence_current=$runtime.runtime_evidence_current;pending_apply=[bool]($runtimePin -and $systemConfigured)}
}

function Get-PCDockerRuntimeSnapshot {
    $result=[pscustomobject]@{runtime_mode='unknown';runtime_local_endpoint=$null;runtime_evidence_current=$false}
    $processes=@(Get-Process -Name 'Docker Desktop','com.docker.backend' -ErrorAction SilentlyContinue)
    if(-not $processes.Count){$result.runtime_mode='not_running';return $result}
    $path=Join-Path $env:LOCALAPPDATA 'Docker\log\host\httpproxy.log'
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){return $result}
    try {
        $line=@(Get-Content -LiteralPath $path -Tail 300 -ErrorAction Stop|Where-Object {$_ -match 'host will use proxy:'}|Select-Object -Last 1)
        if($line.Count -ne 1){return $result}
        # A recent file mtime does not turn an old mode event into current evidence.
        $dateMatch=[regex]::Match([string]$line[0],'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})')
        [DateTimeOffset]$observed=[DateTimeOffset]::MinValue
        if(-not $dateMatch.Success -or -not [DateTimeOffset]::TryParse($dateMatch.Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$observed)){return $result}
        $age=([DateTimeOffset]::UtcNow-$observed).TotalSeconds
        if($age -lt -5 -or $age -gt 600){return $result}
        $backend=@($processes|Where-Object ProcessName -eq 'com.docker.backend')
        if($backend.Count -and $observed.UtcDateTime -lt ($backend|Sort-Object StartTime|Select-Object -First 1).StartTime.ToUniversalTime()){return $result}
        $mode=if($line[0] -match 'host will use proxy:\s+app settings'){'manual'}elseif($line[0] -match 'host will use proxy:\s+static system'){'system'}elseif($line[0] -match 'host will use proxy:\s+disabled'){'disabled'}else{'unknown'}
        $result.runtime_mode=$mode;$result.runtime_evidence_current=$mode -ne 'unknown'
        $tokens=[regex]::Matches([string]$line[0], '(?i)(?:https?|socks5h?)://[^\s"'',;]+|(?<![\w./@-])(?:127\.0\.0\.1|localhost|\[::1\]):\d{1,5}(?![\d@])')
        foreach($token in $tokens){$e=@(Get-ProxyEndpoints $token.Value);if($e.Count -eq 1 -and $e[0].parsed -and $e[0].local){$result.runtime_local_endpoint=Get-PCSafeProxyValue $token.Value;break}}
    } catch { $result.runtime_mode='unknown';$result.runtime_local_endpoint=$null;$result.runtime_evidence_current=$false }
    return $result
}

function Get-PCListenerCandidates {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Listeners=@(),[AllowEmptyCollection()][object[]]$Endpoints=@())
    $processCache=@{}
    foreach($row in $Listeners){
        $id=[int](Get-PCValue $row 'OwningProcess' 0);if($id -le 0){continue}
        [Net.IPAddress]$ip=$null
        if(-not [Net.IPAddress]::TryParse([string]$row.LocalAddress,[ref]$ip)){continue}
        if(-not ([Net.IPAddress]::IsLoopback($ip) -or $ip.Equals([Net.IPAddress]::Any) -or $ip.Equals([Net.IPAddress]::IPv6Any))){continue}
        if(-not $processCache.ContainsKey($id)){$process=Get-Process -Id $id -ErrorAction SilentlyContinue;$processCache[$id]=if($process){[string]$process.ProcessName}else{''}}
        $name=$processCache[$id]
        $published=@($Endpoints|Where-Object { $_.local -and (Get-PCListenerState -Endpoint $_ -Listeners @($row)) -eq 'listening' }).Count -gt 0
        $recognized=$name -match '(?i)clash|mihomo|sing-box|xray|v2ray|flyingbird|\btag\b|hysteria|tuic|naive|trojan|shadowsocks|sslocal'
        if($published -or $recognized){[pscustomobject]@{port=[int]$row.LocalPort;address=[string]$row.LocalAddress;pid=$id;process=$name;published_by_system_proxy=$published;http_proxy_confirmed=$false}}
    }
}
function Get-PCSnapshot {
    [CmdletBinding()]
    param([switch]$SkipConsumers,[scriptblock]$Progress)
    Write-PCProgress $Progress 'listeners' '正在检查本机代理是否仍在运行…'
    $availability=[ordered]@{}
    $listeners=@();$adapters=@();$routes=@();$proxy=$null;$environment=@();$git=@()
    try{$listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop);$availability.listeners='observed'}catch{$availability.listeners='unknown'}
    Write-PCProgress $Progress 'network' '正在检查网卡与默认连接…'
    try{$adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop);$availability.adapters='observed'}catch{$availability.adapters='unknown'}
    try{$routes=@(Get-NetRoute -PolicyStore ActiveStore -ErrorAction Stop|Where-Object{$_.DestinationPrefix -in @('0.0.0.0/0','::/0')});$availability.routes='observed'}catch{$availability.routes='unknown'}
    Write-PCProgress $Progress 'settings' '正在读取 Windows 代理与终端设置…'
    try{
        $key=Get-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $proxy=[pscustomobject]@{enabled=([int]$key.GetValue('ProxyEnable',0) -eq 1);server=[string]$key.GetValue('ProxyServer','');pac=[string]$key.GetValue('AutoConfigURL','');values=[pscustomobject]@{ProxyEnable=Get-PCRegistryValue -Area WinInet -Name ProxyEnable;ProxyServer=Get-PCRegistryValue -Area WinInet -Name ProxyServer}}
        $availability.wininet='observed'
    }catch{$availability.wininet='unknown'}
    try{
        foreach($scope in 'User','Machine','Process'){foreach($name in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY'){
                        $registry=if($scope -eq 'User'){Get-PCRegistryValue -Area UserEnv -Name $name}else{$null}
            $value=if($scope -eq 'User' -and $registry.exists){[string]$registry.value}else{[Environment]::GetEnvironmentVariable($name,$scope)}
            $environment+=@([pscustomobject]@{name=$name;scope=$scope;value=$value;registry=$registry})
        }};$availability.environment='observed'
    }catch{$availability.environment='unknown'}
    Write-PCProgress $Progress 'git' '正在检查 Git 的代理设置…'
    try{if(Get-PCGitPath){foreach($name in 'http.proxy','https.proxy'){$values=@(Get-PCGitValues $name)
            $target=$null
            if($values.Count){try{$target=Get-PCGitWriteTarget -Key $name}catch{}}
            $git+=@([pscustomobject]@{key=$name;values=$values;target_file=$target;writable=[bool]$target})};$availability.git='observed'}else{$availability.git='not_installed'}}catch{$availability.git='unknown'}
    Write-PCProgress $Progress 'consumers' '正在核对其他应用的代理使用情况…'
    $winhttp=$null;$docker=$null
    if(-not $SkipConsumers){
        try{$winhttp=Get-PCWinHttpSnapshot;$availability.winhttp='observed'}catch{$availability.winhttp='unknown'}
        try{$docker=Get-PCDockerSnapshot;$availability.docker=$docker.status}catch{$availability.docker='unknown'}
    }else{$availability.winhttp='not_inspected';$availability.docker='not_inspected'}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{observedUtc=[DateTimeOffset]::UtcNow.ToString('O');sid=$identity.User.Value;isSystem=$identity.IsSystem;sessionId=(Get-Process -Id $PID).SessionId
        availability=[pscustomobject]$availability;listeners=$listeners;adapters=$adapters;routes=$routes;systemProxy=$proxy;environment=$environment;git=$git;winhttp=$winhttp;docker=$docker}
}
function ConvertTo-PCPublicSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot)
    $proxy=$Snapshot.systemProxy
    $endpoints=if($proxy -and $proxy.enabled){@(Get-ProxyEndpoints $proxy.server)}else{@()}
    $rows=@(foreach($e in $endpoints){[pscustomobject]@{endpoint=Get-PCSafeProxyValue $e.raw;local=$e.local;parsed=$e.parsed;state=Get-PCListenerState $e $Snapshot.listeners ($Snapshot.availability.listeners -eq 'observed')}})
    $routeRows=@(foreach($route in $Snapshot.routes){
        $index=Get-PCValue $route 'InterfaceIndex' (Get-PCValue $route 'ifIndex')
        $ad=@($Snapshot.adapters|Where-Object{(Get-PCValue $_ 'InterfaceIndex' (Get-PCValue $_ 'ifIndex')) -eq $index})
        [pscustomobject]@{interface=[string]$route.InterfaceAlias;interface_index=$index;destination=[string]$route.DestinationPrefix;metric=[int]$route.RouteMetric;adapter_up=($ad.Count -eq 1 -and $ad[0].Status -eq 'Up');fake_ip_gateway=([string]$route.NextHop -match '^198\.1[89]\.');physical_fallback=Test-PCPhysicalRoute $route $Snapshot.adapters}
    })
    $tun=@($routeRows|Where-Object{$_.fake_ip_gateway -and $_.adapter_up})
    [pscustomobject]@{schema='proxyclean.dynamic-status.v1';discovery='exact_endpoint_address_family_and_active_routes';observedUtc=$Snapshot.observedUtc;redacted=$true
        context=@{scope='current_windows_user';system_account=$Snapshot.isSystem;session_id=$Snapshot.sessionId;noninteractive=($Snapshot.sessionId -eq 0)}
        availability=$Snapshot.availability
        listener_candidates=@(Get-PCListenerCandidates -Listeners $Snapshot.listeners -Endpoints @($endpoints))
        conclusion=@{current_default='not_probed';simultaneous_routing_paths=(@($rows|Where-Object state -eq 'listening').Count+$tun.Count) -gt 1;consumer_local_proxy_pin_present=(Get-PCValue $Snapshot.docker 'local_manual_pin_present' $false);network_recovered='not_tested'}
        system_proxy=@{enabled=if($proxy){$proxy.enabled}else{$null};server=if($proxy){Get-PCSafeProxyValue $proxy.server}else{$null};pac_configured=[bool]($proxy -and $proxy.pac);published_local_ports=@($endpoints|Where-Object local|Select-Object -ExpandProperty port -Unique)}
        endpoints=$rows;listeners=@($rows|Where-Object state -eq 'listening');tun_routes=$tun;default_routes=$routeRows
        environment=@($Snapshot.environment|ForEach-Object{[pscustomobject]@{name=$_.name;scope=$_.scope;configured=-not [string]::IsNullOrEmpty($_.value);endpoint=Get-PCSafeProxyValue $_.value}})
        git_proxy=@($Snapshot.git|ForEach-Object{[pscustomobject]@{key=$_.key;values=@($_.values|ForEach-Object{Get-PCSafeProxyValue $_})}})
        winhttp=$Snapshot.winhttp;docker_proxy=$Snapshot.docker;exit_probes=@()
        boundaries=@('A TCP listener is not proof of a working HTTP proxy.','PAC, WinHTTP, machine environment, URL-specific Git and other applications are not silently changed.','Equal exit addresses cannot identify the routing client.','A noninteractive or SYSTEM snapshot is not desktop-user acceptance.')}
}
. (Join-Path $PSScriptRoot 'ProxyClean.Operations.ps1')
. (Join-Path $PSScriptRoot 'ProxyClean.Network.ps1')
. (Join-Path $PSScriptRoot 'ProxyClean.Clients.ps1')
. (Join-Path $PSScriptRoot 'ProxyClean.Workflow.ps1')
Export-ModuleMember -Function '*-PC*','Get-ProxyEndpoints','Get-LocalProxyPorts','Test-LocalProxyDead'
