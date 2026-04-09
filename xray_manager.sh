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

# 自动检测架构，确保 cloudflared 下载不报错
detect_arch() {
    case "$(uname -m)" in
        x86_64)  CF_ARCH="amd64" ;;
        aarch64) CF_ARCH="arm64" ;;
        armv7l)  CF_ARCH="arm"   ;;
        *)       CF_ARCH="amd64" ;;
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
    # 仅在非 systemd 环境下定义伪装函数
    systemctl() {
        local action=$1
        shift # 移除第一个参数 (action)
        local service=${1%.service}
        case "$action" in
            start|stop|restart) rc-service "$service" "$action" >/dev/null 2>&1 ;;
            enable) 
                # 处理 enable --now 的情况
                [[ "$1" == "--now" ]] && service=${2%.service}
                rc-update add "$service" default >/dev/null 2>&1 
                [[ "$1" == "--now" ]] && rc-service "$service" start >/dev/null 2>&1
                ;;
            is-active) rc-service "$service" status 2>/dev/null | grep -q "started" ;;
            # 【新增】通过扫描 init 目录模拟服务列表，解决 Alpine 下的安装检测问题
            list-unit-files) ls /etc/init.d/ ;;
            daemon-reload) : ;;
            *) return 0 ;;
        esac
    }
fi

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
    elif command -v apk >/dev/null 2>&1; then
        apk cache clean >/dev/null 2>&1
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
    detect_arch  # 必须先运行检测架构
    echo -e "${BLUE}[进度] 正在安装系统基础依赖...${PLAIN}"
    if grep -qi "alpine" /etc/os-release; then
        apk update && apk add bash curl wget jq socat cronie openssl tar lsof net-tools libc6-compat openrc >/dev/null 2>&1
    elif [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl wget jq socat cron openssl tar lsof net-tools >/dev/null 2>&1
    else
        yum install -y curl wget jq socat crontabs openssl tar lsof net-tools >/dev/null 2>&1
    fi
    
    # 依赖装完后立即探测，确保 strategy 变量有值
    check_network_strategy
    
    mkdir -p /usr/local/etc/xray "$CERT_DIR"

    echo -e "${YELLOW}正在清理系统缓存以释放内存...${PLAIN}"
    sync && echo 3 > /proc/sys/vm/drop_caches

    systemctl stop xray >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1
    rm -rf /usr/local/bin/xray /usr/local/share/xray

    echo -e "${YELLOW}正在重新拉取最新版 Xray 核心...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    if [[ -f /usr/local/bin/xray ]]; then
        echo -e "${BLUE}[进度] 正在进行 Xray 二进制权限强制校验...${PLAIN}"
        chattr -i /usr/local/bin/xray >/dev/null 2>&1
        chmod +x /usr/local/bin/xray
        local xray_ver=$(/usr/local/bin/xray version | head -n 1)
        echo -e "${GREEN}[成功] 核心版本: $xray_ver${PLAIN}"
    fi

    # --- 【重点修正：区分 Systemd 与 OpenRC】 ---
    if [ "$HAS_SYSTEMD" = true ]; then
        local SERVICE_FILE="/etc/systemd/system/xray.service"
        [[ ! -f "$SERVICE_FILE" ]] && SERVICE_FILE="/lib/systemd/system/xray.service"
        
        if [[ ! -f "$SERVICE_FILE" ]]; then
            echo -e "${YELLOW}[警告] 官方 Service 文件缺失，正在手动创建 $SERVICE_FILE ...${PLAIN}"
            cat <<EOF > /etc/systemd/system/xray.service
[Unit]
Description=Xray Service
After=network.target
[Service]
User=root
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/
Restart=always
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable --now xray
        else
            echo -e "${BLUE}[进度] 正在修正服务运行参数与权限...${PLAIN}"
            sed -i 's|run -config /usr/local/etc/xray/config.json|run -confdir /usr/local/etc/xray/|g' "$SERVICE_FILE"
            sed -i 's/User=nobody/User=root/g' "$SERVICE_FILE"
            chmod 644 "$SERVICE_FILE"
            systemctl daemon-reload
        fi # <--- 这里补齐了内部 if 的闭合，解决了 line 220 的 elif 报错
    elif command -v rc-service >/dev/null 2>&1; then
        local OPENRC_FILE="/etc/init.d/xray"
        echo -e "${YELLOW}[警告] 检测到 Alpine (OpenRC)，正在创建 $OPENRC_FILE ...${PLAIN}"
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
        rc-service xray start >/dev/null 2>&1
    fi
    echo -e "${GREEN}[成功] 服务环境配置完毕。${PLAIN}"
}
# --- 2. 安装 VLESS+xhttp+TLS ---
install_vless_direct() {
    # 变量兜底：防止全局变量失效导致空值操作风险
    [[ -z "$CERT_DIR" ]] && CERT_DIR="/usr/local/etc/xray/certs"
    [[ -z "$XRAY_CONF_DIRECT" ]] && XRAY_CONF_DIRECT="/usr/local/etc/xray/conf_1_direct.json"
    
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (兼容 CDN) ---${PLAIN}"

    # --- 变量生成区 ---    
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"       

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

    echo -e "${BLUE}[进度] 正在检查 Xray 核心环境...${PLAIN}"
    if [[ ! -f /usr/local/bin/xray ]]; then
        echo -e "${YELLOW}检测到核心缺失且为非 Systemd 系统，正在手动拉取核心...${PLAIN}"
        # 自动获取架构
        local temp_arch="64"
        [[ "$(uname -m)" == "aarch64" ]] && temp_arch="arm64-v8a"
        
        wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${temp_arch}.zip"
        if [ $? -eq 0 ]; then
            unzip -o /tmp/xray.zip xray -d /usr/local/bin/
            chmod +x /usr/local/bin/xray
            rm -f /tmp/xray.zip
            echo -e "${GREEN}核心手动安装成功！${PLAIN}"
        else
            echo -e "${RED}下载核心失败，请检查网络。${PLAIN}"
            return 1
        fi
    fi

    # 只有 systemd 系统才执行 systemctl 重载
    if [ "$HAS_SYSTEMD" = true ]; then
        rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload
    fi
 
# --- 执行安装区 ---
    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    
    if [[ ! -f "$ACME_BIN" ]]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi
    
    # 强制指定 server，避开默认 ZeroSSL 注册慢的问题
    $ACME_BIN --set-default-ca --server letsencrypt

    if [[ "$c_mode" == "2" ]]; then
        read -p "请输入 CF Email: " cf_e
        read -p "请输入 CF Global API Key: " cf_k
        export CF_Key="$cf_k"
        export CF_Email="$cf_e"
        $ACME_BIN --issue --dns dns_cf -d $domain --force
    else
        # 1. 预先检查端口占用
        if lsof -i:80 > /dev/null 2>&1; then
            echo -e "${YELLOW}检测到 80 端口占用，尝试停止服务...${PLAIN}"
            systemctl stop nginx >/dev/null 2>&1
            rc-service nginx stop >/dev/null 2>&1
            sleep 1
        fi
        # 2. 仅执行一次申请
        $ACME_BIN --issue -d $domain --standalone --force
    fi

    # 3. 统一判断申请结果并同步
    if [[ -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" ]]; then
        echo -e "${GREEN}[成功] 证书就绪，正在同步至 Xray 目录...${PLAIN}"
        mkdir -p "$CERT_DIR"
        cp -f "$HOME/.acme.sh/${domain}_ecc/${domain}.key" "$CERT_DIR/server.key"
        cp -f "$HOME/.acme.sh/${domain}_ecc/fullchain.cer" "$CERT_DIR/server.crt"
        chmod 644 "$CERT_DIR/server.key" "$CERT_DIR/server.crt"
    else
        echo -e "${RED}[致命错误] 无法获取证书。${PLAIN}"
        echo -e "${YELLOW}请检查解析或防火墙 80 端口。${PLAIN}"
        read -p "按回车键返回..."
        return 1
    fi

    # 【修复重点】：ALPN 格式化，xhttp 模式下直接处理成 JSON 数组字符串
    local alpn_json=$(echo "$alpn" | sed 's/,/","/g')

    echo -e "${BLUE}[进度] 正在写入核心配置 (IPv6 优先出站模式)...${PLAIN}"

# 运行检测
check_network_strategy

# 核心配置写入 (修正 listen 为双栈支持，修正 ALPN 引号错误)
cat <<EOF > $XRAY_CONF_DIRECT
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "listen": "::",
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
                "alpn": ["$alpn_json"],
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

    # --- 【优化后的强力重启逻辑】 ---
    echo -e "${BLUE}[进度] 正在重启 Xray 服务并校验配置...${PLAIN}"
    
    # 1. 预校验配置语法
    /usr/local/bin/xray -test -confdir /usr/local/etc/xray/ >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误] 配置文件语法校验失败！${PLAIN}"
        /usr/local/bin/xray -test -confdir /usr/local/etc/xray/
        read -p "按回车键返回..."
        return 1
    fi

    # 2. 兼容性重启
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl stop xray >/dev/null 2>&1
        pkill -9 xray >/dev/null 2>&1
        systemctl start xray
    else
        # Alpine/OpenRC 逻辑，增加 nohup 暴力拉起作为最终兜底
        rc-service xray stop >/dev/null 2>&1
        pkill -9 xray >/dev/null 2>&1
        rc-service xray start >/dev/null 2>&1
        sleep 1
        if ! pgrep -x "xray" > /dev/null; then
            echo -e "${YELLOW}OpenRC 启动失败，尝试使用 nohup 强制拉起...${PLAIN}"
            nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
        fi
    fi
    
    sleep 2
    
    # 3. 最终状态检测
    if pgrep -x "xray" > /dev/null; then
        echo -e "${GREEN}VLESS+xhttp+TLS 部署成功！${PLAIN}"
        show_node_info
    else
        echo -e "${RED}[错误] Xray 启动失败。${PLAIN}"
        echo -e "${YELLOW}正在进行配置诊断...${PLAIN}"
        /usr/local/bin/xray -test -confdir /usr/local/etc/xray/
        read -p "按回车键返回..."
    fi
}

# --- 3. 安装 CF Tunnel (修正版) ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS 模式) ---${PLAIN}"

    # --- 2. 生成默认值 ---
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))

    # --- 用户输入区 ---    
    echo -e "选择隧道类型: 1.临时隧道 2.固定隧道"
    read -p "选择 [1-2]: " t_choice
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid
    t_uuid=${t_uuid:-$r_t_uuid}
    read -p "请输入自定义节点名称 (默认: CF_Tunnel): " t_node_name
    t_node_name=${t_node_name:-"CF_Tunnel"}
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path
    t_path=${t_path:-$r_t_path}

    local t_domain=""
    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 Cloudflare 绑定的域名 (如 tunnel.example.com): " t_domain
        [[ -z "$t_domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
        read -p "请输入 Token: " t_token
        [[ -z "$t_token" ]] && { echo -e "${RED}Token不能为空！${PLAIN}"; return; }
        echo "$t_domain" > /usr/local/etc/xray/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port
        t_port=${t_port:-$r_t_port}
    fi

    # 运行检测
    check_network_strategy

    # 【关键修正 1】：删掉重复的 "log" 结构，防止与 conf_1_direct.json 冲突导致合并失败
    # 【关键修正 2】：监听 127.0.0.1 避免与公网 IP 上的服务竞争
    cat <<EOF > "$XRAY_CONF_TUNNEL"
{
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
    }]
}
EOF

    # --- 【关键修正 3：强化重启逻辑】 ---
    echo -e "${BLUE}[进度] 正在同步重启服务并校验配置...${PLAIN}"
    
    # 低内存环境强制预清理
    sync && echo 3 > /proc/sys/vm/drop_caches
    
    # 强制杀死残留 Xray，确保端口 100% 释放后再校验
    pkill -9 xray >/dev/null 2>&1
    sleep 1

    # 执行预校验
    if ! /usr/local/bin/xray -test -confdir /usr/local/etc/xray/ >/tmp/xray_test.log 2>&1; then
        echo -e "${RED}[错误] 隧道配置校验失败或与现有配置冲突！${PLAIN}"
        echo -e "${YELLOW}错误原因如下：${PLAIN}"
        cat /tmp/xray_test.log
        read -p "按回车键返回..."
        return 1
    fi

    # 2. 兼容性启动服务
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl start xray
    else
        rc-service xray start >/dev/null 2>&1
        sleep 1
        if ! pgrep -x "xray" > /dev/null; then
            nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
        fi
    fi

    # --- 隧道核心 Cloudflared 部分 ---
    [[ -z "$CF_ARCH" ]] && detect_arch
    if [[ ! -f $CF_BIN ]]; then
        echo -e "${YELLOW}正在下载 cloudflared ($CF_ARCH)...${PLAIN}"
        wget -O $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        chmod +x $CF_BIN
    fi
    
    # 杀掉旧的隧道进程
    pkill -9 cloudflared >/dev/null 2>&1
    : > "$CF_LOG"

    local cf_cmd=""
    if [[ "$t_choice" == "1" ]]; then
        cf_cmd="tunnel --protocol http2 --logfile $CF_LOG --url http://localhost:$t_port"
    else
        cf_cmd="tunnel --no-autoupdate run --token $t_token"
    fi

    # 写入服务并启动（OpenRC/Systemd）
    if [ "$HAS_SYSTEMD" = true ]; then
        cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel Service
After=network.target
[Service]
ExecStart=$CF_BIN $cf_cmd
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now cloudflared
    elif grep -qi "alpine" /etc/os-release; then
        cat <<EOF > /etc/init.d/cloudflared
#!/sbin/openrc-run
command="$CF_BIN"
command_args="$cf_cmd"
command_background="yes"
pidfile="/run/cloudflared.pid"
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default >/dev/null 2>&1
        rc-service cloudflared restart >/dev/null 2>&1
    fi

    # 临时域名抓取
    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在尝试抓取临时域名 (最长等待 30s)...${PLAIN}"
        for i in {1..30}; do
            echo -ne "\r正在尝试抓取域名: ${i}s..."
            if [[ -s $CF_LOG ]]; then
                tmp_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
                if [[ -n "$tmp_domain" ]]; then
                    echo -e "\n${GREEN}抓取成功！域名: $tmp_domain${PLAIN}"
                    echo "$tmp_domain" > /usr/local/etc/xray/cf_tunnel_domain
                    break
                fi
            fi
            sleep 1
        done
        [[ -z "$tmp_domain" ]] && echo -e "\n${RED}域名抓取超时，请查看日志: $CF_LOG${PLAIN}"
    fi
    
    show_node_info
}

# --- 4. 查看当前节点信息与链接  ---
show_node_info() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━ 当前已部署节点列表 ━━━━━━━━━━━━━━${PLAIN}"
    
    # --- 1. 处理直连节点 (VLESS + xhttp + TLS) ---
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
        local d_path_enc=$(echo "$d_path" | sed 's/\//%2F/g')

        echo -e "${GREEN}[节点: $d_name]${PLAIN}"
        echo -e "  类型: VLESS + xhttp + TLS"
        echo -e "  链接: ${CYAN}vless://$d_uuid@$final_host:$d_port?security=tls&sni=$d_host&type=xhttp&mode=auto&path=$d_path_enc&fp=$d_fp&alpn=$d_alpn#$d_name${PLAIN}"
        echo -e "------------------------------------------------"
    fi

    # --- 2. 处理隧道节点 (CF Tunnel + WS) ---
    if [[ -f "$XRAY_CONF_TUNNEL" ]]; then
        local t_name=$(jq -r '.inbounds[0].tag' $XRAY_CONF_TUNNEL)
        local t_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF_TUNNEL)
        local t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' $XRAY_CONF_TUNNEL)
        # 【修复】：读取持久化路径
        local t_url=$(cat /usr/local/etc/xray/cf_tunnel_domain 2>/dev/null)
        local t_alpn="h2%2Chttp%2F1.1"
        local t_path_enc=$(echo "$t_path" | sed 's/\//%2F/g')
        
        echo -e "${PURPLE}[节点: $t_name]${PLAIN}"
        if [[ -n "$t_url" ]]; then
            # 【修复】：使用编码后的 t_alpn
            echo -e "  链接: ${YELLOW}vless://$t_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&host=$t_url&path=$t_path_enc&fp=chrome&alpn=$t_alpn#$t_name${PLAIN}"
        else
            echo -e "  ${RED}错误: 未找到隧道域名，请检查 cloudflared 是否运行正常${PLAIN}"
        fi
        echo -e "------------------------------------------------"
    fi

    read -p "按回车键返回菜单..."
}
# --- 5.1 仅卸载 Xray (保留 CF Tunnel) ---
uninstall_xray() {
    echo -e "${RED}警告：此操作将仅卸载 Xray 核心、直连节点配置及证书。${PLAIN}"
    read -p "确定要卸载 Xray 吗？[y/n]: " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}正在停止 Xray 服务...${PLAIN}"
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1

    echo -e "${YELLOW}清理 Xray 文件及配置...${PLAIN}"
    # 移除服务定义 (兼容 Systemd & OpenRC)
    rm -f /etc/systemd/system/xray.service
    if [ -f "/etc/init.d/xray" ]; then
        rc-update del xray default >/dev/null 2>&1
        rm -f /etc/init.d/xray
    fi
    systemctl daemon-reload
    
    rm -rf /usr/local/etc/xray/conf_1_direct.json
    rm -rf /usr/local/etc/xray/certs
    rm -f /usr/local/bin/xray
    rm -f /usr/local/share/xray
    rm -f /var/log/xray/access.log /var/log/xray/error.log
    
    echo -e "${GREEN}Xray 及直连节点卸载完成！(若安装了 CF Tunnel，则隧道仍保留运行)${PLAIN}"
    read -p "按回车键返回..."
}

# --- 5.2 仅卸载 CF Tunnel (保留 Xray) ---
uninstall_cf() {
    echo -e "${RED}警告：此操作将仅卸载 Cloudflare Tunnel 及隧道节点配置。${PLAIN}"
    read -p "确定要卸载 CF Tunnel 吗？[y/n]: " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}正在停止 Cloudflared 服务...${PLAIN}"
    systemctl stop cloudflared >/dev/null 2>&1
    systemctl disable cloudflared >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1

    echo -e "${YELLOW}清理 Cloudflared 文件及配置...${PLAIN}"
    # 移除服务定义 (兼容 Systemd & OpenRC)
    rm -f /etc/systemd/system/cloudflared.service
    if [ -f "/etc/init.d/cloudflared" ]; then
        rc-update del cloudflared default >/dev/null 2>&1
        rm -f /etc/init.d/cloudflared
    fi
    systemctl daemon-reload
    
    rm -f /usr/local/bin/cloudflared
    rm -f /tmp/cloudflared.log
    # 【修复】统一清理持久化路径下的域名文件
    rm -f /usr/local/etc/xray/cf_tunnel_domain
    
    # 清理 Xray 中的隧道专属配置文件并重启 Xray
    if [[ -f "/usr/local/etc/xray/conf_2_tunnel.json" ]]; then
        rm -f /usr/local/etc/xray/conf_2_tunnel.json
        systemctl restart xray >/dev/null 2>&1
    fi
    
    echo -e "${GREEN}CF Tunnel 卸载完成！(Xray 直连节点仍正常保留)${PLAIN}"
    read -p "按回车键返回..."
}

# --- 5.3 彻底卸载 (全环境清理版) ---
uninstall_all() {
    echo -e "${RED}！！！警告：此操作将彻底删除所有节点配置、证书及服务 ！！！${PLAIN}"
    read -p "确定要清空所有数据并卸载吗？[y/n]: " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}[1/5] 正在停止相关服务与进程...${PLAIN}"
    systemctl stop xray cloudflared >/dev/null 2>&1
    pkill -9 xray >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1

    echo -e "${YELLOW}[2/5] 正在移除服务定义与自启动配置...${PLAIN}"
    systemctl disable xray cloudflared >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/cloudflared.service
    
    # Alpine 深度清理
    if command -v rc-update >/dev/null 2>&1; then
        rc-update del xray default >/dev/null 2>&1
        rc-update del cloudflared default >/dev/null 2>&1
        rm -f /etc/init.d/xray /etc/init.d/cloudflared
    fi
    systemctl daemon-reload

    echo -e "${YELLOW}[3/5] 正在清理安装目录与核心文件...${PLAIN}"
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray /usr/local/bin/cloudflared

    echo -e "${YELLOW}[4/5] 正在清理日志、证书及临时数据...${PLAIN}"
    rm -f /tmp/cloudflared.log /var/log/xray_keep_alive.log
    rm -rf ~/.acme.sh

    echo -e "${YELLOW}[5/5] 正在释放守护任务与系统别名...${PLAIN}"
    rm -f /usr/local/bin/xray_keep_alive.sh
    # 清理 Crontab
    crontab -l 2>/dev/null | grep -vE "acme.sh|xray_keep_alive.sh|cleanup_logs" | crontab - >/dev/null 2>&1
    
    if [[ -f ~/.bashrc ]]; then
        sed -i '/acme.sh/d' ~/.bashrc
    fi

    echo -e "------------------------------------------------"
    echo -e "${GREEN}彻底卸载完成！系统已恢复至干净状态。${PLAIN}"
    echo -e "------------------------------------------------"
    read -p "按回车键返回菜单..."
}
# --- 5.4 卸载子菜单控制台 ---
uninstall_menu() {
    while true; do
        clear
        echo -e "
${CYAN}==========================================
             ⚙️ 卸载管理菜单
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 仅卸载 Xray (VLESS+xhttp) 及证书
 ${YELLOW}2.${PLAIN} 仅卸载 Cloudflare Tunnel 隧道
 ${RED}3.${PLAIN} 彻底卸载所有组件 (包含脚本数据)
 ${YELLOW}0.${PLAIN} 返回主菜单"
        read -p "选择 [0-3]: " un_choice
        case $un_choice in
            1) uninstall_xray ; break ;;
            2) uninstall_cf ; break ;;
            3) uninstall_all ; break ;;
            0) break ;;
            *) echo -e "${RED}输入错误${PLAIN}" && sleep 1 ;;
        esac
    done
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
 ${YELLOW}5.${PLAIN} 卸载管理 (支持单独卸载/彻底清理)  
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
            5) uninstall_menu ;;
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
    
    cat <<EOF > /usr/local/bin/xray_keep_alive.sh
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# OpenRC 兼容层 (Alpine专属)
if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
    systemctl() {
        local action=\$1
        local service=\${2%.service}
        case "\$action" in
            start|stop|restart) rc-service "\$service" "\$action" >/dev/null 2>&1 ;;
            is-active) rc-service "\$service" status 2>/dev/null | grep -q "started" ;;
            list-unit-files) ls /etc/init.d/ ;;
            *) return 0 ;;
        esac
    }
fi

if ! systemctl is-active --quiet xray; then
    echo "\$(date): Xray 掉线，正在尝试拉起..." >> /var/log/xray_keep_alive.log
    systemctl start xray
fi

if systemctl list-unit-files | grep -q cloudflared; then
    if ! systemctl is-active --quiet cloudflared; then
        echo "\$(date): Cloudflared 掉线，正在尝试拉起..." >> /var/log/xray_keep_alive.log
        systemctl start cloudflared
    fi
fi
EOF
    chmod +x /usr/local/bin/xray_keep_alive.sh

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
