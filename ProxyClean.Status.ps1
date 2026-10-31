#Requires -Version 5.1
# Local read-only inventory; never returns raw subscriptions or preferences.
function Get-PCStatusValue($Object,[string]$Path) {
    foreach($key in $Path.Split('.')){$Object=Get-PCValue $Object $key};return $Object
}
function Get-PCStatusScalar([string]$Text,[string]$Key) {
    $m=[regex]::Match($Text,'(?m)^'+[regex]::Escape($Key)+':[ \t]*([^\r\n#]+)')
    if($m.Success){return $m.Groups[1].Value.Trim().Trim('"',"'")};return $null
}
function Get-PCStatusPreference($Config,[string]$Path,[string]$Yaml) {
    $state='observed';$value=$null
    if($PSBoundParameters.ContainsKey('Yaml')){
        $found=[regex]::Matches($Yaml,'(?m)^'+[regex]::Escape($Path)+':[ \t]*([^\r\n]*)')
        if(-not $found.Count){$state='missing_field'}elseif($found.Count -ne 1 -or $found[0].Groups[1].Value -notmatch '^(?i:true|false)(?:[ \t]+#.*|[ \t]*)$'){$state='invalid_format'}
        else{$value=$found[0].Groups[1].Value -match '^(?i:true)'}
    }else{
        foreach($key in $Path.Split('.')){
            if($Config -isnot [pscustomobject]){$state='invalid_format';break}
            if(-not $Config.PSObject.Properties[$key]){$state='missing_field';break};$Config=$Config.$key
        }
        if($state -eq 'observed'){if($Config -is [bool]){$value=$Config}else{$state='invalid_format'}}
    }
    [pscustomobject]@{state=$state;value=$value}
}
function Complete-PCStatusPreferences($Saved,[string[]]$TunFields,[string[]]$SystemFields) {
    if($Saved.state -ne 'reading'){return}
    $states=@($Saved.fields.Values|ForEach-Object state)
    $Saved.state=if('invalid_format' -in $states){'invalid_format'}elseif('missing_field' -in $states){'missing_field'}else{'observed'}
    $tun=@($TunFields|ForEach-Object{$Saved.fields[$_].value});$proxy=@($SystemFields|ForEach-Object{$Saved.fields[$_].value})
    $Saved.tun_enabled=if($false -in $tun){$false}elseif($null -notin $tun){$true}else{$null}
    $Saved.system_proxy_enabled=if($true -in $proxy){$true}elseif($null -notin $proxy){$false}else{$null}
}
function Get-PCStatusTarget([string]$UserSid) {
    if(-not $UserSid){return [pscustomobject]@{sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;appdata=$env:APPDATA}}
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$UserSid)
    try{if(-not $key){throw 'User profile not registered.'};$path=[string]$key.GetValue('ProfileImagePath');if(-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)){throw 'User profile unavailable.'};[pscustomobject]@{sid=$UserSid;appdata=(Join-Path $path 'AppData\Roaming')}}finally{if($key){$key.Dispose()}}
}
function Get-PCStatusInstallations([string]$UserSid) {
    foreach($hive in @('LocalMachine',$(if($UserSid){'Users'}else{'CurrentUser'}))){foreach($view in @('Registry64','Registry32')){
        $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey($hive,$view);$key=$base.OpenSubKey($(if($hive -eq 'Users'){$UserSid+'\'})+'Software\Microsoft\Windows\CurrentVersion\Uninstall')
        try{if($key){foreach($name in $key.GetSubKeyNames()){
            $sub=$key.OpenSubKey($name)
            try{$display=[string]$sub.GetValue('DisplayName');if($display -match '飞鸟|FlyingBird|Clash Verge'){
                [pscustomobject]@{name=$display;path=[string]$sub.GetValue('InstallLocation');executable=([string]$sub.GetValue('DisplayIcon') -replace ',\d+$','').Trim('"')}
            }}finally{if($sub){$sub.Dispose()}}
        }}}finally{if($key){$key.Dispose()};$base.Dispose()}
    }}
}
function Get-PCDefaultSnapshot([string]$UserSid) {
    $availability=[ordered]@{listeners='unknown';adapters='unknown';routes='unknown';wininet='unknown';environment='not_inspected';git='not_inspected';winhttp='not_inspected';docker='not_inspected'}
    $adapters=@();$listeners=@();$routes=@();$proxy=$null
    try{$adapters=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|ForEach-Object{
        $ip=$_.GetIPProperties();$index=0;try{$index=$ip.GetIPv4Properties().Index}catch{}
        [pscustomobject]@{Name=$_.Name;InterfaceDescription=$_.Description;Status=$_.OperationalStatus.ToString();InterfaceIndex=$index;addresses=@($ip.UnicastAddresses|ForEach-Object{$_.Address.IPAddressToString})}
    });$availability.adapters='observed'}catch{}
    try{$lines=& "$env:SystemRoot\System32\netstat.exe" -ano -p tcp;if($LASTEXITCODE){throw 'listeners'}
        $listeners=@(foreach($line in $lines){if($line -match '^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$'){
            [pscustomobject]@{LocalAddress=$Matches[1].Trim('[',']');LocalPort=[int]$Matches[2];OwningProcess=[int]$Matches[3]}
        }});$availability.listeners='observed'
    }catch{}
    try{$lines=& "$env:SystemRoot\System32\route.exe" print;if($LASTEXITCODE){throw 'routes'}
        $routes=@(foreach($line in $lines){
            if($line -match '^\s*(0\.0\.0\.0|128\.0\.0\.0)\s+(0\.0\.0\.0|128\.0\.0\.0)\s+(\S+)\s+(\S+)\s+(\d+)\s*$'){
                $destination=$Matches[1]+'/'+$(if($Matches[2] -eq '0.0.0.0'){'0'}else{'1'});$gateway=$Matches[3];$address=$Matches[4];$metric=[int]$Matches[5]
                foreach($adapter in @($adapters|Where-Object{$address -in $_.addresses})){[pscustomobject]@{InterfaceAlias=$adapter.Name;InterfaceIndex=$adapter.InterfaceIndex;DestinationPrefix=$destination;NextHop=$gateway;RouteMetric=$metric}}
            }elseif($line -match '^\s*(\d+)\s+(\d+)\s+(::/0|::/1|8000::/1)\s+(\S+)\s*$'){
                $index=[int]$Matches[1];$metric=[int]$Matches[2];$destination=$Matches[3];$gateway=$Matches[4]
                foreach($adapter in @($adapters|Where-Object InterfaceIndex -eq $index)){[pscustomobject]@{InterfaceAlias=$adapter.Name;InterfaceIndex=$index;DestinationPrefix=$destination;NextHop=$gateway;RouteMetric=$metric}}
            }
        });$availability.routes='observed'
    }catch{}
    $inet=if($UserSid){[Microsoft.Win32.Registry]::Users.OpenSubKey($UserSid+'\Software\Microsoft\Windows\CurrentVersion\Internet Settings')}else{[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Internet Settings')}
    try{if($inet){$proxy=[pscustomobject]@{enabled=($inet.GetValue('ProxyEnable',0) -eq 1);server=[string]$inet.GetValue('ProxyServer','');pac=[string]$inet.GetValue('AutoConfigURL','')};$availability.wininet='observed'}}finally{if($inet){$inet.Dispose()}}
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{observedUtc=[DateTimeOffset]::UtcNow.ToString('o');sid=$identity.User.Value;isSystem=$identity.IsSystem;sessionId=(Get-Process -Id $PID).SessionId;availability=[pscustomobject]$availability;listeners=$listeners;adapters=$adapters;routes=@($routes|Where-Object DestinationPrefix -in @('0.0.0.0/0','::/0'));diagnosticRoutes=$routes;ipInterfaces=@();systemProxy=$proxy;environment=@();git=@();winhttp=$null;docker=$null}
}
function Get-PCStatusProcessQuery { "SELECT ProcessId,Name,ExecutablePath,ParentProcessId,SessionId,CreationDate FROM Win32_Process WHERE Name LIKE 'clash%' OR Name LIKE 'verge-%' OR Name='Apex.exe' OR Name='helper-service.exe' OR Name LIKE 'FlyingBird%' OR Name LIKE 'mihomo%' OR Name LIKE 'tag%' OR Name LIKE '[a-f0-9][a-f0-9]%.exe'" }
function Get-PCClientStatus($Snapshot,[ValidateSet('','TunOnly')][string]$ExpectMode='',[AllowEmptyCollection()][object[]]$Processes,[string]$AppDataPath=$env:APPDATA,[string]$UserSid) {
    $errors=New-Object 'Collections.Generic.List[string]';$groups=@();$installs=@()
    try{if(-not $PSBoundParameters.ContainsKey('Processes')){$Processes=@(Get-CimInstance -Query (Get-PCStatusProcessQuery) -ErrorAction Stop)};$groups=@(Get-PCClientInventory -Processes $Processes -Listeners $Snapshot.listeners -IncludeAllSessions)}catch{$errors.Add('client_processes_unavailable')}
    try{$installs=@(Get-PCStatusInstallations -UserSid $UserSid)}catch{$errors.Add('client_installations_unavailable')}
    if(@($Processes|Where-Object{$_.Name -match '^(Apex|[a-f0-9]{64})\.exe$' -and -not $_.ExecutablePath}).Count){$errors.Add('client_identity_unavailable')}
    $clients=@(foreach($family in @('flyingbird','clash-verge')){
        $bird=$family -eq 'flyingbird';$pattern=if($bird){'飞鸟|FlyingBird'}else{'Clash Verge'}
        $installed=@($installs|Where-Object name -match $pattern);$members=@($groups|Where-Object family_key -eq $family|ForEach-Object{$_.members})
        $gui=@();$core=@();$helpers=@();$settings=[ordered]@{};$names=@($(if($bird){'FlyingBird'}else{'Meta'}))
        $saved=[ordered]@{state='missing_file';tun_enabled=$null;system_proxy_enabled=$null;fields=[ordered]@{}}
        foreach($member in $members){$p=[pscustomobject]@{pid=$member.ProcessId;path=$member.ExecutablePath;name=$member.Name;path_observed=[bool]$member.ExecutablePath}
            if((Test-PCClientBroker $member.Name $member.ExecutablePath) -or $member.Name -ieq 'fb-ai-entry.exe'){$helpers+=@($p)}elseif(Test-PCClientController $member.Name $member.ExecutablePath){$gui+=@($p)}else{$core+=@($p)}
        }
        try{if($bird){
            $path=Join-Path $AppDataPath 'com.fbapp.clients.apex\飞鸟-极速版\shared_preferences.json';$settings.preferences_path=$path;$settings.exists=Test-Path -LiteralPath $path -PathType Leaf
            if(-not $settings.exists -and $installed.Count){$errors.Add('flyingbird_settings_missing')}
            # Legacy FlyingBird identity remains supported; its saved format is not known.
            $legacy=@($members|Where-Object Name -match '^FlyingBird(?:Core|HelperService)?(?:\.exe)?$').Count -gt 0 -or @($installed|Where-Object name -notmatch '飞鸟.*极速|FlyingBird.*Apex').Count -gt 0
            if($legacy){$saved.state='unsupported'}elseif($settings.exists){$saved.state='reading';$wrapper=[IO.File]::ReadAllText($path)|ConvertFrom-Json;$json=Get-PCValue $wrapper 'flutter.config';if($json -isnot [string]){throw 'Unknown preferences format'};$config=$json|ConvertFrom-Json
                foreach($field in @('patchClashConfig.tun.enable','networkProps.systemProxy','vpnProps.enable','vpnProps.systemProxy')){$saved.fields[$field]=Get-PCStatusPreference $config $field;$settings[$field]=$saved.fields[$field].value}
                Complete-PCStatusPreferences $saved @('patchClashConfig.tun.enable','vpnProps.enable') @('networkProps.systemProxy','vpnProps.systemProxy')
                $device=Get-PCStatusValue $config 'patchClashConfig.tun.device';if($device -is [string] -and $device){$names+=@($device);$settings.tun_device=$device}
            }
        }else{
            $roots=@(Get-ChildItem -LiteralPath $AppDataPath -Directory -Filter '*clash*verge*' -ErrorAction Stop|Where-Object{Test-Path -LiteralPath (Join-Path $_.FullName 'verge.yaml')})
            $settings.profiles=@();$settings.rule_files=@();$settings.config_roots=@($roots|ForEach-Object FullName)
            if(-not $roots.Count -and $installed.Count){$errors.Add('clash_settings_missing')}
            if($roots.Count -gt 1){$errors.Add('clash_multiple_config_roots');$saved.state='ambiguous'}
            foreach($root in $roots){$verge=Join-Path $root.FullName 'verge.yaml';$text=[IO.File]::ReadAllText($verge);$settings.verge_path=$verge
                if($roots.Count -eq 1){$saved.state='reading';foreach($field in @('enable_tun_mode','enable_system_proxy')){$saved.fields[$field]=Get-PCStatusPreference -Path $field -Yaml $text;$settings[$field]=$saved.fields[$field].value};Complete-PCStatusPreferences $saved @('enable_tun_mode') @('enable_system_proxy')}
                $runtime=Join-Path $root.FullName 'clash-verge.yaml';$settings.runtime_config_path=$runtime
                if(Test-Path -LiteralPath $runtime){$block=[regex]::Match([IO.File]::ReadAllText($runtime),'(?ms)^tun:\s*\r?\n((?:^[ \t]+[^\r\n]*\r?\n?)+)');$device=Get-PCStatusScalar ($block.Groups[1].Value -replace '(?m)^\s+','') 'device';if($device){$names+=@($device)}}
                $profiles=Join-Path $root.FullName 'profiles.yaml';$settings.profiles_path=$profiles;$text=[IO.File]::ReadAllText($profiles);$current=Get-PCStatusScalar $text 'current'
                $items=@([regex]::Matches($text,'(?ms)^- uid:[ \t]*([\w-]+)[ \t]*\r?\n(.*?)(?=^- uid:|\z)'));$active=@($items|Where-Object{$_.Groups[1].Value -ceq $current})
                if($active.Count -ne 1){$errors.Add('clash_current_profile_unknown')}
                foreach($item in $items){$body=$item.Groups[2].Value -replace '(?m)^  ','';$type=Get-PCStatusScalar $body 'type';$file=Get-PCStatusScalar $body 'file'
                    if($file -notmatch '^[\w.-]+\.(yaml|js)$'){continue};$filePath=Join-Path $root.FullName ('profiles\'+$file)
                    if($item.Groups[1].Value -ceq $current){$name=Get-PCStatusScalar $body 'name';if($name -match '://|[?=&]'){$name='[subscription address omitted]'};$settings.profiles+=@{id=$current;name=$name;path=$filePath}}
                    if($type -in @('rules','merge','script')){$settings.rule_files+=@{id=$item.Groups[1].Value;type=$type;path=$filePath;active=($item.Groups[1].Value -in @('Merge','Script') -or ($active.Count -eq 1 -and $active[0].Groups[2].Value -match ('(?m)^    (rules|merge|script): '+[regex]::Escape($item.Groups[1].Value)+'\s*$')))}}
                }
            }
        }}catch{
            if($saved.state -in @('reading','missing_file')){
                $failure=$_.Exception;while($failure.InnerException){$failure=$failure.InnerException}
                $saved.state=if($failure -is [IO.FileNotFoundException] -or $failure -is [IO.DirectoryNotFoundException] -or $_.CategoryInfo.Category -eq 'ObjectNotFound'){'missing_file'}elseif($failure -is [IO.IOException] -or $failure -is [UnauthorizedAccessException] -or $_.CategoryInfo.Category -in @('PermissionDenied','ReadError','OpenError')){'unavailable'}else{'invalid_format'}
            }
            $errors.Add($family+'_settings_unavailable')
        }
        if($saved.state -ne 'observed' -and ($installed.Count -or $members.Count -or $saved.state -ne 'missing_file')){$errors.Add($family+'_saved_preferences_'+$saved.state)}
        $tun=@($Snapshot.adapters|Where-Object Name -in $names);$ids=@(@($gui)+@($core)|ForEach-Object pid)
        [pscustomobject]@{family=$family;label=$(if($bird){'飞鸟'}else{'Clash'});installed=($installed.Count -gt 0 -or $members.Count -gt 0);installations=$installed;gui=$gui;core=$core;helpers=$helpers;running=($ids.Count -gt 0);tun_adapters=@($tun|Select-Object Name,Status,InterfaceIndex);tun_active=(@($tun|Where-Object Status -eq 'Up').Count -gt 0);listeners=@($Snapshot.listeners|Where-Object OwningProcess -in $ids|Select-Object LocalAddress,LocalPort,OwningProcess);settings=$settings;saved_preferences=$saved}
    })
    $deviations=@();if($ExpectMode -eq 'TunOnly'){
        $tun=@($clients|Where-Object tun_active).Count;$running=@($clients|Where-Object running).Count
        foreach($client in $clients){foreach($check in @(@('saved_tun_disabled',($client.saved_preferences.tun_enabled -eq $false),'保存的 TUN 关闭','开启该客户端保存的 TUN 偏好。'),@('saved_system_proxy_enabled',($client.saved_preferences.system_proxy_enabled -eq $true),'保存的系统代理开启','关闭该客户端保存的系统代理偏好。'))){if($check[1]){$deviations+=@{code=$check[0];family=$client.family;message=$client.label+$check[2];repair=$check[3]}}}}
        foreach($check in @(@('system_proxy_enabled',($Snapshot.systemProxy -and $Snapshot.systemProxy.enabled),'系统代理开着','关闭当前用户系统代理，保留选定客户端 TUN。'),@('no_tun',($Snapshot.availability.adapters -eq 'observed' -and $tun -eq 0),'两家代理都没有开启 TUN','在选定客户端开启 TUN，回读网卡和路由。'),@('dual_tun',($tun -gt 1),'两家代理同时开启 TUN','只保留选定客户端的 TUN，沿客户端正常流程退出另一家。'),@('no_client',(-not $errors.Contains('client_processes_unavailable') -and -not $errors.Contains('client_identity_unavailable') -and $running -eq 0),'两家代理都没运行','启动选定客户端，开启 TUN 并保持系统代理关闭。'))){if($check[1]){$deviations+=@{code=$check[0];message=$check[2];repair=$check[3]}}}
    }
    foreach($key in @('listeners','adapters','routes','wininet')){if($Snapshot.availability.$key -ne 'observed'){$errors.Add($key+'_unavailable')}}
    $status=if($deviations.Count){'deviation'}elseif($errors.Count){'unknown'}else{'pass'}
    $stateLabels=@{observed='';missing_file='缺文件';missing_field='缺字段';invalid_format='格式未知';unsupported='版本未支持';ambiguous='多份配置';unavailable='读取失败'}
    $parts=@(foreach($client in $clients){$run=if($client.running){'运行'}elseif($client.installed){'已装未运行'}else{'未发现安装'};$ports=(@($client.listeners|ForEach-Object LocalPort|Sort-Object -Unique) -join ',');$saved=$client.saved_preferences;$client.label+'='+$run+'/TUN'+$(if($client.tun_active){'开'}else{'关'})+$(if($ports){'/端口'+$ports})+'/保存TUN'+$(if($null -eq $saved.tun_enabled){'未确认'}elseif($saved.tun_enabled){'开'}else{'关'})+'/保存系统代理'+$(if($null -eq $saved.system_proxy_enabled){'未确认'}elseif($saved.system_proxy_enabled){'开'}else{'关'})+$(if($saved.state -ne 'observed'){'('+ $stateLabels[$saved.state]+')'})})
    [pscustomobject]@{client_inventory=$clients;expect_mode=$ExpectMode;status=$status;deviations=$deviations;collection_errors=@($errors);summary=('代理现状：'+($parts -join '；')+'；系统代理'+$(if($Snapshot.availability.wininet -ne 'observed'){'未确认'}elseif($Snapshot.systemProxy.enabled){'开'}else{'关'})+'；'+$(if($status -eq 'unknown'){'部分未核实'}elseif($deviations.Count){'偏离'+$deviations.Count+'项'}elseif($ExpectMode){'符合默认'}else{'未指定期望模式'}))}
}
