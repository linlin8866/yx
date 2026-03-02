cat > /root/warp-auto-ip.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# ========== 配置项 ==========
WARP_CMD="warp"
CHECK_INTERVAL=600        # 10分钟检测一次
DAILY_HOUR=1              # 每天1点强制更换
LOG_FILE="/var/log/warp-auto-ip.log"
SERVICE_FILE="/etc/systemd/system/warp-auto-ip.service"
SOCKS5_PROXY="127.0.0.1:40001"

# ========== 颜色输出 ==========
RED="\033[31m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${CYAN}$*${RESET}"
}

# ========== 检测 IP 是否可用 ==========
check_ip() {
    curl --socks5 $SOCKS5_PROXY -m 10 -s https://www.gstatic.com/generate_204 >/dev/null 2>&1
}

# ========== 检测 Netflix 是否解锁 ==========
check_nf() {
    local result
    result=$(curl --socks5 $SOCKS5_PROXY -m 15 -sL "https://api.ip.sb/geoip" 2>/dev/null || echo "error")
    if echo "$result" | grep -E '"country"' >/dev/null; then
        return 0
    else
        return 1
    fi
}

# ========== 优选优质IP（可NF、可用、不限制国家） ==========
select_best_ip() {
    log "开始优选 可解锁Netflix 的优质IP..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        $WARP_CMD n >/dev/null 2>&1
        sleep 4

        if check_ip && check_nf; then
            local ip
            ip=$(curl --socks5 $SOCKS5_PROXY -m 8 -s https://api.ip.sb/ip 2>/dev/null || echo "获取失败")
            local country
            country=$(curl --socks5 $SOCKS5_PROXY -m 8 -s https://api.ip.sb/geoip 2>/dev/null | grep -o '"country":"[^"]*' | cut -d'"' -f4 || echo "unknown")
            log "✅ 优选成功 IP: $ip 国家: $country"
            systemctl restart sing-box >/dev/null 2>&1
            log "已重启 sing-box 使新IP生效"
            return 0
        else
            log "❌ 第 $attempt 次：IP不可用或NF未解锁，重新更换"
            attempt=$((attempt+1))
            sleep 2
        fi
    done

    log "⚠️  多次尝试未找到最优IP，继续使用当前IP"
    return 1
}

# ========== 开机自动优选 ==========
boot_select() {
    log "🟢 开机自动执行优选IP"
    select_best_ip
}

# ========== 守护进程 ==========
daemon() {
    log "=== WARP 自动优选IP守护已启动 ==="
    log "检测间隔：每10分钟 | 每日更换：1点 | 自动NF检测"

    while true; do
        local hour=$(date +%H)
        local flag="/tmp/warp_daily.flag"

        # 每日1点强制更换
        if [ "$hour" -eq "$DAILY_HOUR" ] && [ ! -f "$flag" ]; then
            log "⏰ 每日定时更换优质IP"
            select_best_ip
            touch "$flag"
        elif [ "$hour" -ne "$DAILY_HOUR" ] && [ -f "$flag" ]; then
            rm -f "$flag"
        fi

        # 检测IP+NF是否正常
        if check_ip && check_nf; then
            log "🔍 IP正常、NF解锁正常"
        else
            log "🔴 IP失效或NF不可用，自动重新优选"
            select_best_ip
        fi

        sleep $CHECK_INTERVAL
    done
}

# ========== 安装开机服务 ==========
install_service() {
    cat > "$SERVICE_FILE" << EOF_SERVICE
[Unit]
Description=WARP 自动优选IP(含NF检测)
After=network-online.target wireproxy.service sing-box.service
Wants=network-online.target wireproxy.service sing-box.service

[Service]
Type=simple
ExecStart=/root/warp-auto-ip.sh daemon
Restart=always
RestartSec=5
User=root
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod +x "$0"
    systemctl daemon-reload
    systemctl enable --now warp-auto-ip
    log "✅ 服务已安装并开机自启"
}

# ========== 主入口 ==========
case "${1:-}" in
    daemon)
        daemon
        ;;
    select)
        select_best_ip
        ;;
    boot)
        boot_select
        ;;
    *)
        install_service
        log "=== 首次运行：自动优选IP ==="
        select_best_ip
        log "=== 部署完成 ==="
        log "查看状态：systemctl status warp-auto-ip"
        log "查看日志：tail -f $LOG_FILE"
        log "手动换IP：/root/warp-auto-ip.sh select"
        ;;
esac
EOF

chmod +x /root/warp-auto-ip.sh && /root/warp-auto-ip.sh
