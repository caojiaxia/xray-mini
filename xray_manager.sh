#!/bin/bash

# 1. 权限检查 (第一时间拦截非 root 用户)
[[ $EUID -ne 0 ]] && echo -e "\033[0;31m错误: 必须使用 root 用户运行此脚本！\033[0m" && exit 1

# ====================================================
# Project: Xray xhttp & CF Tunnel 一键脚本 (修复版)
# Author: BoGe & User (caojiaxia)
# System: Debian/Ubuntu/CentOS/Alpine
# ====================================================

# 颜色和路径定义 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 自动检测架构，确保 cloudflared 下载不报错
detect_arch() {
    case "$(uname -m)" in
        x86_64)  CF_ARCH="amd64"; XRAY_ARCH="64" ;;
        aarch64) CF_ARCH="arm64"; XRAY_ARCH="arm64-v8a" ;;
        armv7l)  CF_ARCH="arm";   XRAY_ARCH="arm32-v7a" ;;
        *)       CF_ARCH="amd64"; XRAY_ARCH="64" ;;
    esac
}

XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_DIRECT="$XRAY_CONF_DIR/conf_1_direct.json"
XRAY_CONF_TUNNEL="$XRAY_CONF_DIR/conf_2_tunnel.json"
CERT_DIR="$XRAY_CONF_DIR/certs"
CF_BIN="/usr/local/bin/cloudflared"
CF_LOG="/tmp/cloudflared.log"

# ====================================================
# [核心兼容层] Alpine (OpenRC) 桥接 Systemctl
# ====================================================
if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
    HAS_SYSTEMD=true
else
    HAS_SYSTEMD=false
    systemctl() {
        local action=$1
        shift
        local service=${1%.service}
        case "$action" in
            start|stop|restart) rc-service "$service" "$action" >/dev/null 2>&1 ;;
            enable) 
                [[ "$1" == "--now" ]] && service=${2%.service}
                rc-update add "$service" default >/dev/null 2>&1 
                [[ "$1" == "--now" ]] && rc-service "$service" start >/dev/null 2>&1
                ;;
            is-active) rc-service "$service" status 2>/dev/null | grep -q "started" ;;
            list-unit-files) ls /etc/init.d/ ;;
            daemon-reload) : ;;
            *) return 0 ;;
        esac
    }
fi

# --- 自动检测网络能力并设置策略 ---
check_network_strategy() {
    echo -e "${BLUE}[进度] 正在精准探测网络环境...${PLAIN}"
    
    local total_mem=$(free -m | awk '/Mem:/ {print $2}')
    strategy="AsIs"
    
    if [ "$total_mem" -lt 512 ]; then
        strategy="AsIs"
        echo -e "${YELLOW}[注意] 检测到内存较小 (${total_mem}MB)，已自动开启低耗能模式。${PLAIN}"
        return 0
    fi

    # 修复核心：采用纯 IPv6 权威检测源，防止双栈 DNS 降级解析
    if curl -6 -s --max-time 5 https://6.ipw.cn > /dev/null 2>&1 || curl -6 -s --max-time 5 https://ipv6.google.com > /dev/null 2>&1; then
        strategy="UseIPv6"
        echo -e "${GREEN}[检测] 环境支持 IPv6，已成功启用 IPv6 优先模式。${PLAIN}"
    elif curl -4 -s --max-time 5 https://4.ipw.cn > /dev/null 2>&1 || curl -4 -s --max-time 5 https://www.google.com > /dev/null 2>&1; then
        strategy="UseIPv4"
        echo -e "${YELLOW}[提醒] 环境不支持 IPv6，已切换至 IPv4 优先模式。${PLAIN}"
    else
        strategy="AsIs"
        echo -e "${PURPLE}[提醒] 无法确认双栈连接性，使用默认解析策略。${PLAIN}"
    fi
}

# ---  自动清理日志与系统垃圾 ---
cleanup_logs() {
    echo -e "${YELLOW}正在执行系统瘦身与日志清理...${PLAIN}"
    
    [[ -f /var/log/xray/access.log ]] && : > /var/log/xray/access.log
    [[ -f /var/log/xray/error.log ]] && : > /var/log/xray/error.log
    [[ -f /tmp/cloudflared.log ]] && : > /tmp/cloudflared.log
    [[ -f "$CF_LOG" ]] && : > "$CF_LOG"
    
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=1d >/dev/null 2>&1
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get autoremove -y >/dev/null 2>&1
        apt-get clean >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum autoremove -y >/dev/null 2>&1
        yum clean all >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk cache clean >/dev/null 2>&1
    fi

    local current_script=$(readlink -f "$0")
    (crontab -l 2>/dev/null | grep -v "cleanup_logs"; echo "0 3 * * 1 $current_script cleanup_logs > /dev/null 2>&1") | crontab -
    
    echo -e "${GREEN}已添加/更新每周一凌晨 3 点自动清理计划任务。${PLAIN}"
    [[ "$1" != "silent" ]] && read -p "按回车键返回菜单..."
}

# --- [ 服务升级与 BBR 维护 ] ---
update_services_bbr() {
    clear
    echo -e "${YELLOW}正在穿透层级检测服务状态...${PLAIN}"
    
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null)
    local xray_bin=$(command -v xray || echo "/usr/local/bin/xray")
    local xray_local=$($xray_bin -version 2>/dev/null | head -n 1 | awk '{print $2}')
    local cf_bin=$(command -v cloudflared || echo "/usr/local/bin/cloudflared")
    local cf_local=$($cf_bin --version 2>/dev/null | awk '{print $3}')

    local xray_remote=$(curl -sL --connect-timeout 5 https://api.github.com/repos/XTLS/Xray-install/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$xray_remote" ]] && xray_remote="[网络波动/获取失败]"
    local cf_remote=$(curl -sL --connect-timeout 5 https://api.github.com/repos/cloudflare/cloudflared/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -z "$cf_remote" ]] && cf_remote="[网络波动/获取失败]"

    echo -e "${PURPLE}======================================================${PLAIN}"
    echo -e "${PURPLE}       服务升级与加速维护                ${PLAIN}"
    echo -e "${PURPLE}======================================================${PLAIN}"
    echo -e "${CYAN} BBR 加速状态 :${PLAIN} $([[ "$current_algo" == "bbr" ]] && echo -e "${GREEN}Running (BBRv1)${PLAIN}" || echo -e "${RED}Not Enabled${PLAIN}")"
    echo -e "${PURPLE}------------------------------------------------------${PLAIN}"
    echo -e "${CYAN} Xray 核心    :${PLAIN} 本地: ${YELLOW}${xray_local:-未安装}${PLAIN} | 最新: ${GREEN}${xray_remote}${PLAIN}"
    echo -e "${CYAN} Cloudflared  :${PLAIN} 本地: ${YELLOW}${cf_local:-未安装}${PLAIN} | 最新: ${GREEN}${cf_remote}${PLAIN}"
    echo -e "${PURPLE}------------------------------------------------------${PLAIN}"

    echo -e " 1. 开启 BBRv1 加速"
    echo -e " 2. 升级 Xray 核心"
    echo -e " 3. 升级 Cloudflared"
    echo -e " 4. 一键执行全部操作 (优化+升级)"
    echo -e " 0. 返回主菜单"
    read -p " 请输入编号 [0-4]: " op_choice

    case "$op_choice" in
        1|4)
            echo -e "${YELLOW}正在应用 BBR 优化配置...${PLAIN}"
            echo "net.core.default_qdisc=fq" > /etc/sysctl.d/99-bbr.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.d/99-bbr.conf
            sysctl --system >/dev/null 2>&1
            [[ "$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')" == "bbr" ]] && echo -e "${GREEN}[生效确认] BBR 已经在运行。${PLAIN}"
            ;;
    esac

    case "$op_choice" in
        2|4)
            echo -e "${YELLOW}正在升级 Xray...${PLAIN}"
            bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
            systemctl daemon-reload
            systemctl restart xray
            sleep 1
            local xray_new=$($xray_bin -version 2>/dev/null | head -n 1 | awk '{print $2}')
            echo -e "${GREEN}[生效确认] Xray 升级完成: ${YELLOW}${xray_local}${PLAIN} -> ${GREEN}${xray_new}${PLAIN}"
            ;;
    esac

    case "$op_choice" in
        3|4)
            echo -e "${YELLOW}正在替换 Cloudflared 二进制文件...${PLAIN}"
            local arch=$(uname -m)
            local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
            [[ "$arch" == "aarch64" ]] && url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
            
            wget -q -O /tmp/cf_tmp "$url" && mv -f /tmp/cf_tmp /usr/local/bin/cloudflared
            chmod +x /usr/local/bin/cloudflared
            
            if systemctl list-unit-files | grep -q "cloudflared"; then
                systemctl daemon-reload
                systemctl restart cloudflared
            fi
            local cf_new=$($cf_bin --version 2>/dev/null | awk '{print $3}')
            echo -e "${GREEN}[生效确认] Cloudflared 升级完成: ${YELLOW}${cf_local}${PLAIN} -> ${GREEN}${cf_new}${PLAIN}"
            ;;
    esac

    [[ "$op_choice" == "0" ]] && return
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  操作结束。所有反馈的版本号均为“实时探测”结果。${PLAIN}"
}

# 统一重启与冲突校验函数
restart_and_check() {
    echo -e "${BLUE}[进度] 正在同步重启服务并进行环境适配...${PLAIN}"
    
    local X_BIN="/usr/local/bin/xray"
    if [[ ! -f "$X_BIN" ]]; then
        echo -e "${RED}[致命错误] Xray 二进制文件未找到。${PLAIN}"
        return 1
    fi

    pkill -9 xray >/dev/null 2>&1
    sleep 1 
    
    if ! "$X_BIN" -test -confdir /usr/local/etc/xray/ >/tmp/xray_err.log 2>&1; then
        echo -e "${RED}[错误] 配置文件校验失败！详细日志：${PLAIN}"
        cat /tmp/xray_err.log
        return 1
    fi

    local started=false
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl restart xray >/dev/null 2>&1
        sleep 1
        pgrep -x "xray" > /dev/null && started=true
    fi

    if [ "$HAS_OPENRC" = true ] && [ "$started" = false ]; then
        rc-service xray restart >/dev/null 2>&1
        sleep 1
        pgrep -x "xray" > /dev/null && started=true
    fi

    # 修复核心：如果系统服务没有跑起来，通过 nohup 守护，并注册系统挂载守护
    if [ "$started" = false ]; then
        nohup "$X_BIN" run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
        sleep 4
        if ps w | grep -v grep | grep -q "xray"; then
            started=true
            # 注入 rc.local 或 crontab 开机启动项，确保重启不失效
            if [[ -f /etc/rc.local ]]; then
                grep -q "xray run" /etc/rc.local || sed -i -e '$i \nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &\n' /etc/rc.local
            fi
        fi
    fi

    if [ "$started" = true ]; then
        echo -e "${GREEN}[成功] Xray 已在当前环境成功启动并确保持久化。${PLAIN}"
        return 0
    else
        echo -e "${RED}[致命错误] 所有启动方式均失败，请检查端口是否被占用。${PLAIN}"
        return 1
    fi
}

# --- 1. 基础环境安装 ---
install_base() {
    echo -e "${YELLOW}正在放行双栈所有端口...${PLAIN}"
    iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT
    iptables -F && iptables -X && iptables -Z
    
    if command -v ip6tables &> /dev/null; then
        ip6tables -P INPUT ACCEPT && ip6tables -P FORWARD ACCEPT && ip6tables -P OUTPUT ACCEPT
        ip6tables -F && ip6tables -X && ip6tables -Z
    fi
    
    if command -v nft &> /dev/null; then
        nft flush ruleset
    fi

    detect_arch
    echo -e "${BLUE}[进度] 正在安装系统基础依赖...${PLAIN}"
    
    if grep -qi "alpine" /etc/os-release; then
        mkdir -p /var/spool/cron/crontabs
        apk update && apk add bash curl wget jq socat cronie openssl tar lsof net-tools libc6-compat gcompat libstdc++ openrc unzip >/dev/null 2>&1
        HAS_OPENRC=true
    elif [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl wget jq socat cron openssl tar lsof net-tools unzip >/dev/null 2>&1
    else
        yum install -y curl wget jq socat crontabs openssl tar lsof net-tools unzip >/dev/null 2>&1
    fi
    
    check_network_strategy
    mkdir -p /usr/local/etc/xray "$CERT_DIR" /usr/local/bin

    if [[ ! -f /usr/local/bin/xray ]]; then
        echo -e "${YELLOW}正在获取最新版 Xray 核心链接...${PLAIN}"
        local latest_ver=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
        local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${XRAY_ARCH}.zip"
        
        echo -e "${YELLOW}正在手动下载 Xray 核心 ($latest_ver)...${PLAIN}"
        wget -O /tmp/xray.zip "$download_url"

        if [[ ! -s /tmp/xray.zip ]]; then
            echo -e "${RED}[错误] 核心压缩包下载失败！${PLAIN}"
            exit 1
        fi
        unzip -o /tmp/xray.zip -d /usr/local/bin/ xray
        rm -f /tmp/xray.zip
        chmod +x /usr/local/bin/xray
    fi

    if [[ -w /proc/sys/vm/drop_caches ]]; then
        sync && echo 3 > /proc/sys/vm/drop_caches
    fi

    # 修复核心：重构 Systemd 配置，增加网络就绪强依赖和启动延迟，避免开机闪退
    if [ "$HAS_SYSTEMD" = true ]; then
        cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/
Restart=always
RestartSec=5
LimitNOFILE=233333

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
    else
        local OPENRC_FILE="/etc/init.d/xray"
        cat <<EOF > "$OPENRC_FILE"
#!/sbin/openrc-run
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -confdir /usr/local/etc/xray/"
command_background="yes"
pidfile="/run/xray.pid"
depend() {
    need net
}
EOF
        chmod +x "$OPENRC_FILE"
        rc-update add xray default >/dev/null 2>&1
    fi
}

# [核心执行模块]
update_xray_config() {
    local domain=$1 port=$2 uuid=$3 path=$4
    local direct_conf="/usr/local/etc/xray/conf_1_direct.json"

    if [[ "$domain" != "$old_domain" ]]; then
        echo -e "${YELLOW}检测到域名变更，正在更新证书...${PLAIN}"
        issue_cert "$domain"
    fi

    echo -e "${YELLOW}正在写入新配置到 JSON...${PLAIN}"
    local tmp_file=$(mktemp)
    jq ".inbounds[0].port = $port | 
        .inbounds[0].settings.clients[0].id = \"$uuid\" | 
        .inbounds[0].streamSettings.xhttpSettings.path = \"$path\" |
        .inbounds[0].streamSettings.xhttpSettings.host = \"$domain\" |
        .inbounds[0].streamSettings.tlsSettings.serverName = \"$domain\"" \
        "$direct_conf" > "$tmp_file" && mv "$tmp_file" "$direct_conf"

    restart_and_check

    if pgrep -x "xray" > /dev/null; then
        clear
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}       配置修改成功！节点已生效         ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        
        local d_name="${node_name:-Modified_xHTTP}"
        local d_fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint // "chrome"' "$direct_conf")
        local d_alpn_raw=$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn | join(",")' "$direct_conf")
        local d_alpn=$(echo "$d_alpn_raw" | sed 's/,/%2C/g')
        local d_path_enc=$(echo "$path" | sed 's/\//%2F/g')
        
        local final_host="$domain"
        if [[ "$domain" =~ ":" ]] && [[ ! "$domain" =~ "[" ]]; then
            final_host="[$domain]"
        fi

        local vless_link="vless://$uuid@$final_host:$port?security=tls&sni=$domain&type=xhttp&mode=auto&path=$d_path_enc&fp=$d_fp&alpn=$d_alpn#$d_name"

        echo -e "${BLUE}新配置详情：${PLAIN}"
        echo -e "  域名: ${domain}"
        echo -e "  端口: ${port}"
        echo -e "  UUID: ${uuid}"
        echo -e "  路径: ${path}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${YELLOW}新的直连链接 (VLESS + xHTTP + TLS):${PLAIN}"
        echo -e "${CYAN}${vless_link}${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        
        sync && echo 3 > /proc/sys/vm/drop_caches
        read -p "按回车键返回主菜单..."
    else
        echo -e "${RED}[错误] Xray 重启失败，配置可能未生效！${PLAIN}"
        read -p "按回车键返回..."
    fi
}

# --- 2. 安装 VLESS+xhttp+TLS ---
install_vless_direct() {
    [[ -z "$CERT_DIR" ]] && CERT_DIR="/usr/local/etc/xray/certs"
    [[ -z "$XRAY_CONF_DIRECT" ]] && XRAY_CONF_DIRECT="/usr/local/etc/xray/conf_1_direct.json"
    
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (兼容 CDN) ---${PLAIN}"
    
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"       

    read -p "请输入解析域名: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
    
    echo -e "${YELLOW}注意：若需套 CDN，端口请务必使用 CF 支持的端口 (如 443, 8443, 2053, 2083, 2087, 2096)${PLAIN}"
    read -p "请输入端口 (回车随机: $r_port): " port; port=${port:-$r_port}
    read -p "请输入UUID (回车随机: $r_uuid): " uuid; uuid=${uuid:-$r_uuid}
    read -p "请输入路径 (回车随机: $r_path): " path; path=${path:-$r_path}
    read -p "请输入指纹fp (回车随机: $r_fp): " fp; fp=${fp:-$r_fp}
    read -p "请输入ALPN (回车随机: $r_alpn): " alpn; alpn=${alpn:-$r_alpn}
    read -p "请输入自定义节点名称 (默认: Direct_xHTTP): " node_name
    node_name=${node_name:-"Direct_xHTTP"}    
    
    echo -e "${BLUE}请选择证书申请模式:${PLAIN}"
    echo -e "  1. Standalone (80端口模式)"
    echo -e "  2. Cloudflare API (DNS模式)"
    read -p "选择 [1-2] (默认 1): " c_mode
    c_mode=${c_mode:-1}
  
    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    if [[ ! -f "$ACME_BIN" ]]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi
    $ACME_BIN --set-default-ca --server letsencrypt

    local skip_acme="n"
    local cert_file="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    local key_file="$HOME/.acme.sh/${domain}_ecc/${domain}.key"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        echo -e "${YELLOW}检测到域名 $domain 已有完整证书文件。${PLAIN}"
        read -p "是否跳过新申请，直接使用现有证书？[y/n] (默认 y): " skip_acme
        skip_acme=${skip_acme:-y}
    else
        skip_acme="n"
    fi

    if [[ "$skip_acme" == "y" || "$skip_acme" == "Y" ]]; then
        echo -e "${GREEN}跳过申请阶段，直接进入证书同步...${PLAIN}"
    else
        if [[ "$c_mode" == "2" ]]; then
            read -p "请输入 CF Email: " cf_e
            read -p "请输入 CF Global API Key: " cf_k
            export CF_Key="$cf_k"
            export CF_Email="$cf_e"
            $ACME_BIN --issue --dns dns_cf -d "$domain" --force
        else
            if lsof -i:80 > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 80 端口占用，正在强制释放...${PLAIN}"
                lsof -i:80 | awk '{print $2}' | grep -v PID | xargs kill -9 >/dev/null 2>&1
                sleep 2
            fi
            $ACME_BIN --issue -d "$domain" --standalone --httpport 80 --listen-v6 --force
        fi
    fi

    if [[ ! -f "$cert_file" ]]; then
        echo -e "${RED}[致命错误] 证书申请未成功，无法获取 fullchain.cer。${PLAIN}"
        return 1
    fi

    mkdir -p "$CERT_DIR"
    cp -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" "$CERT_DIR/server.key"
    cp -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" "$CERT_DIR/server.crt"
    chmod 644 "$CERT_DIR/server.key" "$CERT_DIR/server.crt"

    local alpn_json=$(echo "$alpn" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')

    # 修复核心：确保安装直连节点时也自动追加出站路由策略
    if [[ ! -f "$XRAY_CONF_DIR/conf_0_core.json" ]]; then
        cat <<EOF > "$XRAY_CONF_DIR/conf_0_core.json"
{
    "log": { "loglevel": "warning" },
    "outbounds": [
        { "protocol": "freedom", "settings": { "domainStrategy": "$strategy" } }
    ]
}
EOF
    fi

    cat <<EOF > "$XRAY_CONF_DIR/conf_1_direct.json"
{
    "inbounds": [{
        "listen": "::",
        "port": $port, 
        "protocol": "vless",
        "tag": "$node_name",
        "settings": { "clients": [{"id": "$uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": { "path": "$path", "mode": "auto", "host": "$domain" },
            "tlsSettings": {
                "certificates": [{ "certificateFile": "$CERT_DIR/server.crt", "keyFile": "$CERT_DIR/server.key" }],
                "alpn": [$alpn_json], "fingerprint": "$fp"
            }
        }
    }]
}
EOF

    if restart_and_check; then
        echo -e "${GREEN}VLESS+xhttp+TLS 部署成功！${PLAIN}"
        # 自动触发一次强力守护任务注册，保证重启有效
        setup_cron_job "silent"
        show_node_info
    else
        echo -e "${RED}[错误] Xray 启动失败。${PLAIN}"
    fi
}

# --- 3. 安装 CF Tunnel  ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS + Host 强校验模式) ---${PLAIN}"

    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))
    local t_domain=""

    echo -e "${BLUE}请选择隧道类型:${PLAIN}"
    echo -e "  1. 临时隧道 (Quick Tunnel) [注意: 重启服务器后节点URL会变]"
    echo -e "  2. 固定隧道 (Named Tunnel) [推荐: 重启保持不变]"
    read -p "选择 [1-2] (默认 1): " t_choice
    t_choice=${t_choice:-1}
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid; t_uuid=${t_uuid:-$r_t_uuid}
    read -p "请输入自定义节点名称 (默认: CF_Tunnel): " t_node_name; t_node_name=${t_node_name:-"CF_Tunnel"}
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path; t_path=${t_path:-$r_t_path}

    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 CF 绑定域名: " t_domain
        read -p "请输入 Token: " t_token
        [[ -z "$t_domain" || -z "$t_token" ]] && { echo -e "${RED}输入不能为空！${PLAIN}"; return 1; }
        echo "$t_domain" > /usr/local/etc/xray/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port; t_port=${t_port:-$r_t_port}
    fi

    [[ -z "$CF_ARCH" ]] && detect_arch
    if [[ ! -f $CF_BIN ]]; then
        echo -e "${YELLOW}正在下载 cloudflared...${PLAIN}"
        wget -O $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        chmod +x $CF_BIN
    fi

    pkill -9 cloudflared >/dev/null 2>&1
    : > "$CF_LOG"

    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在启动临时隧道以获取动态域名...${PLAIN}"
        nohup $CF_BIN tunnel --logfile $CF_LOG --protocol http2 --url http://127.0.0.1:${t_port} > /dev/null 2>&1 &

        for i in {1..20}; do
            echo -ne "\r抓取域名中: ${i}s/20s..."
            t_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
            [[ -n "$t_domain" ]] && break
            sleep 1
        done
        echo ""

        if [[ -z "$t_domain" ]]; then
            echo -e "${RED}[致命错误] 获取临时域名失败！${PLAIN}"
            return 1
        fi
        echo "$t_domain" > /usr/local/etc/xray/cf_tunnel_domain
    fi

    cat <<EOF > "/usr/local/etc/xray/conf_2_tunnel.json"
{
    "inbounds": [{
        "listen": "127.0.0.1",
        "port": $t_port,
        "protocol": "vless",
        "tag": "$t_node_name",
        "settings": { "clients": [{"id": "$t_uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "ws", "security": "none",
            "wsSettings": { "path": "$t_path", "headers": { "Host": "$t_domain" } }
        }
    }]
}
EOF

    restart_and_check

    local cf_cmd=""
    if [[ "$t_choice" == "1" ]]; then
        cf_cmd="tunnel --logfile $CF_LOG --protocol http2 --http-host-header $t_domain --url http://127.0.0.1:${t_port}"
    else
        cf_cmd="tunnel --no-autoupdate --protocol http2 --http-host-header $t_domain run --token $t_token"
    fi

    # 修复核心：修复重启失效，完美兼容开机拉起逻辑
    if [ "$HAS_SYSTEMD" = true ]; then
        cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel Service
After=network.target network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 8
ExecStart=$CF_BIN $cf_cmd
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable cloudflared >/dev/null 2>&1
        systemctl restart cloudflared >/dev/null 2>&1
    else
        cat <<EOF > /etc/init.d/cloudflared
#!/sbin/openrc-run
command="$CF_BIN"
command_args="$cf_cmd"
command_background="yes"
pidfile="/run/cloudflared.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default >/dev/null 2>&1
        rc-service cloudflared restart >/dev/null 2>&1
    fi

    setup_cron_job "silent"
    show_node_info
}

# --- 修改参数整合模块  ---
modify_parameters_menu() {
    get_current_params
    clear
    echo -e "  1. 修改 Xray 节点参数\n  2. 修改 CF Tunnel 参数\n  0. 返回"
    read -p "选择: " sub_choice
    case $sub_choice in
        1)
            read -p "域名 (${old_domain}): " new_domain; new_domain=${new_domain:-$old_domain}
            read -p "端口 (${old_port}): " new_port; new_port=${new_port:-$old_port}
            read -p "UUID (${old_uuid}): " new_uuid; new_uuid=${new_uuid:-$old_uuid}
            read -p "路径 (${old_path}): " new_path; new_path=${new_path:-$old_path}
            update_xray_config "$new_domain" "$new_port" "$new_uuid" "$new_path"
            ;;
        2)
            # 兼容保留原版逻辑
            if [[ -f "/usr/local/etc/xray/cf_tunnel_domain" || "$old_t_choice" == "2" ]]; then
                local current_t_domain=$(cat /usr/local/etc/xray/cf_tunnel_domain 2>/dev/null)
                read -p "隧道域名 (${current_t_domain}): " new_t_domain; new_t_domain=${new_t_domain:-$current_t_domain}
                read -p "新 Token: " new_t_token; new_t_token=${new_t_token:-$old_t_token}
                read -p "新路径 (${old_t_path}): " new_t_path; new_t_path=${new_t_path:-$old_t_path}
                cf_cmd="tunnel --no-autoupdate run --token ${new_t_token}"
                echo "$new_t_domain" > /usr/local/etc/xray/cf_tunnel_domain
            else
                read -p "新临时路径 (${old_t_path}): " new_t_path; new_t_path=${new_t_path:-$old_t_path}
                cf_cmd="tunnel --no-autoupdate --url http://127.0.0.1:${old_port:-8443}$new_t_path"
            fi
            pkill -9 cloudflared && sleep 1
            nohup /usr/local/bin/cloudflared $cf_cmd > /dev/null 2>&1 &
            systemctl restart cloudflared >/dev/null 2>&1
            systemctl restart xray >/dev/null 2>&1
            read -p "修改完成，回车返回..."
            ;;
    esac
}

# --- 查看当前节点信息与链接 ---
show_node_info() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━ 当前已部署节点列表 ━━━━━━━━━━━━━━${PLAIN}"
    if [[ -f "$XRAY_CONF_DIRECT" ]]; then
        local d_name=$(jq -r '.inbounds[0].tag' "$XRAY_CONF_DIRECT")
        local d_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONF_DIRECT")
        local d_port=$(jq -r '.inbounds[0].port' "$XRAY_CONF_DIRECT")
        local d_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONF_DIRECT")
        local d_host=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' "$XRAY_CONF_DIRECT")
        local d_fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint // "chrome"' "$XRAY_CONF_DIRECT")
        local d_alpn_raw=$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn | join(",")' "$XRAY_CONF_DIRECT")
        local d_alpn=$(echo "$d_alpn_raw" | sed 's/,/%2C/g')
        local final_host="$d_host"
        [[ "$d_host" =~ ":" ]] && [[ ! "$d_host" =~ "[" ]] && final_host="[$d_host]"
        echo -e "${GREEN}[直连节点: $d_name]${PLAIN}\n  链接: ${CYAN}vless://$d_uuid@$final_host:$d_port?security=tls&sni=$d_host&type=xhttp&mode=auto&path=$(echo "$d_path" | sed 's/\//%2F/g')&fp=$d_fp&alpn=$d_alpn#$d_name${PLAIN}"
    fi

    if [[ -f "$XRAY_CONF_TUNNEL" ]]; then
        local t_name=$(jq -r '.inbounds[0].tag' $XRAY_CONF_TUNNEL)
        local t_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF_TUNNEL)
        local t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' $XRAY_CONF_TUNNEL)
        local t_url=$(cat /usr/local/etc/xray/cf_tunnel_domain 2>/dev/null)
        echo -e "${PURPLE}[隧道节点: $t_name]${PLAIN}\n  链接: ${YELLOW}vless://$t_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&host=$t_url&path=$(echo "$t_path" | sed 's/\//%2F/g')&fp=chrome&alpn=h2%2Chttp%2F1.1#$t_name${PLAIN}"
    fi
    read -p "按回车键返回菜单..."
}

# --- 卸载相关控制 ---
uninstall_xray() {
    systemctl stop xray >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service /etc/init.d/xray
    rm -rf /usr/local/etc/xray/conf_1_direct.json /usr/local/bin/xray
    echo -e "${GREEN}Xray 卸载完成。${PLAIN}"
}
uninstall_cf() {
    systemctl stop cloudflared >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1
    rm -f /etc/systemd/system/cloudflared.service /etc/init.d/cloudflared /usr/local/bin/cloudflared
    echo -e "${GREEN}Tunnel 卸载完成。${PLAIN}"
}
uninstall_all() {
    uninstall_xray
    uninstall_cf
    rm -rf /usr/local/etc/xray ~/.acme.sh
    crontab -l 2>/dev/null | grep -vE "xray_keep_alive|cleanup_logs" | crontab -
    echo -e "${GREEN}环境已彻底清理干净。${PLAIN}"
}
uninstall_menu() {
    clear
    echo -e "1. 卸载 Xray\n2. 卸载 CF Tunnel\n3. 彻底卸载全部"
    read -p "选择: " un_choice
    [[ "$un_choice" == "1" ]] && uninstall_xray
    [[ "$un_choice" == "2" ]] && uninstall_cf
    [[ "$un_choice" == "3" ]] && uninstall_all
}

# --- 自动获得当前参数缓存 ---
get_current_params() {
    if [[ -f "$XRAY_CONF_DIRECT" ]]; then
        old_domain=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' "$XRAY_CONF_DIRECT")
        old_port=$(jq -r '.inbounds[0].port' "$XRAY_CONF_DIRECT")
        old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONF_DIRECT")
        old_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$XRAY_CONF_DIRECT")
    fi
}

# --- 自动守护任务设置 (修复核心：如果是 Quick Tunnel 临时隧道，重启后自动重新抓取生成新域名并热重载 Xray) ---
setup_cron_job() {
    [[ "$1" != "silent" ]] && echo -e "${YELLOW}正在配置自适应高维维护守护任务...${PLAIN}"
    
    cat <<EOF > /usr/local/bin/xray_keep_alive.sh
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
    HAS_SYSTEMCTL=false
else
    HAS_SYSTEMCTL=true
fi

# 内存低时回收
free_mem=\$(free -m | awk '/Mem:/ {print \$4}')
if [ "\$free_mem" -lt 30 ]; then
    sync && echo 3 > /proc/sys/vm/drop_caches
fi

# 1. 守护 Xray 核心
if ! pgrep -x "xray" > /dev/null; then
    if \$HAS_SYSTEMCTL; then
        systemctl restart xray >/dev/null 2>&1
    else
        rc-service xray restart >/dev/null 2>&1
    fi
    sleep 3
    if ! pgrep -x "xray" > /dev/null; then
        nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
    fi
fi

# 2. 守护 Cloudflared 并对临时隧道实现【变动域名自适应热修正】
if [[ -f "/usr/local/bin/cloudflared" ]]; then
    if ! pgrep -x "cloudflared" > /dev/null; then
        if \$HAS_SYSTEMCTL; then
            systemctl restart cloudflared >/dev/null 2>&1
        else
            rc-service cloudflared restart >/dev/null 2>&1
        fi
        
        # 针对临时隧道的极端处理：如果重启了，动态抓取新分配的 trycloudflare 域名
        if [[ -f "/usr/local/etc/xray/conf_2_tunnel.json" ]] && ! grep -q "run --token" /etc/systemd/system/cloudflared.service 2>/dev/null; then
            sleep 8
            new_t_domain=\$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare.com" /tmp/cloudflared.log 2>/dev/null | head -n 1 | sed 's/https:\/\///')
            if [[ -n "\$new_t_domain" ]]; then
                echo "\$new_t_domain" > /usr/local/etc/xray/cf_tunnel_domain
                # 同步修改配置文件中的 Host 头
                tmp_j=\$(mktemp)
                jq ".inbounds[0].streamSettings.wsSettings.headers.Host = \"\$new_t_domain\"" /usr/local/etc/xray/conf_2_tunnel.json > "\$tmp_j" && mv "\$tmp_j" /usr/local/etc/xray/conf_2_tunnel.json
                # 重载 Xray 节点
                if \$HAS_SYSTEMCTL; then systemctl restart xray; else pkill -9 xray; fi
            fi
        fi
    fi
fi
EOF

    chmod +x /usr/local/bin/xray_keep_alive.sh
    (crontab -l 2>/dev/null | grep -v "xray_keep_alive.sh"; echo "* * * * * /usr/local/bin/xray_keep_alive.sh") | crontab -
    
    # 额外在 crontab 中追加开机自启强拉动作（针对无 systemd 环境双保险）
    (crontab -l 2>/dev/null | grep -v "reboot /usr/local/bin/xray_keep_alive.sh"; echo "@reboot /usr/local/bin/xray_keep_alive.sh") | crontab -

    [[ "$1" != "silent" ]] && echo -e "${GREEN}维护守护任务配置成功！已解决开机断流与闪退问题。${PLAIN}" && read -p "按回车返回..."
}

# --- 主菜单 ---
main_menu() {
    while true; do
        clear
        echo -e "${CYAN}==========================================
     BoGe Xray & CF Tunnel 一键脚本 (修复版)
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS+xhttp+TLS (直连/CDN)
 ${YELLOW}2.${PLAIN} 安装 CF Tunnel (隧道模式)
 ${YELLOW}3.${PLAIN} 查看当前节点信息与链接
 ${YELLOW}4.${PLAIN} 修改配置参数
 ${YELLOW}5.${PLAIN} 服务系统升级与BBR优化
 ${YELLOW}6.${PLAIN} 卸载管理控制台  
 ${YELLOW}7.${PLAIN} 开启自动守护 (解决重启失效、闪退必备)
 ${YELLOW}8.${PLAIN} 清理系统日志与垃圾
 ${RED}0.${PLAIN} 退出脚本"
        read -p "选择 [0-8]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) modify_parameters_menu ;;
            5) update_services_bbr ;; 
            6) uninstall_menu ;;
            7) setup_cron_job ;;
            8) cleanup_logs ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误${PLAIN}" && sleep 1 ;;
        esac
    done
}

case "$1" in
    "cleanup_logs") cleanup_logs "silent" ;;
    *) main_menu ;;
esac
