# ProxyClean

> 一键修复「机场(代理)断开不干净」导致的 Windows 断网问题。
> One-click fix for broken Windows networking left behind when a TUN-based proxy disconnects.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://learn.microsoft.com/powershell/)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

## 这是什么 / What is this

很多基于 **TUN 模式**的代理客户端(飞鸟 FlyingBird、TAG、Clash Verge、各类 clash/mihomo/sing-box 内核)
在**退出或切换机场时清理不干净**。最典型的症状:

- 浏览器还能上网,但 **VS Code / Qoder / ollama / git / npm 等命令行和 Electron 应用全部断网**;
- 关掉代理后**整机彻底没网**,必须重启或重新打开那个代理才恢复;
- 同时装了两个机场,**切换之后网络就乱了**。

根因是断开时残留了**四类垃圾**,任何一类没清,网络就废:

| # | 残留 | 后果 |
|---|------|------|
| 1 | **孤儿 TUN 默认路由** —— 指向已消失的 fake-ip 网关(`198.18.x.x`) | 所有流量被路由进一个已经不存在的隧道 → 黑洞 |
| 2 | **系统代理(WinINET)指向死端口** | 走系统代理的应用(很多桌面软件/浏览器)连不上 |
| 3 | **环境变量指向死端口** —— `HTTP_PROXY` / `HTTPS_PROXY` 还指着关掉的代理端口 | **读环境变量的应用(Qoder、ollama、git、curl、Node)全部断网** |
| 4 | **fake-ip DNS 缓存** | 域名仍解析到 `198.18.x.x`,连不上 |

`ProxyClean` 把这四类残留**一次性清干净,恢复到能正常上网的状态**。它遵循一条铁律:
**只会把"指向死端口"的代理清成直连,绝不主动把系统代理/环境变量/git 焊死到某个会消失的机场端口**
——那正是"机场一关就全断"的根源。在跑的机场,其系统代理交给机场自己维护,本工具不抢。

## 它的原则 / Design principles

- `ProxyClean.ps1` **不杀进程**、**不改任何机场的配置**、**不动 TUN 开关**(TUN 都给你留着);`关闭789*.bat` 是单独的强制关闭工具,只在你明确要关某个客户端时使用。
- **永不主动设置代理**:只把指向**死端口**的系统代理/环境变量/git 清成直连,活的/远程的不碰。
- **清路由带硬保护**:只删 fake-ip 黑洞 / 网卡已 Down 的孤儿路由;**只要当前没有一条健康的物理默认路由,就一条都不删**,绝不会误删 WLAN 把你彻底断网。
- 这正好贴合真实用法:**你用机场自己的界面去连/断,断完之后跑一下本工具把烂摊子收干净。**

## 用法 / Usage

> 改路由表需要**管理员权限**,所以 `.bat` 会自动请求 UAC 提权。

### 最常用:双击批处理

| 文件 | 作用 |
|------|------|
| **`一键修复网络.bat`** | 自动检测在跑的机场并对齐;没有机场则恢复直连。需要管理员权限。**90% 的情况用这个。** |
| **`恢复直连.bat`** | 强制恢复直连(关掉所有代理走本地网络),哪怕还有机场在监听。需要管理员权限。 |
| **`查看当前走哪个.bat`** | 显示 7890/7892/7897 谁在监听、系统代理/环境变量/默认路由,并对比当前默认出口与强制走各端口的出口 IP。 |
| **`关闭7897-ClashVerge.bat`** | 强制结束 `127.0.0.1:7897` 的 Clash Verge/mihomo 核心,同时关闭 `clash-verge` 托盘界面,并清掉指向 7897 的代理残留。需要管理员权限。 |
| **`关闭7892-飞鸟.bat`** | 强制结束 `127.0.0.1:7892` 的飞鸟核心,同时关闭飞鸟界面/服务外壳,并清掉指向 7892 的代理残留。需要管理员权限。 |
| **`关闭7890-TAG.bat`** | 强制结束 `127.0.0.1:7890` 的 TAG/mihomo 核心,同时关闭 TAG 外壳进程,并清掉指向 7890 的代理残留。需要管理员权限。 |

所有脚本输出都按"先结论、后详情"组织。先看顶部的 `Conclusion` / `结论`;下面的表格只是证据和排查细节。

### 命令行 / PowerShell

```powershell
# 自动对齐到当前在跑的机场;没有则恢复直连
powershell -ExecutionPolicy Bypass -File .\ProxyClean.ps1

# 强制恢复直连
powershell -ExecutionPolicy Bypass -File .\ProxyClean.ps1 -Direct

# 查看当前默认出口更像走 7892 还是 7897
powershell -ExecutionPolicy Bypass -File .\ProxyStatus.ps1

# 强制关闭指定端口对应的本地代理进程
powershell -ExecutionPolicy Bypass -File .\Stop-ProxyPort.ps1 -Port 7890 -Label TAG-7890
powershell -ExecutionPolicy Bypass -File .\Stop-ProxyPort.ps1 -Port 7897 -Label ClashVerge-7897
powershell -ExecutionPolicy Bypass -File .\Stop-ProxyPort.ps1 -Port 7892 -Label FlyingBird-7892
```

输出示例:

```
==================== ProxyClean ====================
[*] 检测到在跑的机场:FlyingBird(飞鸟) (127.0.0.1:7892)
[+] 移除孤儿默认路由 via 198.18.0.2 (Meta) —— 网卡已 Down(黑洞)
[*] 代理环境变量本来就是空的(直连)
[*] 系统代理开着且端口可用(127.0.0.1:7892)—— 交给机场客户端维护,保持不动
[+] 已刷新 DNS 缓存
[+] 连通性测试通过 (HTTP 204) via 127.0.0.1:7892
当前默认路由:
接口  网关          RouteMetric
----  ----          -----------
WLAN  192.168.31.1            0
====================================================
```

## 适配你自己的机场 / Adapt to your proxies

脚本顶部有一张机场表,默认内置了 ClashVerge、飞鸟和 TAG。**改成你自己的机场名 + 混合端口(mixed-port)即可**,
顺序就是优先级(从上到下):

```powershell
$Airports = [ordered]@{
    'FlyingBird(飞鸟)' = 7892  # 主梯子
    'ClashVerge'       = 7897  # 次梯子
    'TAG'              = 7890
    # '你的机场'        = 端口号   # ← 照着加
}
```

> 端口填你代理客户端里的 **混合端口 / mixed-port**(HTTP+SOCKS 二合一的那个)。

## 工作原理 / How it works

1. **判定目标**:按优先级探测各机场的混合端口是否在 `LISTEN`;命中第一个即为目标,全没命中则目标为「直连」。
2. **清孤儿路由(带硬保护)**:删掉 ① 网卡已 `Down`/已消失 的黑洞默认路由 ② 直连模式下残留的
   `198.18/198.19` fake-ip 路由。**正在用、网卡 Up 的机场 TUN 路由保留;且只要当前没有一条健康的
   物理默认路由,就一条都不删**——绝不会误删 WLAN/以太网把你彻底断网。
3. **修正代理(只清死端口,绝不焊死)**:系统代理 / 环境变量 / git 只有在**指向已死的本地端口**时
   才被清成直连;指向活端口或远程代理的**保持不动**;`-Direct` 则一律强制直连。
   **本工具永不主动把它们设成某个机场端口。** `NO_PROXY` 白名单始终不动。
4. **刷新 DNS** 并通过 `InternetSetOption` 通知系统代理设置已变更。
5. **验证**:经目标代理(或直连)访问探测地址,打印连通性与最终默认路由。

## 注意 / Notes

- Claude Code / Node / git 的推荐用法是**不要配置任何代理环境变量**。打开 Clash Verge Rev / sing-box / v2rayN 等客户端的 TUN / 虚拟网卡 / Enhanced Mode,让系统底层接管出站流量;终端侧保持直连。
- 如果只是用浏览器完成网页登录,而日常使用 Claude Code / Codex App,浏览器 DNS/WebRTC/时区泄露排查可以先放低优先级;详见 [docs/claude-code-tun-browser-leaks.md](docs/claude-code-tun-browser-leaks.md)。
- 清理用户级环境变量后,对**已经在运行**的进程不生效,**新开**的程序才会读到干净环境。
  若希望 Claude Code / Qoder / 终端立刻生效,重启该程序即可。
- 若提示「机场端口在监听但出口不通」,通常是该机场**额度满 / 节点挂了**——换一个机场,再跑一次本工具。

## ⚠️ 关于 `fallback/`「常驻兜底层」:默认不启用,且不要焊全局

`fallback/` 里有一套"常驻 mihomo 监听固定端口 `7899`、所有应用指向它、它再 fallback 到机场或直连"
的方案,出发点是想**根治**「机场一关,命令行/Electron/Qoder 就连不上」。

**它的致命问题**:这套方案要求你把 `HTTP_PROXY`/系统代理/git **焊死**到 `7899`,并开机自启一个隐藏的
mihomo。可一旦那个隐藏进程没起来(被杀软删 / 没自启 / 崩了),你的全局又焊死在它上面,**整机全断,
比不装还糟**(本项目实测踩过两次)。这正是"把持久设置焊到一个会消失的端口"的典型反例。

**所以现在默认不启用它,也不再提供焊全局 + 自启的步骤。** 真正稳、且永远不会把你弄断网的用法,
就是平时用机场客户端自己连/断,乱了就双击 `一键修复网络.bat`(或 `恢复直连.bat`)收拾干净。

| 文件 | 作用 |
|------|------|
| `fallback/config.yaml` | 兜底 mihomo 配置:`mixed-port: 7899`,`AUTO = fallback[feiniao, clashverge, tag, DIRECT]`,健康检查用国内地址 |
| `fallback/start-hidden.vbs` | 无窗口启动器(供开机自启调用),启动机场自带的 mihomo 内核去读本目录配置 |
| `fallback/代理状态.bat` | 双击查看「现在到底走飞鸟 / TAG / 还是直连」,识破"以为翻墙其实直连"的假象 |

### ⚠️ 最关键的坑:内核 exe 必须用杀软白名单里的那个

360 / AlibabaProtect 会把**突然出现、又被无窗口拉起的代理 exe** 当木马删除。
如果你复制一份**独立** `mihomo.exe` 放进 `fallback/`,它会被秒删 → 7899 起不来 →
全局又焊在死端口 → **全断,比不装还糟**(本项目实测踩过两次)。

**正确做法:直接复用你某个机场客户端自带的、已在白名单里的内核 exe**,只让它读 `fallback/config.yaml`。
本例用 TAG 的内核:

```
"C:\Program Files\TAG\mihomo-tag.exe" -d "C:\Users\<你>\ProxyTools\fallback"
```

这样 `fallback/` 里只剩数据文件(yaml / bat / vbs),没有会被杀的 exe。`start-hidden.vbs` 就是无窗口跑这条命令。

### 为什么不再给出"焊全局 + 开机自启"的安装步骤

旧版这里曾教你:把终端、系统代理和 git 都固定指向兜底层端口,
再开机自启一个隐藏的 mihomo。**这一步就是把你网络搞断的炸弹**:那个隐藏进程一旦没起来
(被杀软删 / 没自启 / 崩了),而你的全局又焊死在它上面,**整机直接全断,比不装还糟**。

这与本项目的安全原则(**绝不把持久设置焊到一个会消失的端口**)直接冲突,因此**已删除该教程**。
`fallback/` 里的文件仅作参考保留;在你没有充分理解并接受上述风险前,**请不要把全局代理焊到 7899**。

> 如果你确实需要"命令行 / Claude Code 也能稳定走代理",优先使用代理客户端的 TUN / 虚拟网卡 / Enhanced Mode,不要给终端焊代理环境变量。

---

## 故障排查:Claude Code / 命令行突然连不上怎么办

> 浏览器(Chat)能用、但 **Claude Code / git / npm / curl** 连不上,几乎都是代理问题。
> 按下面顺序一步步排查,大多数情况一两步就好。

### 一、先理解:推荐用 TUN,不要给终端配置代理环境变量

推荐模型是:

1. 在 Clash Verge Rev / sing-box / v2rayN 等代理客户端里开启 **TUN / 虚拟网卡 / Enhanced Mode**。
2. 代理客户端在系统底层建立虚拟网卡,接管出站流量。
3. Claude Code / Node / git / curl 不设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`、`ANTHROPIC_BASE_URL`。
4. 对终端程序来说,它是在直连官方服务;实际出站路径由 TUN 接管。

浏览器、桌面软件和终端可能仍会受不同配置影响:

| 程序 | 读哪个代理 |
|------|-----------|
| 浏览器 / Chat / Postman / 多数 Electron / Qoder / TAG | 系统代理(WinINET)或客户端自己的代理设置 |
| Claude Code / git / npm / curl / Node | 默认直连;若存在 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`,会被这些变量劫持 |

所以本项目的目标不是给终端"焊代理",而是**清掉死端口、脏环境变量、孤儿路由**,让 TUN 或直连恢复正常。

### 二、一键诊断(整段复制到 PowerShell)

```powershell
"== 环境变量(命令行/Claude Code 读) =="
'HTTP_PROXY','HTTPS_PROXY' | % { "  $_ = $([Environment]::GetEnvironmentVariable($_,'User'))" }
"== 系统代理(浏览器/Qoder/TAG 读) =="
$r='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
"  Enable=$((gp $r).ProxyEnable)  Server=$((gp $r).ProxyServer)"
"== 端口死活(机场 + 兜底层) =="
foreach($p in 7890,7892,7897,7899){ "  $p : $([bool](Get-NetTCPConnection -State Listen -LocalPort $p -EA 0))" }
"== 7890 / 7892 / 7897 当前出口对比 =="
powershell -ExecutionPolicy Bypass -File .\ProxyStatus.ps1
"== 经兜底层 7899 实测 =="
"  国内 = $(curl.exe -s -o NUL -m8 -w '%{http_code}' -x http://127.0.0.1:7899 http://www.baidu.com)"
"  海外 = $(curl.exe -s -o NUL -m12 -w '%{http_code}' -x http://127.0.0.1:7899 https://www.google.com/generate_204)"
```

`200/204` 表示通,`000` 表示连不上。

### 三、对症下药

| 现象 | 原因 | 解决 |
|------|------|------|
| 终端里存在 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` | 旧配置把 Claude Code / Node 劫持到某个端口 | 清空这些环境变量,重开终端;日常依赖 TUN,不要给终端配代理 |
| 环境变量/系统代理都指向活端口,就是连不上 | **终端是旧的**,还揣着改之前的代理值 | **彻底关掉 Claude Code 终端再重开**(环境变量对已运行进程无效) |
| `7899 : False`(没监听) | 兜底层 mihomo 没起来(被杀 / 没自启) | 双击 `fallback/start-hidden.vbs` 拉起;检查 exe 是否被 360 删 |
| 7890 / 7892 / 7897 同时跑,不知道走谁 | 多个 TUN/HTTP 代理同时监听,默认路由和应用代理可能各走各的 | 双击 `查看当前走哪个.bat`;需要只留一个时双击对应的 `关闭789*.bat` |
| 7899 在跑,国内 200、海外 000 | 机场全关,兜底落到直连 | **海外要翻墙至少开一个机场**;开 ClashVerge / 飞鸟 / TAG |
| 7899 国内通、海外不通(开着机场) | 机场节点挂了 / 额度满 | 在机场客户端换个节点 |
| 全局指向 7899,但 7899 = False | exe 被杀,全局焊在死端口 → 全断 | 见下方「应急回退」,再修兜底层 |
| `git push` 报 `Could not connect ... via 127.0.0.1` | git 的 `http.proxy` 指向死端口 | 清掉 git 代理,让 git 走 TUN/直连:`git config --global --unset http.proxy`;`git config --global --unset https.proxy` |
| Postman 等桌面程序连不上 | 缓存了旧的死端口,或被系统代理劫持 | 先**重启该程序**;仍不行就在它自己的 Proxy 设置里关代理 |

### 四、应急回退(30 秒恢复上网)

**管理员 PowerShell** 跑这一段,立刻变直连——国内一切恢复,海外暂时没有:

```powershell
$r='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $r -Name ProxyEnable -Value 0
'HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy' | % { [Environment]::SetEnvironmentVariable($_,$null,'User') }
git config --global --unset http.proxy  2>$null
git config --global --unset https.proxy 2>$null
```

恢复上网后,再从容修 TUN / 节点 / 客户端。**改完都要重开终端。**

### 五、Claude Code 推荐网络方式

- 开代理客户端的 **TUN / 虚拟网卡 / Enhanced Mode**。
- Claude Code 终端里不要设置 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`。
- 不要设置 `ANTHROPIC_BASE_URL` 指向第三方中转,除非你明确知道这会改变服务提供方和信任边界。
- 用 `查看当前走哪个.bat` 判断默认出口像走哪个端口。
- 用 `关闭789*.bat` 只保留一个代理客户端,避免多个 TUN/核心同时抢路由。

### 六、最容易踩的五个坑

1. **不要给 Claude Code 日常配置代理环境变量**——优先用 TUN;环境变量只用于排查脏配置和清理死端口。
2. **别复制独立 `mihomo.exe`**——会被 360 秒删;用机场客户端自带的白名单 exe。
3. **健康检查别用 google**——机场全关时会误判全部不健康,回退到死端口。要用国内地址。
4. **`.bat` 必须 GBK + CRLF 编码**——UTF-8 / LF 会让 cmd 把中文和 URL 拆碎,报 `'xxx' 不是内部或外部命令`。
5. **飞鸟用「智能分流」别用「全局代理」**——全局代理会把国内登录也绕到海外节点,反而更慢/更容易失败。

## License

MIT. 详见 [LICENSE](LICENSE)。
