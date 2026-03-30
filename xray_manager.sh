#!/bin/bash

# 1. 权限检查 (第一时间拦截非 root 用户)
[[ $EUID -ne 0 ]] && echo -e "\033[0;31m错误: 必须使用 root 用户运行此脚本！\033[0m" && exit 1

# ====================================================
# Project: Xray xhttp & CF Tunnel 一键脚本
# Author: BoGe & User (caojiaxia)
# System: Debian/Ubuntu/CentOS
# ====================================================

# 颜色和路径定义 
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF_DIRECT="$XRAY_CONF_DIR/conf_1_direct.json"
XRAY_CONF_TUNNEL="$XRAY_CONF_DIR/conf_2_tunnel.json"
CERT_DIR="$XRAY_CONF_DIR/certs"
CF_BIN="/usr/local/bin/cloudflared"
CF_LOG="/tmp/cloudflared.log"

# --- 自动检测网络能力并设置策略 (小机适配版) ---
check_network_strategy() {
    echo -e "${BLUE}[进度] 正在探测网络环境...${PLAIN}"
    
    # 【物理限制检测】
    # 获取总内存 (MB)
    local total_mem=$(free -m | awk '/Mem:/ {print $2}')
    
    # 默认回退策略
    strategy="AsIs"
    
    # 如果内存小于 512MB，强制使用 AsIs 模式，跳过复杂的双栈切换，保命第一
    if [ "$total_mem" -lt 512 ]; then
        strategy="AsIs"
        echo -e "${YELLOW}[注意] 检测到内存较小 (${total_mem}MB)，已自动开启低耗能模式以确保稳定。${PLAIN}"
        return 0
    fi

    # --- 原有探测逻辑 (仅在资源充足时执行) ---
    if curl -6 -s --max-time 3 https://www.google.com > /dev/null 2>&1; then
        strategy="UseIPv6"
        echo -e "${GREEN}[检测] 环境支持 IPv6，将启用 IPv6 优先模式。${PLAIN}"
    elif curl -4 -s --max-time 3 https://www.google.com > /dev/null 2>&1; then
        strategy="UseIPv4"
        echo -e "${YELLOW}[提醒] 环境不支持 IPv6，已切换至 IPv4 优先模式。${PLAIN}"
    else
        strategy="AsIs"
        echo -e "${PURPLE}[提醒] 无法确认双栈连接性，使用默认解析策略。${PLAIN}"
    fi
}

# --- 优化 CF Tunnel 传输协议 (HTTP2 模式) ---
update_cf_tunnel_protocol() {
    SERVICE_FILE="/etc/systemd/system/cloudflared.service"
    
    if [ -f "$SERVICE_FILE" ]; then
        echo -e "${YELLOW}检测到 Systemd 服务，正在优化传输协议...${PLAIN}"
        
        # 1. 如果已经有协议参数了，先删掉旧的（防止重复堆积参数）
        sed -i 's/--protocol [^ ]*//g' "$SERVICE_FILE"
        
        # 2. 在 tunnel run 后面精准插入 --protocol http2
        sed -i 's/tunnel run/tunnel run --protocol http2/' "$SERVICE_FILE"
        
        # 3. 重载并重启
        systemctl daemon-reload
        systemctl restart cloudflared
        
        echo -e "${GREEN}协议已强制切换至 HTTP2 并重启服务。${PLAIN}"
    else
        echo -e "${RED}[错误] 未找到 cloudflared 服务文件，请先安装隧道。${PLAIN}"
    fi
    read -p "优化完成，按回车键返回菜单..."
}

# ---  自动清理日志与系统垃圾 ---
cleanup_logs() {
    echo -e "${YELLOW}正在执行系统瘦身与日志清理...${PLAIN}"
    
    # 1. 清空 Xray 和 Cloudflared 的日志文件内容（真正的清零，不保留换行符）
    [[ -f /var/log/xray/access.log ]] && : > /var/log/xray/access.log
    [[ -f /var/log/xray/error.log ]] && : > /var/log/xray/error.log
    [[ -f /tmp/cloudflared.log ]] && : > /tmp/cloudflared.log
    [[ -f "$CF_LOG" ]] && : > "$CF_LOG"
    
    # 2. 清理系统日志 (journalctl) 只保留最近 1 天
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=1d >/dev/null 2>&1
    fi

    # 3. 清理包管理器缓存 (适配 Debian/Ubuntu/CentOS)
    if command -v apt-get >/dev/null 2>&1; then
        apt-get autoremove -y >/dev/null 2>&1
        apt-get clean >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum autoremove -y >/dev/null 2>&1
        yum clean all >/dev/null 2>&1
    fi

    # 4. 设置定时任务：每周一凌晨 3 点自动清理一次
    # 使用 readlink 动态获取当前脚本的绝对路径，避免硬编码导致任务失效
    local current_script=$(readlink -f "$0")
    if ! crontab -l 2>/dev/null | grep -q "cleanup_logs"; then
        (crontab -l 2>/dev/null; echo "0 3 * * 1 $current_script cleanup_logs > /dev/null 2>&1") | crontab -
        echo -e "${GREEN}已添加每周自动清理计划任务。${PLAIN}"
    fi

    echo -e "${GREEN}清理完成！磁盘空间已释放。${PLAIN}"
    [[ "$1" != "silent" ]] && read -p "按回车键返回菜单..."
}

# --- [模块: BBR 加速]  ---
enable_bbr() {
    echo -e "${BLUE}[进度] 正在检查 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}[提示] BBR 已经处于开启状态，无需重复操作。${PLAIN}"
    else
        echo -e "${YELLOW}正在写入 BBR 配置...${PLAIN}"
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
        if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
            echo -e "${GREEN}  BBR 加速已成功开启！内核已切换为 FQ+BBR${PLAIN}"
            echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
        else
            echo -e "${RED}[错误] BBR 开启失败，请检查内核版本是否高于 4.9${PLAIN}"
        fi
    fi
    read -p "按回车键返回..."
}
# --- 1. 基础环境安装 ---
install_base() {
    echo -e "${BLUE}[进度] 正在安装系统基础依赖...${PLAIN}"
    if [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl wget jq socat cron openssl tar lsof net-tools
    else
        yum install -y curl wget jq socat crontabs openssl tar lsof net-tools
    fi
    
    mkdir -p /usr/local/etc/xray "$CERT_DIR"

    # 【紧急清理内存 & 释放缓存】
    echo -e "${YELLOW}正在清理系统缓存以释放内存...${PLAIN}"
    sync && echo 3 > /proc/sys/vm/drop_caches

    # 【核心修改：暴力清理并重新拉取】
    systemctl stop xray >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1
    rm -rf /usr/local/bin/xray /usr/local/share/xray

    echo -e "${YELLOW}正在重新拉取最新版 Xray 核心...${PLAIN}"
    
    # 使用官方脚本安装时增加限制，减少解压时的压力
    # 如果还是断开，建议手动下载二进制文件
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # --- 核心权限修正：解决 Permission denied ---
    if [[ -f /usr/local/bin/xray ]]; then
        echo -e "${BLUE}[进度] 正在进行 Xray 二进制权限强制校验...${PLAIN}"
        # 防止文件被锁定 (部分 LXC 环境常见)
        chattr -i /usr/local/bin/xray >/dev/null 2>&1
        chmod +x /usr/local/bin/xray
        
        # 打印版本信息，确认 xhttp 支持情况
        local xray_ver=$(/usr/local/bin/xray version | head -n 1)
        echo -e "${GREEN}[成功] 核心版本: $xray_ver${PLAIN}"
    fi

    # 【步骤 2】：精准定位服务文件路径
    local SERVICE_FILE="/etc/systemd/system/xray.service"
    [[ ! -f "$SERVICE_FILE" ]] && SERVICE_FILE="/lib/systemd/system/xray.service"

    # 【步骤 3】：如果官方没生成服务文件，则手动创建 (保持你原有的 Service 结构)
    if [[ ! -f "$SERVICE_FILE" ]]; then
        echo -e "${YELLOW}[警告] 官方 Service 文件缺失，正在手动创建 $SERVICE_FILE ...${PLAIN}"
        cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls/xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        SERVICE_FILE="/etc/systemd/system/xray.service"
    fi

    # 【步骤 4】：修正服务配置 
    if [[ -f "$SERVICE_FILE" ]]; then
        echo -e "${BLUE}[进度] 正在修正服务运行参数与权限...${PLAIN}"
        systemctl stop xray >/dev/null 2>&1
        pkill -9 xray >/dev/null 2>&1
        
        # 修正启动命令和运行用户
        sed -i 's|run -config /usr/local/etc/xray/config.json|run -confdir /usr/local/etc/xray/|g' "$SERVICE_FILE"
        sed -i 's/User=nobody/User=root/g' "$SERVICE_FILE"
        
        # 清理可能存在的冲突目录和默认配置
        rm -rf "${SERVICE_FILE}.d"
        rm -f /usr/local/etc/xray/config.json
        
        # 赋予服务文件权限并重载
        chmod 644 "$SERVICE_FILE"
        systemctl daemon-reload
        echo -e "${GREEN}[成功] 服务环境配置完毕。${PLAIN}"
    else
        echo -e "${RED}[致命错误] 无法定位 Xray 二进制文件或服务文件，安装失败。${PLAIN}"
        return 1
    fi
}
# --- 2. 安装 VLESS+xhttp+TLS ---
install_vless_direct() {
    # 变量兜底
    [[ -z "$CERT_DIR" ]] && CERT_DIR="/usr/local/etc/xray/certs"
    [[ -z "$XRAY_CONF_DIRECT" ]] && XRAY_CONF_DIRECT="/usr/local/etc/xray/conf_1_direct.json"
    
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (兼容 CDN) ---${PLAIN}"
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    
    # --- 变量生成区 ---
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"

    # 定义专业伪装路径池
    local PATH_POOL=(
        "/api/v1/auth/login"
        "/api/v2/user/profile"
        "/api/v3/report/metrics"
        "/assets/data/report"
        "/assets/logs/upload"
        "/static/v1/internal/trace"
        "/cdn-cgi/v2/telemetry"
        "/api/client/v4/update"
        "/socket.io/v4/transport"
        "/ws/chat/v3/connect"
    )
    # 从池子中随机选取一个默认路径
    local r_path=${PATH_POOL[$RANDOM % ${#PATH_POOL[@]}]}

    # --- 用户输入区 ---
    read -p "请输入解析域名: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
    
    echo -e "${YELLOW}注意：若需套 CDN，端口请务必使用 CF 支持的端口 (如 443, 8443, 2053, 2083, 2096)${PLAIN}"
    read -p "请输入端口 (回车随机: $r_port): " port; port=${port:-$r_port}
    read -p "请输入UUID (回车随机: $r_uuid): " uuid; uuid=${uuid:-$r_uuid}
    read -p "请输入路径 (回车随机: $r_path): " path; path=${path:-$r_path}
    read -p "请输入指纹fp (回车随机: $r_fp): " fp; fp=${fp:-$r_fp}
    read -p "请输入ALPN (回车随机: $r_alpn): " alpn; alpn=${alpn:-$r_alpn}
    read -p "请输入自定义节点名称 (默认: Direct_xHTTP): " node_name
    node_name=${node_name:-"Direct_xHTTP"}    
    
    echo -e "选择模式: 1.Standalone 2.Cloudflare API"
    read -p "选择 [1-2]: " c_mode

    # --- 执行安装区 ---
    echo -e "${BLUE}[进度] 正在检查 Xray 核心环境...${PLAIN}"
    # 这里记得检查一下是否有 Swap，如果没有，建议脚本自动帮用户挂载
    if [[ $(free | grep -i swap | awk '{print $2}') -lt 1024 ]]; then
        echo -e "${YELLOW}[提醒] 检测到 Swap 过小，正在为您维持 512MB 虚拟内存以防断连...${PLAIN}"
        # 这里可以调用你之前的 swap 脚本逻辑
    fi

    [[ ! -f /usr/local/bin/xray ]] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload

    echo -e "${BLUE}[进度] 正在处理证书步骤...${PLAIN}"
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi
}
    
    # 定义绝对路径变量，避免 source ~/.bashrc 失败导致后续报错
    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    $ACME_BIN --set-default-ca --server letsencrypt
    # ------------------------------------------------

    if [[ "$c_mode" == "2" ]]; then
        read -p "请输入 CF Email: " cf_e
        read -p "请输入 CF Global API Key: " cf_k
        export CF_Key="$cf_k"
        export CF_Email="$cf_e"
        $ACME_BIN --issue --dns dns_cf -d $domain --force
    else
        if [[ ! -f ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            if lsof -i:80 > /dev/null 2>&1; then
                echo -e "${RED}[错误] 80 端口被占用，请停止 Docker/Nginx 后再试！${PLAIN}"
                return 1
            fi
        fi
        $ACME_BIN --issue -d $domain --standalone --force
    fi

    if [[ -f ~/.acme.sh/${domain}_ecc/${domain}.key ]] && [[ -f ~/.acme.sh/${domain}_ecc/fullchain.cer ]]; then
        echo -e "${GREEN}[成功] 证书就绪，正在同步至 Xray 目录...${PLAIN}"
        mkdir -p $CERT_DIR
        cp -f ~/.acme.sh/${domain}_ecc/${domain}.key $CERT_DIR/server.key
        cp -f ~/.acme.sh/${domain}_ecc/fullchain.cer $CERT_DIR/server.crt
        chmod 644 $CERT_DIR/server.key $CERT_DIR/server.crt
    else
        echo -e "${RED}[致命错误] 无法获取证书，请检查 API Key 或 DNS 解析是否正确！${PLAIN}"
        return 1
    fi

    # 处理变量格式化
    local alpn_formatted=$(echo "$alpn" | sed 's/,/","/g')

    echo -e "${BLUE}[进度] 正在写入核心配置 (IPv6 优先出站模式)...${PLAIN}"

# 运行检测
check_network_strategy

# 核心配置写入
cat <<EOF > $XRAY_CONF_DIRECT
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "0.0.0.0",
        "port": $port, 
        "protocol": "vless",
        "tag": "$node_name",
        "settings": { 
            "clients": [{"id": "$uuid"}], 
            "decryption": "none" 
        },
        "streamSettings": {
            "network": "xhttp", 
            "security": "tls",
            "xhttpSettings": { 
                "path": "$path", 
                "mode": "auto", 
                "host": "$domain" 
            },
            "tlsSettings": {
                "certificates": [{ 
                    "certificateFile": "$CERT_DIR/server.crt", 
                    "keyFile": "$CERT_DIR/server.key" 
                }],
                "alpn": ["$alpn_formatted"],
                "fingerprint": "$fp"
            }
        }
    }],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "$strategy"
            }
        }
    ]
}
EOF

    # 强力重启逻辑
    systemctl stop xray >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1
    sleep 1
    systemctl start xray
    
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}VLESS+xhttp+TLS 部署成功！${PLAIN}"
        show_node_info
    else
        echo -e "${RED}[错误] Xray 启动失败。${PLAIN}"
        echo -e "${YELLOW}正在进行配置诊断...${PLAIN}"
        /usr/local/bin/xray -test -config $XRAY_CONF_DIRECT
    fi
}

# --- 3. 安装 CF Tunnel (已集成专业路径池与 IPv6 优化) ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS 模式) ---${PLAIN}"
    
    # --- 1. 定义专业伪装路径池 (与 VLESS 模块保持一致) ---
    local PATH_POOL=(
        "/api/v1/auth/login"
        "/api/v2/user/profile"
        "/api/v3/report/metrics"
        "/assets/data/report"
        "/assets/logs/upload"
        "/static/v1/internal/trace"
        "/cdn-cgi/v2/telemetry"
        "/api/client/v4/update"
        "/socket.io/v4/transport"
        "/ws/chat/v3/connect"
    )

    # --- 2. 生成默认值 ---
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    # 从池子中随机选取一个作为默认路径
    local r_t_path=${PATH_POOL[$RANDOM % ${#PATH_POOL[@]}]}
    local r_t_port=$((RANDOM % 55535 + 10000))
    
    # --- 3. 用户输入交互 ---
    echo -e "选择隧道类型: 1.临时隧道 2.固定隧道"
    read -p "选择 [1-2]: " t_choice
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid
    t_uuid=${t_uuid:-$r_t_uuid}

    read -p "请输入自定义节点名称 (默认: CF_Tunnel): " t_node_name
    t_node_name=${t_node_name:-"CF_Tunnel"}

    # 这里会显示池子里抽出的专业路径
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path
    t_path=${t_path:-$r_t_path}

    local t_domain=""
    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 Cloudflare 绑定的域名 (如 tunnel.example.com): " t_domain
        [[ -z "$t_domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
        read -p "请输入 Token: " t_token
        [[ -z "$t_token" ]] && { echo -e "${RED}Token不能为空！${PLAIN}"; return; }
        echo "$t_domain" > /tmp/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port
        t_port=${t_port:-$r_t_port}
    fi

    # 4. 运行检测与配置写入
    check_network_strategy

    cat <<EOF > $XRAY_CONF_TUNNEL
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "127.0.0.1",
        "port": $t_port, 
        "protocol": "vless",
        "tag": "$t_node_name",
        "settings": { 
            "clients": [{"id": "$t_uuid"}], 
            "decryption": "none" 
        },
        "streamSettings": {
            "network": "ws", 
            "security": "none",
            "wsSettings": { "path": "$t_path" }
        }
    }],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "$strategy"
            },
            "tag": "tunnel_out"
        }
    ]
}
EOF
    systemctl restart xray
    sleep 1  # 增加 1 秒缓冲，确保端口已完全监听，防止 cloudflared 启动瞬间连不上回源端口

    # 下载与权限
    if [[ ! -f $CF_BIN ]]; then
        echo -e "${YELLOW}正在检测架构并下载 cloudflared...${PLAIN}"
        local arch=$(uname -m)
        local cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
        [[ "$arch" == "aarch64" ]] && cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
        wget -O $CF_BIN $cf_url && chmod +x $CF_BIN
    fi

    # Systemd 守护进程运行 cloudflared
    echo -e "${BLUE}[进度] 正在配置 cloudflared 服务守护...${PLAIN}"
    systemctl stop cloudflared >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1
    rm -f $CF_LOG

    local cf_cmd=""
    if [[ "$t_choice" == "1" ]]; then
        # 临时隧道直接强制 http2
        cf_cmd="tunnel --protocol http2 --url http://127.0.0.1:$t_port"
    else
        # 固定隧道：不仅带 token，还要强制 http2 运行模式，性能更佳
        cf_cmd="tunnel --protocol http2 --no-autoupdate run --token $t_token"
    fi

    cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$CF_BIN $cf_cmd
Restart=always
RestartSec=5
StandardOutput=file:$CF_LOG
StandardError=file:$CF_LOG

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable cloudflared
    systemctl start cloudflared

    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在尝试抓取临时域名 (最长等待 30s)...${PLAIN}"
        for i in {1..30}; do
            echo -ne "\r正在尝试抓取域名: ${i}s..."
            if [[ -f $CF_LOG ]]; then
                tmp_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
                if [[ -n "$tmp_domain" ]]; then
                    echo -e "\n${GREEN}抓取成功！域名: $tmp_domain${PLAIN}"
                    echo "$tmp_domain" > /tmp/cf_tunnel_domain
                    break
                fi
            fi
            sleep 1
        done
        [[ -z "$tmp_domain" ]] && echo -e "\n${RED}域名抓取超时，请检查日志: $CF_LOG${PLAIN}"
    else
        echo -e "${GREEN}固定隧道服务已启动，正在执行 HTTP2 协议优化...${PLAIN}"
        # 针对固定隧道，调用协议优化函数
        update_cf_tunnel_protocol
        sleep 1
    fi
    
    echo -e "${BLUE}所有组件已就绪，正在生成节点信息...${PLAIN}"
    sleep 2
    show_node_info
}

# --- 4. 查看当前节点信息与链接  ---
show_node_info() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━ 当前已部署节点列表 ━━━━━━━━━━━━━━${PLAIN}"
    if [[ -f "$XRAY_CONF_DIRECT" ]]; then
        local d_name=$(jq -r '.inbounds[0].tag' $XRAY_CONF_DIRECT)
        local d_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF_DIRECT)
        local d_port=$(jq -r '.inbounds[0].port' $XRAY_CONF_DIRECT)
        local d_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $XRAY_CONF_DIRECT)
        local d_host=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $XRAY_CONF_DIRECT)
        local d_fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' $XRAY_CONF_DIRECT)
        local d_alpn_raw=$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn | join(",")' $XRAY_CONF_DIRECT)
        local d_alpn=$(echo $d_alpn_raw | sed 's/,/%2C/g')
        echo -e "${GREEN}[节点: $d_name]${PLAIN}"
        echo -e "  链接: ${YELLOW}vless://$d_uuid@$d_host:$d_port?security=tls&sni=$d_host&type=xhttp&mode=auto&path=$(echo $d_path | sed 's/\//%2F/g')&fp=$d_fp&alpn=$d_alpn#$d_name${PLAIN}"
        echo -e "------------------------------------------------"
    fi
    if [[ -f "$XRAY_CONF_TUNNEL" ]]; then
        local t_name=$(jq -r '.inbounds[0].tag' $XRAY_CONF_TUNNEL)
        local t_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF_TUNNEL)
        local t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' $XRAY_CONF_TUNNEL)
        local t_url=$(cat /tmp/cf_tunnel_domain 2>/dev/null)
        echo -e "${PURPLE}[节点: $t_name]${PLAIN}"
        if [[ -n "$t_url" ]]; then
            echo -e "  链接: ${YELLOW}vless://$t_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&path=$(echo $t_path | sed 's/\//%2F/g')#$t_name${PLAIN}"
        fi
        echo -e "------------------------------------------------"
    fi
    read -p "按回车键返回菜单..."
}
# --- 5. 彻底卸载  ---
uninstall_all() {
    echo -e "${RED}！！！警告：此操作将彻底删除所有节点配置、证书及 Xray/Cloudflared 服务 ！！！${PLAIN}"
    read -p "确定要清空所有数据并卸载吗？[y/n]: " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}[1/5] 正在停止相关服务与进程...${PLAIN}"
    # 停止服务
    systemctl stop xray cloudflared >/dev/null 2>&1
    # 强力杀除残留进程
    pkill -9 xray >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1
    pkill -f cloudflared >/dev/null 2>&1

    echo -e "${YELLOW}[2/5] 正在移除 Systemd 服务定义...${PLAIN}"
    systemctl disable xray cloudflared >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reload

    echo -e "${YELLOW}[3/5] 正在清理安装目录与配置...${PLAIN}"
    # 安全删除：确保变量不为空时才执行，或者直接写死路径
    [[ -n "$CERT_DIR" ]] && rm -rf "$CERT_DIR"
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/cloudflared
    # 如果定义了 $CF_BIN 变量也一并清除
    [[ -n "$CF_BIN" ]] && rm -f "$CF_BIN"

    echo -e "${YELLOW}[4/5] 正在清理临时文件与日志...${PLAIN}"
    rm -f /tmp/cloudflared.log
    rm -f /tmp/cf_tunnel_domain
    rm -f $CF_LOG
    rm -f /var/log/xray_keep_alive.log
    # 彻底清理 acme.sh 文件夹 (如需保留请注释掉下一行)
    rm -rf ~/.acme.sh

    echo -e "${YELLOW}[5/5] 正在清理残留依赖与守护任务...${PLAIN}"
    
    # 清理自动守护脚本文件
    rm -f /usr/local/bin/xray_keep_alive.sh
    
    # 强力清理 crontab (保留非脚本相关的任务)
    if crontab -l >/dev/null 2>&1; then
        crontab -l | grep -vE "acme.sh|xray_keep_alive.sh" | crontab -
    fi

    # 全面清理 shell 环境变量
    for profile in ~/.bashrc ~/.profile ~/.bash_profile; do
        [[ -f "$profile" ]] && sed -i '/acme.sh/d' "$profile"
    done

    echo -e "------------------------------------------------"
    echo -e "${GREEN}卸载完成！系统已恢复至干净状态。${PLAIN}"
    echo -e "------------------------------------------------"
    read -p "按回车键返回菜单..."
}

# --- [主菜单模块]  ---
main_menu() {
    while true; do
        clear
        echo -e "
${CYAN}==========================================
     BoGe Xray & CF Tunnel 一键脚本
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS+xhttp+TLS
 ${YELLOW}2.${PLAIN} 安装 CF Tunnel
 ${YELLOW}3.${PLAIN} 查看当前节点信息与链接
 ${YELLOW}4.${PLAIN} 开启 BBR 加速
 ${YELLOW}5.${PLAIN} 卸载脚本及相关组件
 ${YELLOW}6.${PLAIN} 开启自动守护 (推荐)
 ${YELLOW}7.${PLAIN} 优化 CF 隧道协议 (HTTP2)
 ${YELLOW}8.${PLAIN} 清理系统日志与垃圾
 ${RED}0.${PLAIN} 退出脚本"
        read -p "选择 [0-8]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) enable_bbr ;; 
            5) uninstall_all ;;
            6) setup_cron_job ;;
            7) update_cf_tunnel_protocol ;;
            8) cleanup_logs ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误${PLAIN}" && sleep 1 ;;
        esac
    done
}

# --- 自动守护任务设置 ---
setup_cron_job() {
    echo -e "${YELLOW}正在配置自动维护任务 (每分钟检查一次)...${PLAIN}"
    
    # 创建守护脚本
    cat <<EOF > /usr/local/bin/xray_keep_alive.sh
#!/bin/bash
# 显式声明 PATH，确保 Cron 环境能找到 systemctl 和其他二进制文件
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 检查 Xray 状态，如果不活跃则尝试启动
if ! systemctl is-active --quiet xray; then
    echo "\$(date): Xray 掉线，正在尝试拉起..." >> /var/log/xray_keep_alive.log
    systemctl start xray
fi

# 检查 Cloudflare Tunnel (仅在服务存在时执行)
if systemctl list-unit-files | grep -q cloudflared.service; then
    if ! systemctl is-active --quiet cloudflared; then
        echo "\$(date): Cloudflared 掉线，正在尝试拉起..." >> /var/log/xray_keep_alive.log
        systemctl start cloudflared
    fi
fi
EOF
    chmod +x /usr/local/bin/xray_keep_alive.sh

    # 写入 Crontab (采用“先删后加”逻辑，防止多次点击导致任务重复堆积)
    (crontab -l 2>/dev/null | grep -v "xray_keep_alive.sh"; echo "* * * * * /usr/local/bin/xray_keep_alive.sh") | crontab -
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  自动守护已开启：每分钟自动检测并拉起服务 ${PLAIN}"
    echo -e "${GREEN}  运行日志记录在: /var/log/xray_keep_alive.log ${PLAIN}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    read -p "按回车键返回菜单..."
}

case "$1" in
    "cleanup_logs")
        cleanup_logs "silent"
        ;;
    *)
        main_menu
        ;;
esac
