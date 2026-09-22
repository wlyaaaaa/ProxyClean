# ProxyClean

Windows 代理残留诊断与定向修复工具。诊断、修复预览、配置回读、端口关闭和公网连通分别报告；不把“脚本跑完”当成“所有应用已直连”。

支持 Windows PowerShell 5.1 和 PowerShell 7。批处理优先使用已安装的 PowerShell 7，否则回退到自带的 5.1。不安装常驻代理、后台修复服务或固定转发端口。

## 日常入口

**双击根目录的 `00-打开 ProxyClean.vbs`。** 不用先运行脚本，不用记住端口，也不用一开始就取得管理员权限。请保留完整文件夹，不要只复制入口文件。原 `ProxyClean控制中心.vbs` 仍然可用。

打开后自动进行一次本机只读检查。白底绿色界面直接显示结论：有可修复设置时，列出本次将调整的项目，点击绿色按钮才开始；没有可清理问题时，不制造“必须修复”的提示。存在未完成的恢复记录时，优先处理上次修改。

执行时显示真实的中文步骤：复查、保存原设置、修改、回读核验，以及必要时的恢复。检查在后台工作线程执行，窗口不会等脚本执行完才更新。检查可以取消；修改或恢复中不允许强行关闭窗口，以免停在一半。没有虚构百分比。

“查看检查详情”提供中文结果；“复制脱敏诊断”才复制结构化技术数据。结束程序、手动关闭代理、网卡重启、IPv6、域名缓存和联网出口比较放在“更多操作”，涉及断网或结束进程时先说明影响。结束的是完整进程，不只是一个端口；恢复设置不会复活进程。

入口会检查完整文件，缺失时直接用中文列出缺少的文件；脚本未能启动或异常退出也会显示原因提示，不再只留下看不见的命令窗口。入口只为本次 PowerShell 子进程设置执行策略，不改写系统或用户的永久策略。

所有历史批处理入口现在也先打开这个界面，不再双击即执行网络修改。旧端口快捷方式保留端口和预期客户端核对，端口换了主人就拒绝套用旧选择。主动选择其他程序或手动输入新端口后，必须重新查看结束范围。

GUI 不自动请求公网服务或测试网站。点击“检查联网情况”才请求微软测试网页；“比较联网出口”另行确认后才请求 ipify。测试结果和配置修复结果分别报告。需要修改路由或网卡时才请求管理员权限；新窗口核对是否仍为原 Windows 用户，重新检查，不自动执行变更。

需要管理员权限时，会保留所选操作、网卡、端口和客户端核对。新窗口仍先检查，再等待确认；不会把“启用 IPv6”误带成“重启网卡”。恢复记录包含路由时先请求授权，不在普通窗口中尝试到一半才发现权限不足。

也可以从命令行打开同一界面：

```powershell
pwsh -NoProfile -STA -File .\ControlCenter.ps1
```

## 命令行

```powershell
# 脱敏诊断，不写日志，不发起公网出口探测。
pwsh -NoProfile -File .\ProxyStatus.ps1 -SkipExitProbe -Json

# 修复预览不写配置、不产生撤销文件。
pwsh -NoProfile -File .\ProxyClean.ps1 -Preview -Json

# 默认清理失效本地端点，保留远程、存活和未知配置；不自动刷新 DNS 缓存。
pwsh -NoProfile -File .\ProxyClean.ps1

# 明确关闭手动用户代理，不等于所有应用必然直连。
pwsh -NoProfile -File .\ProxyClean.ps1 -Direct -Preview
pwsh -NoProfile -File .\ProxyClean.ps1 -Direct

# 先看撤销范围，再执行；不会复活已结束的进程。
pwsh -NoProfile -File .\ProxyClean.ps1 -Undo -Preview
pwsh -NoProfile -File .\ProxyClean.ps1 -Undo

# 34567 是示例，不是内置客户端端口。
pwsh -NoProfile -File .\Stop-ProxyPort.ps1 -Port 34567 -Preview
pwsh -NoProfile -File .\Stop-ProxyPort.ps1 -Port 34567

# 诊断默认不落盘，断线或无 IPv4 仍可明确选择网卡。
pwsh -NoProfile -File .\WifiRebind.ps1 -Mode Diagnose -SkipConnectivityChecks -Json
pwsh -NoProfile -File .\WifiRebind.ps1 -Mode SoftReset -InterfaceAlias 'Wi-Fi'
pwsh -NoProfile -File .\WifiRebind.ps1 -Mode AdapterReset -InterfaceAlias 'Wi-Fi'
pwsh -NoProfile -File .\IPv6-Status.ps1
pwsh -NoProfile -File .\IPv6-Toggle.ps1 -WhatIf
```

修改入口支持 `-WhatIf`；关闭端口、网卡重置、IPv6 变更和撤销还要求确认。只有显式给出 `-ExtraProcessName`，关闭端口入口才追加所列客户端进程。不存在默认客户端进程名表；旧端口已关闭也不会导致其他端口的客户端被结束。

`WifiRebind -LogPath <新文件>` 才保存脱敏摘要，不覆盖已有文件。重置会中断选定连接，不应当作远程控制链路的无害测试。静态地址网卡不执行 DHCP 释放/续租；释放失败仍尝试续租，禁用成功后始终尝试重新启用。

## 处理范围

共享模块统一 URI、协议映射、回环地址、IPv4/IPv6 监听和路由分类。仅端口相同、却绑定在局域网地址上的服务，不算 `127.0.0.1` 的存活代理；IPv6 通配监听能否接收 IPv4 不明确时保留 `unknown`。

默认清理只关闭完全指向死本地端点的 WinINET 手动代理、对应用户环境变量和可安全定位的通用全局 Git 代理；从不主动设置端口。`NO_PROXY`、远程代理和混合配置中的其他映射保留。指定端口操作只移除该端点，不触发全机路由清理。

`-Direct` 的范围是手动 WinINET、用户级 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY、可安全定位的通用全局 Git 代理，以及通过物理回退保护的 IPv4 残留默认路由。**PAC、WinHTTP、机器环境变量、URL 专属或含糊来源 Git 配置、Docker 和其他应用不被隐式改写。** 已运行程序可能仍保留旧环境变量，工具不会假装刷新了它们。

路由修改只针对 ActiveStore；删除前再次确认物理回退及目标身份。无法确认健康物理默认路由就不删路由。IPv6 切换只处理明确的物理网卡，保留虚拟/Tailscale 等隧道。绑定状态与公网、代理路径是不同事实。

## 分层诊断

输出包括 WinINET/PAC、分作用域环境变量、Git、WinHTTP、活动 TUN、Docker 配置和可获得的当前运行态。动态客户端监听也会列作候选，但“进程像代理”不代表它每个端口都是 HTTP 代理。Docker 日志只读有界尾部；缺少当前、可解析且属于本次运行的事件就保持未知，不用日志文件更新时间替旧事件续期。

出口比较只给匿名相同出口分组，不公开出口地址；相同出口不证明经过同一个客户端。HTTP 成功也不证明绕过 TUN。SYSTEM/非交互上下文明确标注，不能充当桌面用户验收。

## 撤销与恢复

每轮可撤销操作在效果前持久化：`%LOCALAPPDATA%\ProxyClean\last-operation.dpapi`。代理原值由 Windows 当前用户 DPAPI 保护，不写明文日志。修改前比对预览原值，修改后回读；失败时逆序恢复。默认清理还在写入前再次确认原代理地址没有变化、本机代理端口仍然失效；指定端口清理也会拒绝重新启动的端口。外部变化被保留，未完成状态保持 `recovery_required`，不会强制覆盖或清掉记录。

下一次实际清理会替换上一轮撤销记录；预检发现配置变化或端口重新运行时，不覆盖原记录。未完成记录阻止新的配置修改。撤销不恢复已关闭进程、DNS 缓存、网卡重置或其他应用。DPAPI 文件不是跨电脑、跨用户恢复包。无法自动恢复时按 Windows/客户端原生设置处理，不删除日志以伪造完成。

配置状态包括 `applied`、`no_changes`、`plan_changed`、`failed_rolled_back`、`recovery_required`。失败和不完整操作返回非零退出码；DNS 不再随普通修复自动刷新；CLI 显式给出 `-FlushDns` 才执行，失败单独返回 2。GUI 与 CLI 共用 `Invoke-PCWorkflow`，可分别选择是否测试网页。HTTP 探测、通知和所有应用直连是否已证明保持独立字段。

## 验证

预先安装 Pester 5.7.1 或兼容版本；测试不自动安装依赖。

```powershell
pwsh -NoProfile -File .\ProxyClean.test.ps1
powershell -NoProfile -File .\ProxyClean.test.ps1
pwsh -NoProfile -File .\Test-WifiRebind.ps1
```

测试隔离真实代理、路由和进程效果，覆盖混合配置、地址族、回滚、并发变化、DPAPI、Git 原子写入、断线网卡、进程身份、IPv6 及脱敏。零发现、发现错误和未运行不能算通过。`ControlCenter.ps1 -SelfTest` 只验证窗口构造；`-SmokeTest` 会实际打开窗口、执行只读检查并自动关闭，返回工作线程与中文进度的结果，不证明网络恢复。

历史故障背景保留在 [docs](docs/)，不是当前端口、DNS 或网络状态的权威来源。现行边界见 [SECURITY.md](SECURITY.md)，更新见 [CHANGELOG.md](CHANGELOG.md)。`fallback` 为保留的退役 DIRECT-only 材料，不作为现行默认入口。