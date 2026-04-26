# WSL2 AI Agent 控制 Windows Chrome — 实战总结

> 本项目记录了如何在 WSL2 环境中，让 AI Agent（OpenClaw）通过 CDP（Chrome DevTools Protocol）直接控制 Windows 原生 Chrome 浏览器。
>
> **背景**：WSL2 代码在 Linux，AI 在 WSL2，但浏览器在 Windows——这套环境很常见，但打通 CDP 控制链路并不简单，尤其在 Chrome 136+ 和多网络叠加场景下。

---

## 🎯 最终效果

WSL2 里的 OpenClaw 可以：
- ✅ 截取 Windows Chrome 当前页面截图
- ✅ 打开指定 URL
- ✅ 执行点击、填表等自动化操作
- ✅ 读取浏览器控制台日志

---

## 🚀 一键部署

**推荐方式**：克隆本仓库，在 WSL2 终端里跑一行命令，全部自动搞定。

```bash
# 克隆
git clone https://github.com/llnnnl531/openclaw-wsl2-chrome-cdp.git
cd openclaw-wsl2-chrome-cdp

# 运行一键部署（WSL2 侧）
bash setup-wsl2-chrome-cdp.sh
```

脚本会自动完成：
1. 启动 Windows Chrome 调试实例
2. 配置 Windows portproxy 转发
3. 验证网络连通性
4. 配置 OpenClaw browser profile
5. 重启 OpenClaw gateway 并验证

> 💡 **Windows 侧单独使用**（不想跑 WSL2 脚本）：直接双击 `start-chrome-debug.ps1`，自动完成 Chrome 启动 + portproxy + 防火墙配置。

---

## 🗺️ 网络拓扑

```
┌──────────────────────────────────────────────────────────────┐
│  Windows                                                      │
│                                                                │
│  Chrome (调试实例)                                             │
│  监听：127.0.0.1:9333 (IPv4)                                  │
│                                                                │
│  portproxy: 0.0.0.0:9333 → 127.0.0.1:9333                    │
│                    ↑                                           │
│  防火墙放行 9333/tcp                                          │
└──────────────────────────────────────────────────────────────┘
                          │
                    vEthernet (WSL)
                    172.29.240.1
                          │
┌──────────────────────────────────────────────────────────────┐
│  WSL2 (OpenClaw)                                             │
│                                                                │
│  OpenClaw → http://172.29.240.1:9333/json/version            │
│  ✅ CDP HTTP 协议，WSL2 无需特殊配置                           │
└──────────────────────────────────────────────────────────────┘
```

---

## 🚀 快速部署

### 第一步：Windows — 启动 Chrome 调试实例

在 **Windows PowerShell** 中执行：

```powershell
# 先杀掉所有 Chrome，避免端口冲突
taskkill /F /IM chrome.exe
Start-Sleep -Seconds 3

# 启动调试 Chrome（关键参数缺一不可）
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9333 `
  --remote-debugging-address=127.0.0.1 `
  --user-data-dir="$env:TEMP\chrome-debug-profile" `
  --no-first-run `
  --no-default-browser-check
```

### 第二步：Windows — 配置 portproxy 转发

```powershell
# 添加 IPv4 portproxy 规则（让 WSL2 能访问到）
netsh interface portproxy add v4tov4 `
  listenport=9333 `
  listenaddress=0.0.0.0 `
  connectport=9333 `
  connectaddress=127.0.0.1

# 放行防火墙
netsh advfirewall firewall add rule `
  name="Chrome-Debug-9333" `
  dir=in `
  action=allow `
  protocol=TCP `
  localport=9333
```

> **注意**：如果你习惯用 CMD，把 `$env:TEMP` 换成 `%TEMP%`，PowerShell 参数续行符 `` ` `` 换成 `^`。

### 第三步：WSL2 — 配置 OpenClaw Browser Profile

修改 `~/.openclaw/openclaw.json`，在 `browser.profiles` 中添加：

```json
{
  "browser": {
    "enabled": true,
    "defaultProfile": "win11-chrome",
    "attachOnly": true,
    "profiles": {
      "win11-chrome": {
        "cdpUrl": "http://172.29.240.1:9333",
        "attachOnly": true,
        "color": "#00AA00"
      }
    }
  }
}
```

> ⚠️ **必须去掉 `driver: "existing-session"`**！这个驱动会在 Linux 本地找 DevToolsActivePort 文件，完全忽略 `cdpUrl`。

### 第四步：WSL2 — 重启 OpenClaw

```bash
# 必须完全重启，热重载（SIGUSR1）不能让 browser 配置生效
openclaw gateway stop
openclaw gateway start
```

### 第五步：验证

```bash
# 1. 验证 Chrome CDP 端口
curl http://172.29.240.1:9333/json/version

# 2. 验证 OpenClaw 连接
openclaw browser status --profile win11-chrome
# 预期输出包含: running: true, cdpReady: true, cdpHttp: true

# 3. 截取页面截图（验证完整通路）
openclaw browser screenshot --profile win11-chrome
```

---

## 🕵️ 坑点详解

### 坑1：Chrome 136+ 必须带 `--user-data-dir`

Chrome 136（2025 年上半年）开始，收紧了远程调试端口的规则。**单独使用 `--remote-debugging-port` 不会生效**，必须同时指定一个非默认的 `--user-data-dir`。

```powershell
# ✅ 正确
--user-data-dir="$env:TEMP\chrome-debug-profile"

# ❌ 错误（旧方法，Chrome 136+ 不生效）
--remote-debugging-port=9333
```

### 坑2：Chrome 优先绑定 IPv6，导致 portproxy 失效

即使加了 `--remote-debugging-address=0.0.0.0`，Chrome 仍会优先绑定到 IPv6 `[::1]`，而不是 IPv4 `0.0.0.0`。

Windows portproxy 只支持 **IPv4-to-IPv4** 转发，IPv6 流量不会经过 portproxy，所以 WSL2 访问 `0.0.0.0:9333` 会失败。

**解决方法**：显式指定 `--remote-debugging-address=127.0.0.1`，强制 Chrome 绑定到 IPv4 localhost。

```powershell
--remote-debugging-address=127.0.0.1
```

### 坑3：`driver: existing-session` 完全忽略 `cdpUrl`

OpenClaw browser profile 中，如果设置了 `"driver": "existing-session"`，OpenClaw 会尝试在 Linux 本地路径（`~/.config/google-chrome/DevToolsActivePort`）寻找 Chrome 的调试文件，**完全不读 `cdpUrl` 配置**。

**解决方法**：去掉 `driver` 字段，让 driver 默认为 `openclaw`，通过 HTTP CDP 连接远程 Chrome。

```json
{
  "win11-chrome": {
    "cdpUrl": "http://172.29.240.1:9333",
    "attachOnly": true
    // 不要加 "driver": "existing-session"
  }
}
```

### 坑4：Windows svchost 占着 `0.0.0.0:9222`

有时候 Windows 系统服务（svchost）会占用 `0.0.0.0:9222`，导致 Chrome 无法绑定。

**解决方法**：换用其他端口（如 9333），并配置对应的 portproxy 规则。

### 坑5：WSL2 网络路径（Tailscale / NAT）

如果 WSL2 使用 Tailscale 或其他 VPN，流量可能不经过物理网卡。可以用以下命令确认 WSL2 到 Windows 的实际路由：

```bash
ip route get <目标IP>
# 示例
ip route get 172.29.240.1
```

### 坑6：热重载不生效

修改 `openclaw.json` 后，`openclaw gateway restart`（发送 SIGUSR1 热重载）**不能**让 browser 配置生效。必须：

```bash
openclaw gateway stop
openclaw gateway start
```

---

## 🔧 Windows 一键启动脚本

保存为 `start-chrome-debug.ps1`，双击即可运行：

```powershell
# start-chrome-debug.ps1
taskkill /F /IM chrome.exe
Start-Sleep -Seconds 3

Write-Host "Starting Chrome debug instance on port 9333..."

& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9333 `
  --remote-debugging-address=127.0.0.1 `
  --user-data-dir="$env:TEMP\chrome-debug-profile" `
  --no-first-run `
  --no-default-browser-check

Start-Sleep -Seconds 3

$Listening = Get-NetTCPConnection -LocalPort 9333 -State Listen -ErrorAction SilentlyContinue
if ($Listening) {
    Write-Host "✅ Chrome debug port 9333 is listening!" -ForegroundColor Green
    $Listening | Format-Table LocalAddress,LocalPort,OwningProcess -AutoSize
} else {
    Write-Host "❌ Port 9333 not listening. Chrome may have failed to start." -ForegroundColor Red
}
```

---

## 📊 验证命令汇总

```bash
# WSL2 侧：验证 Chrome CDP HTTP 接口
curl http://172.29.240.1:9333/json/version

# Windows 侧：查看端口监听状态和进程
netstat -ano | findstr :9333

# Windows 侧：查看 portproxy 规则
netsh interface portproxy show all

# Windows 侧：确认 Chrome 进程
Get-Process -Id <PID> | Select-Object ProcessName,Path

# OpenClaw：查看 browser profile 状态
openclaw browser status --profile win11-chrome
```

---

## 📚 参考资料

- [Chrome DevTools Protocol 官方文档](https://chromedevtools.github.io/devtools-protocol/)
- [Chrome 136 远程调试安全变更](https://developer.chrome.com/blog/remote-debugging-port)
- [Microsoft Learn: WSL2 网络](https://learn.microsoft.com/en-us/windows/wsl/networking)
- [Microsoft Learn: .wslconfig 高级配置](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)

---

## 🤝 贡献

如果你也踩过类似的坑，欢迎提交 PR 或 Issue！这个项目的目的是让后来的同学少走弯路。
