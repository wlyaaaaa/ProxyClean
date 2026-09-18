# ProxyClean

Windows 代理残留诊断与定向修复工具。诊断、修复预览、配置回读、端口关闭和公网连通分别报告；不把“脚本跑完”当成“所有应用已直连”。

支持 Windows PowerShell 5.1 和 PowerShell 7。批处理优先使用已安装的 PowerShell 7，否则回退到自带的 5.1。不安装常驻代理、后台修复服务或固定转发端口。

## 日常入口

双击 `ProxyClean控制中心.vbs`，或运行：

```powershell
pwsh -NoProfile -STA -File .\ControlCenter.ps1
```

控制中心提供分层诊断、修复预览、执行已预览修复、撤销预览与执行、指定端口关闭预览与执行、管理员窗口。打开窗口不自动修复；关闭窗口不改变网络。改选模式或端口后必须重新预览。

原批处理入口保留。`一键修复网络.bat` 执行默认清理；`恢复直连.bat` 关闭下文列出的手动用户代理设置。三个历史端口快捷方式只针对名称中指定的端口，并检查当前进程是否属于预期客户端；客户端换端口后应选择当前端口，不再按旧端口附带结束整个客户端。

## 命令行

```powershell
# 脱敏诊断，不写日志，不发起公网出口探测。
pwsh -NoProfile -File .\ProxyStatus.ps1 -SkipExitProbe -Json

# 修复预览不写配置、不产生撤销文件。
pwsh -NoProfile -File .\ProxyClean.ps1 -Preview -Json

# 默认清理失效本地端点，保留远程、存活和未知配置。
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

每轮可撤销操作在效果前持久化：`%LOCALAPPDATA%\ProxyClean\last-operation.dpapi`。代理原值由 Windows 当前用户 DPAPI 保护，不写明文日志。修改前比对预览原值，修改后回读；失败时逆序恢复。外部变化被保留，未完成状态保持 `recovery_required`，不会强制覆盖或清掉记录。

下一次成功清理替换上一轮撤销记录；未完成记录阻止新的配置修改。撤销不恢复已关闭进程、DNS 缓存、网卡重置或其他应用。DPAPI 文件不是跨电脑、跨用户恢复包。无法自动恢复时按 Windows/客户端原生设置处理，不删除日志以伪造完成。

配置状态包括 `applied`、`no_changes`、`failed_rolled_back`、`recovery_required`。失败和不完整操作返回非零退出码；DNS 刷新失败单独返回 2。HTTP 探测、通知和所有应用直连是否已证明保持独立字段。

## 验证

预先安装 Pester 5.7.1 或兼容版本；测试不自动安装依赖。

```powershell
pwsh -NoProfile -File .\ProxyClean.test.ps1
powershell -NoProfile -File .\ProxyClean.test.ps1
pwsh -NoProfile -File .\Test-WifiRebind.ps1
```

测试隔离真实代理、路由和进程效果，覆盖混合配置、地址族、回滚、并发变化、DPAPI、Git 原子写入、断线网卡、进程身份、IPv6 及脱敏。零发现、发现错误和未运行不能算通过。`ControlCenter.ps1 -SelfTest` 只验证窗口构造，不证明用户点击或网络恢复。

历史故障背景保留在 [docs](docs/)，不是当前端口、DNS 或网络状态的权威来源。现行边界见 [SECURITY.md](SECURITY.md)，更新见 [CHANGELOG.md](CHANGELOG.md)。`fallback` 为保留的退役 DIRECT-only 材料，不作为现行默认入口。