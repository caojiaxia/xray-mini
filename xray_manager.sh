#!/bin/bash

# ====================================================
# Project: Xray xhttp & CF Tunnel 
# Author: BoGe (Optimized for caojiaxia)
# System: Debian/Ubuntu/CentOS
# ====================================================

# 1. 基础配置与颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray/certs"
CF_LOG="/tmp/cloudflared.log"

# --- 内部核心函数 ---

# 检查并安装基础依赖
install_base() {
    echo -e "${BLUE}开始环境检查...${PLAIN}"
    if [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl wget tar openssl jq socat cron
    elif [[ -f /usr/bin/yum ]]; then
        yum makecache && yum install -y curl wget tar openssl jq socat crontabs
    fi
    mkdir -p /usr/local/etc/xray $CERT_DIR
}

# 智能获取或生成 Xray 参数 (保持配置一致性)
get_xray_params() {
    if [[ -f $XRAY_CONFIG ]]; then
        UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONFIG)
        PORT=$(jq -r '.inbounds[0].port' $XRAY_CONFIG)
        XPATH=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $XRAY_CONFIG)
        HOST=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $XRAY_CONFIG)
    fi

    # 如果没有旧配置，则初始化默认值
    [[ -z "$UUID" || "$UUID" == "null" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
    [[ -z "$PORT" || "$PORT" == "null" ]] && PORT=8080
    [[ -z "$XPATH" || "$XPATH" == "null" ]] && XPATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    [[ -z "$HOST" || "$HOST" == "null" ]] && HOST="www.bing.com"
}

# 核心：写入 Xray 配置文件
# 参数: $1=security(tls/none)
write_config() {
    local sec=$1
    get_xray_params
    
    # 构造 TLS 部分
    local tls_json=""
    if [[ "$sec" == "tls" ]]; then
        tls_json=', "tlsSettings": { "certificates": [{ "certificateFile": "'$CERT_DIR'/server.crt", "keyFile": "'$CERT_DIR'/server.key" }], "alpn": ["h2", "http/1.1"], "fingerprint": "chrome" }'
    fi

    cat <<EOF > $XRAY_CONFIG
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $PORT,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$UUID", "email": "user@xhttp"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "$sec",
            "xhttpSettings": { "path": "$XPATH", "mode": "auto", "host": "$HOST" }${tls_json}
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    # 确保 Xray 已安装
    if [[ ! -f /usr/local/bin/xray ]]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi
    systemctl enable xray && systemctl restart xray
}

# --- 菜单功能模块 ---

# 选项 1：完整证书+直连模式
mod_direct_tls() {
    install_base
    echo -e "${CYAN}--- 证书申请模块 (完整版) ---${PLAIN}"
    read -p "请输入解析域名: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空${PLAIN}"; return; }

    # 安装 acme.sh
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
        source ~/.bashrc
    fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo -e "\n请选择证书验证方式:"
    echo -e "1. Standalone (自动开启80端口验证)"
    echo -e "2. Cloudflare API (推荐，输入 API Key 验证)"
    read -p "选择 [1-2]: " c_method

    if [[ "$c_method" == "2" ]]; then
        read -p "CF Email: " cf_email
        read -p "CF Global API Key: " cf_key
        export CF_Key="$cf_key"
        export CF_Email="$cf_email"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain --debug
    else
        ~/.acme.sh/acme.sh --issue -d $domain --standalone --debug
    fi

    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d $domain \
        --key-file $CERT_DIR/server.key \
        --fullchain-file $CERT_DIR/server.crt \
        --reloadcmd "systemctl restart xray"

    write_config "tls"
    echo -e "${GREEN}直连模式配置完成！${PLAIN}"
    show_links
}

# 选项 2：独立隧道模式
mod_tunnel_only() {
    install_base
    # 如果没有 Xray 配置，先生成一个默认的（不带证书）
    if [[ ! -f $XRAY_CONFIG ]]; then
        echo -e "${YELLOW}未检测到 Xray 配置，正在自动初始化后端服务...${PLAIN}"
        write_config "none"
    else
        # 如果已经有配置，直接重启以防万一
        systemctl restart xray
    fi

    # 下载 cloudflared
    echo -e "${BLUE}获取最新版 cloudflared...${PLAIN}"
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared

    get_xray_params
    echo -e "${YELLOW}正在通过 HTTP2 协议建立隧道，回源端口: $PORT...${PLAIN}"
    pkill -f cloudflared > /dev/null 2>&1
    rm -f $CF_LOG
    
    # 启动隧道
    nohup /usr/local/bin/cloudflared tunnel --protocol http2 --url http://localhost:$PORT > $CF_LOG 2>&1 &
    
    # 循环检测域名生成
    for i in {1..20}; do
        echo -ne "\r检测进度: ${i}s..."
        if grep -q "trycloudflare.com" $CF_LOG; then
            echo -e "\n${GREEN}临时隧道已成功启动！${PLAIN}"
            show_links
            return
        fi
        sleep 1
    done
    echo -e "\n${RED}隧道启动超时，请 cat /tmp/cloudflared.log 查看原因。${PLAIN}"
}

# 选项 3：智能链接展示
show_links() {
    if [[ ! -f $XRAY_CONFIG ]]; then
        echo -e "${RED}错误：未发现 Xray 配置文件，请先执行安装选项。${PLAIN}"; return
    fi
    
    get_xray_params
    local sec_status=$(jq -r '.inbounds[0].streamSettings.security' $XRAY_CONFIG)
    local acme_domain=$(~/.acme.sh/acme.sh --list 2>/dev/null | awk 'NR==2 {print $1}')

    echo -e "\n${GREEN}━━━━━━━━━━━━━━━ 节点信息 ━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${BLUE}UUID:${PLAIN}   $UUID"
    echo -e "${BLUE}Path:${PLAIN}   $XPATH"
    echo -e "${BLUE}SNI:${PLAIN}    $HOST (直连使用)"
    echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 1. 检查临时隧道
    if [[ -f $CF_LOG ]]; then
        local t_domain=$(grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
        if [[ -n "$t_domain" ]]; then
            echo -e "${PURPLE}[模式] Cloudflare 临时隧道${PLAIN}"
            echo -e "地址: ${t_domain}  端口: 443"
            echo -e "链接: ${CYAN}vless://$UUID@$t_domain:443?security=tls&sni=$t_domain&type=xhttp&mode=auto&path=${XPATH}#CF_Tunnel${PLAIN}"
            echo -e "---------------------------------------"
        fi
    fi

    # 2. 检查域名直连
    if [[ "$sec_status" == "tls" && -n "$acme_domain" ]]; then
        echo -e "${BLUE}[模式] 域名直连 TLS${PLAIN}"
        echo -e "地址: ${acme_domain}  端口: $PORT"
        echo -e "链接: ${CYAN}vless://$UUID@$acme_domain:$PORT?security=tls&sni=$HOST&type=xhttp&mode=auto&path=${XPATH}#Direct_TLS${PLAIN}"
        echo -e "---------------------------------------"
    fi
}

# --- 主菜单 ---
main_menu() {
    clear
    echo -e "
${CYAN}==========================================
      BoGe Xray xhttp & CF Tunnel
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS+xhttp (完整域名直连模式)
    ${YELLOW}*${PLAIN} 含 acme.sh 完整证书模块 (支持 CF API)
 
 ${YELLOW}2.${PLAIN} 安装 CF Tunnel (独立临时隧道模式)
    ${YELLOW}*${PLAIN} 自动适配 Xray 参数，无需证书即可运行
 
 ${YELLOW}3.${PLAIN} 查看当前所有可用的节点链接
 ${YELLOW}4.${PLAIN} 开启系统 BBR 加速
 ${YELLOW}5.${PLAIN} 彻底卸载 Xray、证书及隧道
 ${RED}0.${PLAIN} 退出脚本
"
    read -p "选择操作: " choice
    case $choice in
        1) mod_direct_tls ;;
        2) mod_tunnel_only ;;
        3) show_links ;;
        4) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf && sysctl -p ;;
        5) systemctl stop xray && pkill -f cloudflared && rm -rf /usr/local/etc/xray /usr/local/bin/cloudflared $CF_LOG ;;
        0) exit 0 ;;
        *) echo "无效选择"; sleep 1; main_menu ;;
    esac
    echo -e "\n按回车键返回菜单..."
    read -n 1 && main_menu
}

main_menu
