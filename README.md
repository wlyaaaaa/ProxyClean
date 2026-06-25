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

`ProxyClean` 就是把这四类残留一次性清干净,并把系统状态**重新对齐到「当前真正在跑的那个机场」**;
如果一个机场都没开,就**干净地恢复成直连**。

## 它的原则 / Design principles

- **不杀进程**、**不改任何机场的配置**、**不动 TUN 开关**(TUN 都给你留着)。
- 只读取「现在到底哪个机场端口在监听」,据此对齐 **系统代理 / 路由表 / 环境变量 / DNS**。
- 这正好贴合真实用法:**你用机场自己的界面去连/断,断完之后跑一下本工具把烂摊子收干净。**

## 用法 / Usage

> 改路由表需要**管理员权限**,所以 `.bat` 会自动请求 UAC 提权。

### 最常用:双击批处理

| 文件 | 作用 |
|------|------|
| **`一键修复网络.bat`** | 自动检测在跑的机场并对齐;没有机场则恢复直连。**90% 的情况用这个。** |
| **`恢复直连.bat`** | 强制恢复直连(关掉所有代理走本地网络),哪怕还有机场在监听。 |

### 命令行 / PowerShell

```powershell
# 自动对齐到当前在跑的机场;没有则恢复直连
powershell -ExecutionPolicy Bypass -File .\ProxyClean.ps1

# 强制恢复直连
powershell -ExecutionPolicy Bypass -File .\ProxyClean.ps1 -Direct
```

输出示例:

```
==================== ProxyClean ====================
[*] 检测到在跑的机场:FlyingBird(飞鸟) (127.0.0.1:7892)
[+] 移除默认路由 via 198.18.0.2 (Meta) —— 网卡已 Down(黑洞)
[+] 系统代理 + 环境变量 -> http://127.0.0.1:7892
[+] 已刷新 DNS 缓存
[+] 连通性测试通过 (HTTP 204) via 127.0.0.1:7892
当前默认路由:
接口  网关          RouteMetric
----  ----          -----------
WLAN  192.168.31.1            0
====================================================
```

## 适配你自己的机场 / Adapt to your proxies

脚本顶部有一张机场表,默认内置了飞鸟和 TAG。**改成你自己的机场名 + 混合端口(mixed-port)即可**,
顺序就是优先级(从上到下):

```powershell
$Airports = [ordered]@{
    'FlyingBird(飞鸟)' = 7892
    'TAG'              = 7890
    # '你的机场'        = 7897   # ← 照着加
}
```

> 端口填你代理客户端里的 **混合端口 / mixed-port**(HTTP+SOCKS 二合一的那个)。

## 工作原理 / How it works

1. **判定目标**:按优先级探测各机场的混合端口是否在 `LISTEN`;命中第一个即为目标,全没命中则目标为「直连」。
2. **清孤儿路由**:遍历所有 `0.0.0.0/0` 默认路由,删掉 ① 所在网卡已 `Down` 的(黑洞)
   ② 直连模式下指向 `198.18/198.19` fake-ip 网关的。**正在使用且网卡 Up 的机场 TUN 路由会被保留。**
3. **对齐系统代理 + 环境变量**:有目标 → 全部指向 `127.0.0.1:<端口>`;直连 → 关 WinINET 代理并清空
   `HTTP_PROXY/HTTPS_PROXY`。`NO_PROXY` 白名单保持不动。
4. **刷新 DNS** 并通过 `InternetSetOption` 通知系统代理设置已变更。
5. **验证**:经目标代理(或直连)访问探测地址,打印连通性与最终默认路由。

## 注意 / Notes

- 修改环境变量是**用户级持久化**的,对**已经在运行**的进程不生效,**新开**的程序才会读到新值。
  若希望 Qoder / 终端立刻生效,重启该程序即可。
- 若提示「机场端口在监听但出口不通」,通常是该机场**额度满 / 节点挂了**——换一个机场,再跑一次本工具。

## 进阶:常驻兜底层(fallback/) —— 让应用永不被机场端口绑架

`ProxyClean` 是「断开后事后救火」。如果你想**根治**「机场一关,命令行/Electron/Qoder/TAG 就连不上」,
用 `fallback/` 里的常驻兜底层。

**根因**:很多人把 `HTTP_PROXY` / 系统代理**焊死**在某个机场端口(如飞鸟 `127.0.0.1:7892`)。
应用只会无脑把流量甩给这个端口,**不会在端口连不上时回退直连**。于是机场一关,端口 `connection refused`,
连国内访问(比如 TAG / Qoder 的登录服务器)都断 —— 哪怕它根本不需要翻墙。

**做法**:常驻一个 mihomo 实例监听**永不消失**的固定端口 `7899`,所有应用指向它;
它用 `fallback` 组做故障转移:**飞鸟活→走飞鸟、飞鸟关→走 TAG、两个都关→自动直连**。
它**不开 tun、不接管 DNS**,只是个 HTTP/SOCKS 转发器,分流仍交给机场内核。

| 文件 | 作用 |
|------|------|
| `fallback/config.yaml` | 兜底 mihomo 配置:`mixed-port: 7899`,`AUTO = fallback[feiniao, tag, DIRECT]`,健康检查用国内地址 |
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

### 安装步骤(顺序很重要)

1. 改 `config.yaml` 里的端口、`start-hidden.vbs` 里的内核 exe 路径,改成你自己的。
2. 先**手动**双击 `start-hidden.vbs` 启动,用 `代理状态.bat` 确认 7899 在跑、`now` 正确,
   并**放几分钟确认它没被杀**。
3. **确认稳定之后**,才把 `HTTP_PROXY/HTTPS_PROXY` + 系统代理 + git 代理改指 `127.0.0.1:7899`
   (`NO_PROXY` 白名单保留)。**顺序绝不能反**——7899 没验证稳之前别把全局焊上去,否则它一死你就全断。
4. 开机自启:`HKCU\...\Run` 加一项 `wscript "…\fallback\start-hidden.vbs"`(无需管理员)。
5. 把 `fallback/` 目录加进 360 / 杀软信任区(双保险);机场客户端目录也建议加。

> **健康检查 URL 必须用国内地址**(本配置用 `http://www.baidu.com`)。若用 google,
> 机场全关时所有节点连 DIRECT 都被判不健康,fallback 会回退命中死端口 → 又断网。
> 用国内地址只检测「上游端口是否活」,保证全关时 DIRECT 永远健康、干净落到直连。

---

## 故障排查:Claude Code / 命令行突然连不上怎么办

> 浏览器(Chat)能用、但 **Claude Code / git / npm / curl** 连不上,几乎都是代理问题。
> 按下面顺序一步步排查,大多数情况一两步就好。

### 一、先理解:为什么"浏览器能用,命令行不行"

它们读的是**两套不同的代理设置**:

| 程序 | 读哪个代理 |
|------|-----------|
| 浏览器 / Chat / Postman / 多数 Electron / Qoder / TAG | **系统代理(WinINET)** |
| Claude Code / git / npm / curl / Node | **环境变量 `HTTPS_PROXY`**(git 还另读自己的 `http.proxy`) |

所以系统代理对了浏览器就通,但只要**环境变量**指向一个**死端口**,命令行就全断。
反过来也一样。两套要分别检查。

### 二、一键诊断(整段复制到 PowerShell)

```powershell
"== 环境变量(命令行/Claude Code 读) =="
'HTTP_PROXY','HTTPS_PROXY' | % { "  $_ = $([Environment]::GetEnvironmentVariable($_,'User'))" }
"== 系统代理(浏览器/Qoder/TAG 读) =="
$r='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
"  Enable=$((gp $r).ProxyEnable)  Server=$((gp $r).ProxyServer)"
"== 端口死活(机场 + 兜底层) =="
foreach($p in 7890,7892,7899){ "  $p : $([bool](Get-NetTCPConnection -State Listen -LocalPort $p -EA 0))" }
"== 经兜底层 7899 实测 =="
"  国内 = $(curl.exe -s -o NUL -m8 -w '%{http_code}' -x http://127.0.0.1:7899 http://www.baidu.com)"
"  海外 = $(curl.exe -s -o NUL -m12 -w '%{http_code}' -x http://127.0.0.1:7899 https://www.google.com/generate_204)"
```

`200/204` 表示通,`000` 表示连不上。

### 三、对症下药

| 现象 | 原因 | 解决 |
|------|------|------|
| 环境变量/系统代理都指向活端口,就是连不上 | **终端是旧的**,还揣着改之前的代理值 | **彻底关掉 Claude Code 终端再重开**(环境变量对已运行进程无效) |
| `7899 : False`(没监听) | 兜底层 mihomo 没起来(被杀 / 没自启) | 双击 `fallback/start-hidden.vbs` 拉起;检查 exe 是否被 360 删 |
| 7899 在跑,国内 200、海外 000 | 机场全关,兜底落到直连 | **海外要翻墙至少开一个机场**;开飞鸟或 TAG |
| 7899 国内通、海外不通(开着机场) | 机场节点挂了 / 额度满 | 在机场客户端换个节点 |
| 全局指向 7899,但 7899 = False | exe 被杀,全局焊在死端口 → 全断 | 见下方「应急回退」,再修兜底层 |
| `git push` 报 `Could not connect ... via 127.0.0.1` | git 的 `http.proxy` 指向死端口 | 见「手动指回活机场」改 git 代理 |
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

恢复上网后,再从容修兜底层,或用下面那段临时指回活机场。**改完都要重开终端。**

### 五、手动把代理指回某个活机场(临时方案)

假设 TAG(7890) 活着——把 `7890` 换成你在跑的那个机场端口:

```powershell
$P='http://127.0.0.1:7890'
'HTTP_PROXY','HTTPS_PROXY' | % { [Environment]::SetEnvironmentVariable($_,$P,'User') }
$r='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty $r -Name ProxyServer -Value '127.0.0.1:7890'
Set-ItemProperty $r -Name ProxyEnable -Value 1
git config --global http.proxy  $P
git config --global https.proxy $P
```

> 或者直接双击 `一键修复网络.bat`,它会自动对齐系统代理 + 环境变量到在跑的机场(但不改 git,git 需手动)。
> **改完务必重开 Claude Code 终端 / Qoder** 才生效。

### 六、最容易踩的五个坑

1. **环境变量对已运行进程无效**——改了代理一定要重开终端 / Qoder / Postman,否则白改。
2. **别复制独立 `mihomo.exe`**——会被 360 秒删;用机场客户端自带的白名单 exe。
3. **健康检查别用 google**——机场全关时会误判全部不健康,回退到死端口。要用国内地址。
4. **`.bat` 必须 GBK + CRLF 编码**——UTF-8 / LF 会让 cmd 把中文和 URL 拆碎,报 `'xxx' 不是内部或外部命令`。
5. **飞鸟用「智能分流」别用「全局代理」**——全局代理会把国内登录也绕到海外节点,反而更慢/更容易失败。

## License

MIT. 详见 [LICENSE](LICENSE)。
