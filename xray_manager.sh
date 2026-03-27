#!/bin/bash

# ====================================================
# Project: Xray xhttp & CF Tunnel一键脚本
# Author: BoGe
# System: Debian/Ubuntu/CentOS
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 路径定义
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/usr/local/etc/xray/certs"
CF_LOG="/tmp/cloudflared.log"

# 1. 基础环境检查与依赖安装
install_dependencies() {
    echo -e "${BLUE}[1/5] 正在检查并安装系统依赖...${PLAIN}"
    if [[ -f /usr/bin/apt ]]; then
        apt update
        apt install -y curl wget tar openssl jq socat cron
    elif [[ -f /usr/bin/yum ]]; then
        yum makecache
        yum install -y curl wget tar openssl jq socat crontabs
    fi
    echo -e "${GREEN}依赖安装完成。${PLAIN}"
}

# 2. 证书申请模块
manage_certs() {
    echo -e "${BLUE}[2/5] 开始证书管理程序...${PLAIN}"
    read -p "请输入您的解析域名: " domain
    if [[ -z "$domain" ]]; then echo -e "${RED}域名不能为空！${PLAIN}"; return 1; fi

    echo -e "${YELLOW}正在检查 acme.sh 环境...${PLAIN}"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo -e "\n${CYAN}选择证书申请方式:${PLAIN}"
    echo -e "1. Standalone 模式 (需确保 80 端口未被占用)"
    echo -e "2. Cloudflare API 模式 (推荐，无需开放端口)"
    read -p "请输入选择 [1-2]: " cert_method

    mkdir -p $CERT_DIR

    if [[ "$cert_method" == "2" ]]; then
        echo -e "${YELLOW}使用 Cloudflare API 申请...${PLAIN}"
        read -p "请输入 Cloudflare Email: " cf_email
        read -p "请输入 Cloudflare Global API Key: " cf_key
        export CF_Key="$cf_key"
        export CF_Email="$cf_email"
        
        if ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain --debug; then
            echo -e "${GREEN}API 模式证书申请成功！${PLAIN}"
        else
            echo -e "${RED}申请失败，请检查 API Key。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${YELLOW}使用 Standalone 模式申请...${PLAIN}"
        if ~/.acme.sh/acme.sh --issue -d $domain --standalone --debug; then
            echo -e "${GREEN}Standalone 模式证书申请成功！${PLAIN}"
        else
            echo -e "${RED}申请失败，请检查 80 端口。${PLAIN}"
            exit 1
        fi
    fi

    ~/.acme.sh/acme.sh --install-cert -d $domain \
        --key-file $CERT_DIR/server.key \
        --fullchain-file $CERT_DIR/server.crt \
        --reloadcmd "systemctl restart xray"
}

# 3. 安装 Xray 并配置 xhttp
install_vless_xhttp() {
    echo -e "${BLUE}[3/5] 正在安装 Xray 核心二进制文件...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    echo -e "${PURPLE}--- 开始节点参数设置 ---${PLAIN}"
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo -e "生成随机 UUID: ${CYAN}$uuid${PLAIN}"
    
    read -p "设置监听端口 (回车随机, 隧道建议 8080): " port
    [[ -z "$port" ]] && port=$((RANDOM % 55535 + 10000))
    
    read -p "设置 xhttp 路径 (回车随机): " path
    [[ -z "$path" ]] && path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    
    read -p "设置伪装域名 (SNI, 默认 www.bing.com): " sni
    [[ -z "$sni" ]] && sni="www.bing.com"
    
    cat <<EOF > $XRAY_CONFIG
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{"id": "$uuid", "email": "user@xhttp"}],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "tls",
            "xhttpSettings": {
                "path": "$path",
                "mode": "auto",
                "host": "$sni"
            },
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$CERT_DIR/server.crt",
                    "keyFile": "$CERT_DIR/server.key"
                }],
                "alpn": ["h2", "http/1.1"],
                "fingerprint": "chrome"
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    systemctl enable xray && systemctl restart xray
    echo -e "${GREEN}Xray 服务已就绪！本地端口: $port${PLAIN}"
}

# 4. Cloudflare Tunnel 隧道配置 (修复版)
install_cf_tunnel() {
    echo -e "${BLUE}[4/5] 正在部署 Cloudflare Tunnel...${PLAIN}"
    
    # 强制下载 x86_64 版本
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
    
    echo -e "\n${CYAN}请选择隧道类型:${PLAIN}"
    echo -e "1. 固定隧道 (需登录授权)"
    echo -e "2. 临时隧道 (TryCloudflare)"
    read -p "请输入选择 [1-2]: " tunnel_type

    if [[ "$tunnel_type" == "2" ]]; then
        read -p "请输入 Xray 监听的本地端口 (刚才设置的端口, 默认 8080): " local_port
        [[ -z "$local_port" ]] && local_port=8080
        
        echo -e "${YELLOW}正在通过 HTTP2 协议启动隧道并等待域名全路径...${PLAIN}"
        pkill -f cloudflared > /dev/null 2>&1
        rm -f $CF_LOG
        
        # 使用 --protocol http2 提高稳定性
        nohup /usr/local/bin/cloudflared tunnel --protocol http2 --url http://localhost:$local_port > $CF_LOG 2>&1 &
        
        # 增加循环检测，每秒检查一次，共 30 秒
        for i in {1..30}; do
            echo -ne "\r检测中: ${i}s..."
            tunnel_url=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
            if [[ -n "$tunnel_url" ]]; then
                echo -e "\n${GREEN}临时隧道获取成功！${PLAIN}"
                echo -e "地址: ${CYAN}$tunnel_url${PLAIN}"
                return 0
            fi
            sleep 1
        done
        echo -e "\n${RED}获取超时，请手动运行命令检查: cat $CF_LOG${PLAIN}"
    else
        echo -e "固定隧道请先运行: ${CYAN}cloudflared tunnel login${PLAIN}"
    fi
}

# 5. 节点输出链接 (增强临时域名识别)
show_node_links() {
    if [[ ! -f $XRAY_CONFIG ]]; then
        echo -e "${RED}错误：未发现配置文件！${PLAIN}"
        return
    fi
    
    local _uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONFIG)
    local _port=$(jq -r '.inbounds[0].port' $XRAY_CONFIG)
    local _path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $XRAY_CONFIG)
    local _sni=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $XRAY_CONFIG)
    local _domain=$(~/.acme.sh/acme.sh --list | awk 'NR==2 {print $1}')

    echo -e "\n${GREEN}========= 节点详情 (XHTTP+TLS) =========${PLAIN}"
    [[ -n "$_domain" ]] && echo -e "${BLUE}解析域名:${PLAIN} $_domain"
    echo -e "${BLUE}本地端口:${PLAIN} $_port"
    echo -e "${BLUE}UUID:${PLAIN} $_uuid"
    echo -e "${BLUE}路径:${PLAIN} $_path"
    echo -e "------------------------------------------"
    
    # 动态获取日志里的临时域名
    if [[ -f $CF_LOG ]]; then
        local _tmp_url=$(grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
        if [[ -n "$_tmp_url" ]]; then
            echo -e "${PURPLE}临时隧道 URL:${PLAIN} ${_tmp_url}"
        fi
    fi
    
    echo -e "${YELLOW}VLESS 链接:${PLAIN}"
    echo -e "${CYAN}vless://$_uuid@$_domain:$_port?security=tls&sni=$_sni&type=xhttp&mode=auto&path=${_path}#BoGe_XHTTP${PLAIN}"
    echo -e "------------------------------------------"
}

# 6. BBR 加速安装
install_bbr() {
    echo -e "${BLUE}正在开启 BBR 加速...${PLAIN}"
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR 已开启！${PLAIN}"
}

# 7. 卸载功能
uninstall_all() {
    echo -e "${RED}正在清理系统...${PLAIN}"
    systemctl stop xray && pkill -f cloudflared
    rm -rf /usr/local/etc/xray /usr/local/bin/cloudflared $CF_LOG
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# 菜单循环保持不变...
main_menu() {
    while true; do
        echo -e "
${CYAN}==========================================
      BoGe Xray xhttp & CF Tunnel
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS + xhttp + TLS (含API证书)
 ${YELLOW}2.${PLAIN} 配置 CF Tunnel (固定/临时隧道)
 ${YELLOW}3.${PLAIN} 查看节点连接信息与链接
 ${YELLOW}4.${PLAIN} 仅查看节点参数配置 (JSON)
 ${YELLOW}5.${PLAIN} 开启系统 BBR 加速
 ${YELLOW}6.${PLAIN} 卸载 Xray / 证书 / 隧道
 ${RED}0.${PLAIN} 退出脚本
"
        read -p "选择操作 [0-6]: " choice
        case $choice in
            1) install_dependencies; manage_certs; install_vless_xhttp ;;
            2) install_cf_tunnel ;;
            3) show_node_links ;;
            4) [[ -f $XRAY_CONFIG ]] && jq . $XRAY_CONFIG || echo "无配置" ;;
            5) install_bbr ;;
            6) uninstall_all ;;
            0) exit 0 ;;
        esac
        echo -e "\n按回车键返回菜单..."
        read -n 1
    done
}

main_menu
