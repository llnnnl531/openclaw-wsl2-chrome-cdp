# start-chrome-debug.ps1
# Windows Chrome 调试实例一键启动脚本
# 双击此文件，或右键 → "使用 PowerShell 运行"
#
# 参数（可选）:
#   -DebugPort <端口>    调试端口，默认 9333
#   -SkipFirewall        跳过防火墙配置
#   -Verbose             显示详细日志
#
# 示例:
#   .\start-chrome-debug.ps1 -DebugPort 9333
#   .\start-chrome-debug.ps1 -DebugPort 9222 -SkipFirewall

param(
    [int]$DebugPort = 9333,
    [switch]$SkipFirewall,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Level) {
        "INFO"  { "White" }
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Get-ProcessName {
    param([int]$PID)
    try {
        (Get-Process -Id $PID -ErrorAction SilentlyContinue).ProcessName
    } catch { "Unknown" }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前置检查
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Log "=== Chrome Debug Port 启动脚本 ===" "INFO"
Write-Log "目标端口: $DebugPort" "INFO"

# 检查 Chrome 是否安装
$chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromePath)) {
    $chromePath = "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path $chromePath)) {
    Write-Log "未找到 Chrome 安装路径！" "ERROR"
    Write-Log "请确认 Google Chrome 已正确安装" "ERROR"
    exit 1
}
Write-Log "Chrome 路径: $chromePath" "INFO"

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 杀掉现有 Chrome 实例
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Log "终止所有 Chrome 进程..." "INFO"
$before = Get-Process chrome -ErrorAction SilentlyContinue
taskkill /F /IM chrome.exe 2>$null | Out-Null
Start-Sleep -Seconds 3

# 检查端口占用
Write-Log "检查端口 $DebugPort 占用情况..." "INFO"
$portInfo = Get-NetTCPConnection -LocalPort $DebugPort -State Listen -ErrorAction SilentlyContinue

if ($portInfo) {
    $owningPid = $portInfo.OwningProcess
    $processName = Get-ProcessName -PID $owningPid
    Write-Log "端口 $DebugPort 被 PID $owningPid ($processName) 占用" "WARN"

    if ($processName -eq "svchost" -or $processName -eq "System") {
        Write-Log "占用者是系统服务，尝试终止..." "WARN"
        try {
            Stop-Process -Id $owningPid -Force -ErrorAction Stop
            Write-Log "进程已终止" "OK"
            Start-Sleep -Seconds 2
        } catch {
            Write-Log "无法终止系统进程 (PID $owningPid)，尝试更换端口..." "ERROR"
            # 找一个可用端口
            for ($newPort = 9333; $newPort -le 9999; $newPort++) {
                $test = Get-NetTCPConnection -LocalPort $newPort -State Listen -ErrorAction SilentlyContinue
                if (-not $test) {
                    $DebugPort = $newPort
                    Write-Log "切换到新端口: $DebugPort" "OK"
                    break
                }
            }
        }
    } else {
        Write-Log "终止占用进程 PID $owningPid..." "INFO"
        Stop-Process -Id $owningPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
} else {
    Write-Log "端口 $DebugPort 当前空闲" "OK"
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 启动 Chrome 调试实例
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$userDataDir = "$env:TEMP\chrome-debug-profile-$(Get-Random -Maximum 99999)"
Write-Log "用户数据目录: $userDataDir" "INFO"

Write-Log "启动 Chrome 调试实例..." "INFO"
$chromeArgs = @(
    "--remote-debugging-port=$DebugPort",
    "--remote-debugging-address=127.0.0.1",
    "--user-data-dir=`"$userDataDir`"",
    "--no-first-run",
    "--no-default-browser-check",
    "--no-session-crash-breadcrumbs",
    "--disable-crash-reporter",
    "--disable-extensions"
)

$argString = $chromeArgs -join " "
if ($Verbose) {
    Write-Log "Chrome 启动参数: $argString" "INFO"
}

Start-Process -FilePath $chromePath -ArgumentList $argString -WindowStyle Hidden -PassThru | Out-Null

# 等待 Chrome 完全启动
Write-Log "等待 Chrome 启动 (5秒)..." "INFO"
Start-Sleep -Seconds 5

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 验证 Chrome 监听状态
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$listening = $false
for ($i = 0; $i -lt 5; $i++) {
    $check = Get-NetTCPConnection -LocalPort $DebugPort -State Listen -ErrorAction SilentlyContinue
    if ($check) {
        $listening = $true
        break
    }
    Start-Sleep -Seconds 2
}

if ($listening) {
    $finalCheck = Get-NetTCPConnection -LocalPort $DebugPort -State Listen | Select-Object -First 1
    $procName = Get-ProcessName -PID $finalCheck.OwningProcess
    Write-Log "✅ Chrome 调试端口 $DebugPort 已就绪!" "OK"
    Write-Log "  监听地址: $($finalCheck.LocalAddress):$DebugPort" "OK"
    Write-Log "  进程: $procName (PID: $($finalCheck.OwningProcess))" "OK"
} else {
    Write-Log "⚠️ Chrome 可能未正确启动，端口未监听" "ERROR"
    Write-Log "请手动执行以下命令排查:" "ERROR"
    Write-Log "  & `"$chromePath`" $argString" "ERROR"
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 配置 portproxy
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Log "检查 portproxy 规则..." "INFO"
$existingRule = netsh interface portproxy show all 2>$null | Select-String "^\s+0.0.0.0\s+$DebugPort"

if ($existingRule) {
    Write-Log "portproxy 规则已存在，跳过" "OK"
} else {
    Write-Log "添加 portproxy 规则..." "INFO"
    $err = $null
    netsh interface portproxy add v4tov4 listenport=$DebugPort listenaddress=0.0.0.0 connectport=$DebugPort connectaddress=127.0.0.1 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log "✅ portproxy 规则已添加" "OK"
    } else {
        Write-Log "⚠️ portproxy 配置可能需要管理员权限" "WARN"
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 配置防火墙
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if (-not $SkipFirewall) {
    Write-Log "检查防火墙规则..." "INFO"
    $fwRule = Get-NetFirewallRule -DisplayName "Chrome-Debug-$DebugPort" -ErrorAction SilentlyContinue

    if ($fwRule) {
        Write-Log "防火墙规则已存在" "OK"
    } else {
        Write-Log "添加防火墙入站规则..." "INFO"
        try {
            New-NetFirewallRule -DisplayName "Chrome-Debug-$DebugPort" `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort $DebugPort `
                -Action Allow `
                -Profile Any `
                -ErrorAction Stop | Out-Null
            Write-Log "✅ 防火墙规则已添加" "OK"
        } catch {
            Write-Log "⚠️ 防火墙规则添加失败: $_" "WARN"
            Write-Log "  可手动执行: netsh advfirewall firewall add rule name=`"Chrome-Debug-$DebugPort`" dir=in action=allow protocol=TCP localport=$DebugPort" "WARN"
        }
    }
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 最终验证
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Write-Log ""
Write-Log "=== 验证 ===" "INFO"

# 本地 CDP 测试
try {
    $cdpResponse = Invoke-WebRequest -Uri "http://127.0.0.1:$DebugPort/json/version" `
        -TimeoutSec 5 `
        -UseBasicParsing `
        -ErrorAction Stop
    $browserName = ($cdpResponse.Content | ConvertFrom-Json).Browser
    Write-Log "✅ CDP 接口正常! 浏览器: $browserName" "OK"
} catch {
    Write-Log "⚠️ CDP 接口无法访问: $_" "WARN"
}

# 输出最终状态
Write-Log ""
Write-Log "=== 完成 ===" "OK"
Write-Log "  调试端口: 127.0.0.1:$DebugPort" "OK"
Write-Log "  WSL2 访问: http://172.29.240.1:$DebugPort" "OK"
Write-Log ""
Write-Log "下次使用只需运行: .\start-chrome-debug.ps1" "INFO"
Write-Log "按任意键退出..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
