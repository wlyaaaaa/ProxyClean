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

`ProxyClean` 是「断开后事后救火」。如果你想**根治**「机场一关,命令行/Electron 就断网」,
用 `fallback/` 里的常驻兜底层。

**根因**:很多人把 `HTTP_PROXY` / 系统代理**焊死**在某个机场端口(如飞鸟 `127.0.0.1:7892`)。
应用只会无脑把流量甩给这个端口,**不会在端口连不上时回退直连**。于是机场一关,端口 `connection refused`,
连国内访问都断 —— 哪怕它根本不需要翻墙。

**做法**:常驻一个 mihomo 实例监听**永不消失**的固定端口 `7899`,所有应用指向它;
它用 `fallback` 组做故障转移:**飞鸟活→走飞鸟、飞鸟关→走 TAG、两个都关→直连**。
它**不开 tun、不接管 DNS**,只是个 HTTP/SOCKS 转发器,分流仍交给机场内核。

| 文件 | 作用 |
|------|------|
| `fallback/config.yaml` | 兜底 mihomo 配置:`mixed-port: 7899`,`AUTO = fallback[feiniao, tag, DIRECT]` |
| `fallback/start-hidden.vbs` | 无窗口启动器(供开机自启调用) |
| `fallback/代理状态.bat` | 双击查看「现在到底走飞鸟 / TAG / 还是直连」,识破"以为翻墙其实直连"的假象 |

**安装要点**:
1. 把你的 mihomo 内核复制成 `fallback/mihomo.exe`(本仓库**不含** exe,见 `.gitignore`)。
2. 开机自启:`HKCU\...\Run` 加一项 `wscript "…\fallback\start-hidden.vbs"`(无需管理员)。
3. 解焊:把 `HTTP_PROXY/HTTPS_PROXY` 与系统代理从机场端口改指 `127.0.0.1:7899`(`NO_PROXY` 白名单保留)。

**关键提醒**:`mixed-port` 健康检查 URL **必须用国内地址**(本配置用 `http://www.baidu.com`)。
若用 google,机场全关时所有节点连 DIRECT 都被判不健康,fallback 会回退命中死端口 → 又断网。

> ⚠️ 360 / 安全软件可能把 `fallback/mihomo.exe` 当木马删除。务必把 `fallback/` 目录加进**信任区**,
> 否则开机 exe 被删 → 7899 起不来 → 指向 7899 的应用全断。

## License

MIT. 详见 [LICENSE](LICENSE)。
