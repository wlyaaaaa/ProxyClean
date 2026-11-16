#Requires -Version 5.1
# Explicit website projection; never copies diagnostic objects or recovery payloads.
function Write-PCLiveSnapshot($Status,[string]$AppData,[string]$Output) {
    $at=([datetimeoffset]$Status.observedUtc).ToUniversalTime().ToString('o');$clients=@($Status.client_inventory);$errors=@($Status.collection_errors)
    $processKnown=-not @($errors|Where-Object {$_ -in @('client_processes_unavailable','client_identity_unavailable')}).Count
    $installed=@($clients|Where-Object installed);$running=@($clients|Where-Object running);$tun=@($clients|Where-Object tun_active)
    $installedKnown=$processKnown -and 'client_installations_unavailable' -notin $errors
    $savedKnown=$installedKnown -and -not @($installed|Where-Object {$_.saved_preferences.state -ne 'observed'}).Count
    $metrics=[ordered]@{
        takeover=$(if($Status.availability.adapters -eq 'observed'){if($tun.Count){($tun.label -join '、')+'（TUN 开着）'}else{'未发现活动 TUN'}}else{$null})
        running=$(if($processKnown){[ordered]@{text=([string]$running.Count+' 个'+$(if($running.Count){'（'+($running.label -join '、')+'）'}));count=$running.Count}}else{$null})
        system_proxy=$(if($Status.availability.wininet -eq 'observed'){if($Status.system_proxy.enabled){'开'}else{'关'}}else{$null})
        deviations=$(if($Status.expect_mode -eq 'TunOnly' -and -not $errors.Count){@($Status.deviations).Count}else{$null})
        saved=$(if($savedKnown){[string]@($installed|Where-Object {$_.saved_preferences.tun_enabled -eq $true -and $_.saved_preferences.system_proxy_enabled -eq $false}).Count+'/'+$installed.Count}else{$null})
        undo=$null;close=$null;installed=$(if($installedKnown){[ordered]@{text=([string]$installed.Count+' 个（'+($installed.label -join '、')+'）');count=$installed.Count}}else{$null})
    }
    $details=@($Status.deviations|ForEach-Object {[ordered]@{text=$_.message;state_text='不合习惯'}})
    foreach($client in $clients){foreach($field in @('tun_enabled','system_proxy_enabled')){
        $key=($client.family -replace '-','_')+'_'+$field
        $metrics[$key]=if($client.saved_preferences.state -eq 'observed' -and $null -ne $client.saved_preferences.$field){if($client.saved_preferences.$field){'开'}else{'关'}}else{$null}
    }}
    $history=Join-Path (Split-Path $AppData -Parent) 'Local\ProxyClean'
    $undo=@(foreach($name in @('last-operation.json','last-operation.json.previous','last-operation.dpapi','last-operation.dpapi.previous')){
        $path=Join-Path $history $name;if(Test-Path -LiteralPath $path -PathType Leaf){Get-Item -LiteralPath $path}
    })|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
    if($undo){$metrics.undo=[ordered]@{text=($undo.LastWriteTimeUtc.AddHours(8).ToString('MM-dd HH:mm')+' 留下（北京时间）');at=$undo.LastWriteTimeUtc.ToString('o')}}
    $notes=[ordered]@{undo='没有恢复槽文件；未读取或解密恢复载荷。';close='没有有效关闭阶段记录。'}
    $path=Join-Path $history 'last-close-stage.json'
    if(Test-Path -LiteralPath $path -PathType Leaf){try{
        $stage=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        $time=([datetimeoffset]$stage.time).ToUniversalTime().ToString('o')
        $text=switch($stage.stage){done_failed {'没走完'};done_closed {'已关闭（阶段记录）'};done_repaired {'已修复（非关闭）'};done_cancelled {'已取消'};default {'未记录关闭完成结果'}}
        $metrics.close=[ordered]@{text=($text+'（'+([datetimeoffset]$time).ToOffset([timespan]::FromHours(8)).ToString('MM-dd HH:mm')+'，北京时间）');at=$time;state_text=$text}
    }catch{$notes.close='关闭阶段记录读取失败或时间格式无效。'}}
    # Count only tracked first-party source; snapshots and other generated data are excluded.
    $files=@(& git -C $PSScriptRoot -c core.quotepath=false ls-files);if($LASTEXITCODE){throw 'Tracked source inventory unavailable.'}
    $size=[ordered]@{at=$at;docs_chars=0;code_lines=0;code_chars=0;doc_files=0;code_files=0;tracked_files=$files.Count;doc_words=0}
    foreach($file in $files){$extension=[IO.Path]::GetExtension($file).ToLowerInvariant();$doc=$extension -eq '.md';$code=$extension -in @('.ps1','.psm1','.xaml','.vbs')
        if(-not ($doc -or $code)){continue};$body=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $file));$chars=($body -replace '\s','').Length
        if($doc){$size.docs_chars+=$chars;$size.doc_files++;$size.doc_words+=[regex]::Matches($body,'[\p{IsCJKUnifiedIdeographs}]|[A-Za-z0-9]+').Count}
        else{$size.code_lines+=[regex]::Matches($body,'[^\r\n]*(?:\r\n|\r|\n)|[^\r\n]+$').Count;$size.code_chars+=$chars;$size.code_files++}
    }
    if(Test-Path -LiteralPath $Output -PathType Leaf){$previous=[IO.File]::ReadAllText($Output)|ConvertFrom-Json
        if(-not @($size.Keys|Where-Object {$_ -ne 'at' -and $size[$_] -ne $previous.size.$_}).Count){$size.at=([datetimeoffset]$previous.size.at).ToUniversalTime().ToString('o')}
    }
    foreach($key in @($metrics.Keys)){
        if($null -ne $metrics[$key]){$notes[$key]='仅检查客户端、开关或历史文件；不证明联网、关闭或撤销成功。'}
        elseif(-not $notes.Contains($key)){$notes[$key]='相关状态采集不完整或保存开关未核实；不填零。'}
    }
    if($null -ne $metrics.deviations -and $metrics.deviations -eq 0){$notes.deviations='没有差异；已完整核验，空明细表示没有不合习惯的开关，不是采集故障。'}
    $metrics.repairs=$null;$notes.repairs='从 11 月 17 日起记；以前没有修复摘要，不补造。尚无真实修复摘要。'
    $path=Join-Path $history 'repair-history.json'
    if(Test-Path -LiteralPath $path -PathType Leaf){try{
        $metrics.repairs=@(([IO.File]::ReadAllText($path)|ConvertFrom-Json).items|Select-Object -Last 10|Sort-Object at -Descending|ForEach-Object {
            [ordered]@{at=$_.at;changed=$_.changed;success=$_.success;categories=@($_.categories);text=$(if($null -eq $_.changed){'修复处数未知'}else{'修了 '+$_.changed+' 处'})+'；'+($_.categories -join '、');state_text=$(if($_.success){'设置修复完成'}else{'未完成'})}
        });$notes.repairs='从 11 月 17 日起记；只记设置修复结果，不代表联网成功；失败时处数为回退前已核验改动。'
    }catch{$notes.repairs='修复摘要读取失败；不填零。'}}
    $document=[ordered]@{v=1;at=$at;scope='只读本机客户端、开关及历史文件元数据；未联网实测。';metrics=$metrics;deviation_records=$details;notes=$notes;size=$size;artifacts=@()}
    $full=[IO.Path]::GetFullPath($Output);[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))|Out-Null
    $temporary=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $json="{`n"+(($document.Keys|ForEach-Object {'  "'+$_+'": '+(ConvertTo-Json -InputObject $document[$_] -Depth 8 -Compress)}) -join ",`n")+"`n}`n"
    try{[IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $temporary -Destination $full -Force}
    finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}}
}
