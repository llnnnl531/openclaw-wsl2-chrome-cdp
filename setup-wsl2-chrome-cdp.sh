#!/bin/bash
#
# setup-wsl2-chrome-cdp.sh
# 一键打通 WSL2 → Windows Chrome CDP
# 用法: bash setup-wsl2-chrome-cdp.sh
#
# 前提条件:
#   - Windows 侧: PowerShell 或 CMD
#   - WSL2 侧: openclaw CLI 已安装并配置
#

set -e

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 配置
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
DEBUG_PORT="${DEBUG_PORT:-9333}"
WSL_GATEWAY="${WSL_GATEWAY:-172.29.240.1}"
OPENCLAW_PROFILE="${OPENCLAW_PROFILE:-win11-chrome}"
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 颜色
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERR]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 检测运行环境
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
detect_env() {
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        echo "wsl2"
    else
        echo "linux"
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 步骤 1: Windows 侧 — 启动 Chrome 调试实例
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
windows_start_chrome() {
    log_info "=== 步骤 1/5: Windows — 启动 Chrome 调试实例 ==="

    # 先杀掉现有 Chrome 实例
    log_info "杀掉现有 Chrome..."
    cmd.exe /c "taskkill /F /IM chrome.exe 2>nul" || true
    sleep 3

    # 检查端口是否释放
    CURRENT_PID=$(cmd.exe /c "netstat -ano 2>nul" | grep ":${DEBUG_PORT} " | grep LISTENING | awk '{print $5}' | head -1)
    if [[ -n "$CURRENT_PID" && "$CURRENT_PID" != "0" ]]; then
        log_warn "端口 ${DEBUG_PORT} 被 PID ${CURRENT_PID} 占用，尝试终止..."
        cmd.exe /c "taskkill /F /PID ${CURRENT_PID} 2>nul" || true
        sleep 2
    fi

    # 启动 Chrome
    log_info "启动 Chrome 调试实例 (端口 ${DEBUG_PORT})..."
    cmd.exe /c "start \"\" \"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" --remote-debugging-port=${DEBUG_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=\"%TEMP%\\chrome-debug-profile\" --no-first-run --no-default-browser-check" || true
    sleep 5

    # 验证 Chrome 是否在监听
    local chrome_pid=$(cmd.exe /c "netstat -ano 2>nul" | grep ":${DEBUG_PORT} " | grep "127.0.0.1:${DEBUG_PORT}" | awk '{print $5}' | head -1)
    if [[ -n "$chrome_pid" && "$chrome_pid" != "0" ]]; then
        log_ok "Chrome 已启动，PID: ${chrome_pid}"
    else
        log_error "Chrome 启动失败，请手动检查"
        exit 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 步骤 2: Windows 侧 — 配置 portproxy
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
windows_setup_portproxy() {
    log_info "=== 步骤 2/5: Windows — 配置 portproxy 转发 ==="

    # 检查是否已有 portproxy 规则
    local existing=$(cmd.exe /c "netsh interface portproxy show all 2>nul" | grep "${DEBUG_PORT}" | grep "0.0.0.0" | head -1)
    if [[ -n "$existing" ]]; then
        log_ok "portproxy 规则已存在，跳过"
    else
        log_info "添加 portproxy 规则..."
        cmd.exe /c "netsh interface portproxy add v4tov4 listenport=${DEBUG_PORT} listenaddress=0.0.0.0 connectport=${DEBUG_PORT} connectaddress=127.0.0.1" || true
        log_ok "portproxy 规则已添加"
    fi

    # 配置防火墙
    log_info "放行防火墙..."
    cmd.exe /c "netsh advfirewall firewall show rule name=\"Chrome-Debug-${DEBUG_PORT}\" 2>nul" | grep -q "Chrome-Debug-${DEBUG_PORT}" && \
        log_ok "防火墙规则已存在" || \
        cmd.exe /c "netsh advfirewall firewall add rule name=\"Chrome-Debug-${DEBUG_PORT}\" dir=in action=allow protocol=TCP localport=${DEBUG_PORT}" || true
    log_ok "防火墙已配置"
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 步骤 3: WSL2 侧 — 验证网络连通性
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
wsl2_verify_network() {
    log_info "=== 步骤 3/5: WSL2 — 验证网络连通性 ==="

    # 检测 WSL2 网关
    local wsl_ip=$(ip route show 2>/dev/null | grep default | awk '{print $3}')
    if [[ -z "$wsl_ip" ]]; then
        # 尝试从 Windows 获取
        wsl_ip=$(cmd.exe /c "ipconfig 2>nul" | grep -A3 "vEthernet (WSL" | grep "IPv4" | awk '{print $NF}' | head -1)
    fi
    : "${wsl_ip:=${WSL_GATEWAY}}"

    log_info "WSL2 网关: ${wsl_ip}"

    # 测试连通性
    if timeout 5 bash -c "curl -s --connect-timeout 3 http://${wsl_ip}:${DEBUG_PORT}/json/version" > /dev/null 2>&1; then
        log_ok "Chrome CDP 端口已通!"
        curl -s --connect-timeout 3 "http://${wsl_ip}:${DEBUG_PORT}/json/version" | grep -o '"Browser":[^,]*' || true
    else
        log_error "无法连接到 Chrome CDP，检查端口是否正确"
        log_info "尝试直接连接 Chrome..."
        timeout 5 bash -c "curl -s --connect-timeout 3 http://127.0.0.1:${DEBUG_PORT}/json/version" > /dev/null 2>&1 && \
            log_warn "Chrome 在 127.0.0.1:${DEBUG_PORT} 可达，但 WSL2 无法访问——检查 portproxy 配置" || \
            log_error "Chrome 在本地也无法访问"
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 步骤 4: WSL2 侧 — 配置 OpenClaw browser profile
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
wsl2_config_openclaw() {
    log_info "=== 步骤 4/5: WSL2 — 配置 OpenClaw browser profile ==="

    local wsl_ip="${WSL_GATEWAY}"
    local cdp_url="http://${wsl_ip}:${DEBUG_PORT}"

    log_info "CDP URL: ${cdp_url}"

    # 备份原配置
    if [[ -f "$OPENCLAW_JSON" ]]; then
        cp "$OPENCLAW_JSON" "${OPENCLAW_JSON}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "已备份原配置"
    fi

    # 使用 python3 修改配置
    python3 << EOF
import json
import os

config_path = os.path.expanduser("${OPENCLAW_JSON}")

with open(config_path, 'r', encoding='utf-8') as f:
    config = json.load(f)

# 确保 browser 配置存在
if 'browser' not in config:
    config['browser'] = {}
if 'profiles' not in config['browser']:
    config['browser']['profiles'] = {}

# 更新 profile
config['browser']['profiles']['${OPENCLAW_PROFILE}'] = {
    'cdpUrl': '${cdp_url}',
    'attachOnly': True,
    'color': '#00AA00'
}
config['browser']['defaultProfile'] = '${OPENCLAW_PROFILE}'
config['browser']['attachOnly'] = True
config['browser']['enabled'] = True

with open(config_path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print("OPENCLAW_JSON_UPDATED")
EOF

    local result=$?
    if [[ $result -eq 0 ]]; then
        log_ok "OpenClaw 配置已更新"
    else
        log_error "OpenClaw 配置更新失败"
        exit 1
    fi

    # 显示配置
    python3 -c "
import json
with open('${OPENCLAW_JSON}', 'r') as f:
    c = json.load(f)
profile = c.get('browser', {}).get('profiles', {}).get('${OPENCLAW_PROFILE}', {})
print(json.dumps(profile, indent=2))
"
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 步骤 5: WSL2 侧 — 重启 OpenClaw 并验证
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
wsl2_restart_and_verify() {
    log_info "=== 步骤 5/5: WSL2 — 重启 OpenClaw 并验证 ==="

    log_info "重启 OpenClaw gateway..."
    openclaw gateway stop 2>/dev/null || true
    sleep 2
    openclaw gateway start 2>/dev/null || true
    sleep 5

    log_info "等待 gateway 就绪..."
    local retries=10
    while [[ $retries -gt 0 ]]; do
        if curl -s --connect-timeout 2 http://127.0.0.1:18789/health > /dev/null 2>&1; then
            break
        fi
        sleep 1
        ((retries--))
    done

    if [[ $retries -eq 0 ]]; then
        log_error "OpenClaw gateway 启动失败"
        exit 1
    fi
    log_ok "Gateway 已就绪"

    # 等待 browser 初始化
    sleep 3

    log_info "验证 browser 连接..."
    local status=$(openclaw browser status --profile "${OPENCLAW_PROFILE}" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    r = data.get('running', False)
    cdp = data.get('cdpReady', False)
    url = data.get('cdpUrl', '')
    print(json.dumps({'running': r, 'cdpReady': cdp, 'cdpUrl': url}))
except:
    print(json.dumps({'error': True}))
" 2>/dev/null)

    echo "$status" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d.get('error'):
        print('  状态查询失败，请手动检查')
    else:
        print(f\"  running: {d.get('running')}\")
        print(f\"  cdpReady: {d.get('cdpReady')}\")
        print(f\"  cdpUrl: {d.get('cdpUrl')}\")
except:
    print('  解析状态失败')
"

    if echo "$status" | grep -q '"running": true'; then
        log_ok "🎉 全部完成！WSL2 已成功控制 Windows Chrome"
        echo ""
        echo "  访问地址: http://${WSL_GATEWAY}:${DEBUG_PORT}"
        echo "  OpenClaw profile: ${OPENCLAW_PROFILE}"
        echo ""
        echo "  常用命令:"
        echo "    openclaw browser screenshot --profile ${OPENCLAW_PROFILE}"
        echo "    openclaw browser status --profile ${OPENCLAW_PROFILE}"
    else
        log_error "browser 连接未就绪，请查看上方日志"
        exit 1
    fi
}

#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 主流程
#━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
main() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  WSL2 → Windows Chrome CDP 一键部署"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  调试端口: ${DEBUG_PORT}"
    echo "  WSL2 网关: ${WSL_GATEWAY}"
    echo "  OpenClaw profile: ${OPENCLAW_PROFILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # 确认在 WSL2 环境
    local env=$(detect_env)
    if [[ "$env" != "wsl2" ]]; then
        log_error "此脚本需要在 WSL2 环境中运行"
        exit 1
    fi

    log_info "检测到 WSL2 环境，开始部署..."

    windows_start_chrome
    windows_setup_portproxy
    wsl2_verify_network
    wsl2_config_openclaw
    wsl2_restart_and_verify
}

main "$@"
