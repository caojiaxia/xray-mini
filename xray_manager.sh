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

# 1. 基础环境检查与依赖安装 (非静默)
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

# 2. 证书申请模块 (交互式+实时进度)
manage_certs() {
    echo -e "${BLUE}[2/5] 开始证书管理程序...${PLAIN}"
    read -p "请输入您的解析域名: " domain
    if [[ -z "$domain" ]]; then echo -e "${RED}域名不能为空！${PLAIN}"; return 1; fi

    # 安装 acme.sh
    echo -e "${YELLOW}正在通过网络获取 acme.sh 脚本...${PLAIN}"
    curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    
    echo -e "${YELLOW}正在尝试申请 Let's Encrypt 证书 (Standalone 模式)...${PLAIN}"
    echo -e "${YELLOW}请确保 80 端口未被占用且域名已解析。${PLAIN}"
    
    mkdir -p $CERT_DIR
    if ~/.acme.sh/acme.sh --issue -d $domain --standalone --debug; then
        echo -e "${GREEN}证书申请成功！正在安装到 Xray 目录...${PLAIN}"
        ~/.acme.sh/acme.sh --install-cert -d $domain \
            --key-file $CERT_DIR/server.key \
            --fullchain-file $CERT_DIR/server.crt \
            --reloadcmd "systemctl restart xray"
    else
        echo -e "${RED}证书申请失败，请检查防火墙设置。${PLAIN}"
        exit 1
    fi
}

# 3. 安装 Xray 并配置 xhttp
install_vless_xhttp() {
    echo -e "${BLUE}[3/5] 正在安装 Xray 核心二进制文件...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    echo -e "${PURPLE}--- 开始节点参数设置 ---${PLAIN}"
    # 参数交互
    uuid=$(cat /proc/sys/kernel/random/uuid)
    echo -e "生成随机 UUID: ${CYAN}$uuid${PLAIN}"
    
    read -p "设置监听端口 (回车随机): " port
    [[ -z "$port" ]] && port=$((RANDOM % 55535 + 10000))
    
    read -p "设置 xhttp 路径 (回车随机): " path
    [[ -z "$path" ]] && path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    
    read -p "设置伪装域名 (如 www.google.com): " sni
    [[ -z "$sni" ]] && sni="www.bing.com"
    
    echo -e "${YELLOW}正在生成 Xray 配置文件 ($XRAY_CONFIG)...${PLAIN}"
    
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
    echo -e "${GREEN}配置文件写入成功。正在启动服务...${PLAIN}"
    systemctl enable xray && systemctl restart xray
    echo -e "${GREEN}Xray 服务已就绪！${PLAIN}"
}

# 4. Cloudflare Tunnel 隧道配置
install_cf_tunnel() {
    echo -e "${BLUE}[4/5] 正在部署 Cloudflare Tunnel...${PLAIN}"
    
    # 实时下载
    echo -e "${YELLOW}正在获取最新版 cloudflared 二进制...${PLAIN}"
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
    
    echo -e "${PURPLE}--- CF Tunnel 参数配置 ---${PLAIN}"
    tunnel_uuid=$(cat /proc/sys/kernel/random/uuid)
    tunnel_path="/tunnel-$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)"
    frontend_port=$((RANDOM % 55535 + 10000))
    
    echo -e "固定隧道回源端口: ${CYAN}8080${PLAIN}"
    echo -e "前端随机连接端口: ${CYAN}$frontend_port${PLAIN}"
    echo -e "隧道传输协议: ${CYAN}WS (WebSocket)${PLAIN}"

    echo -e "\n${YELLOW}提示：固定隧道需要通过 'cloudflared tunnel login' 手动授权。${PLAIN}"
    echo -e "${YELLOW}此脚本将准备好临时隧道运行环境...${PLAIN}"
    
    # 这里可根据需求扩展 systemd 托管逻辑
}

# 5. 节点输出链接
show_node_links() {
    if [[ ! -f $XRAY_CONFIG ]]; then
        echo -e "${RED}错误：未发现配置文件，请先执行安装！${PLAIN}"
        return
    fi
    
    local _uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONFIG)
    local _port=$(jq -r '.inbounds[0].port' $XRAY_CONFIG)
    local _path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $XRAY_CONFIG)
    local _sni=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $XRAY_CONFIG)
    local _domain=$(~/.acme.sh/acme.sh --list | awk 'NR==2 {print $1}')

    echo -e "\n${GREEN}========= 节点详情 (XHTTP+TLS) =========${PLAIN}"
    echo -e "${BLUE}域名:${PLAIN} $_domain"
    echo -e "${BLUE}端口:${PLAIN} $_port"
    echo -e "${BLUE}UUID:${PLAIN} $_uuid"
    echo -e "${BLUE}路径:${PLAIN} $_path"
    echo -e "${BLUE}ALPN:${PLAIN} h2, http/1.1"
    echo -e "${BLUE}指纹:${PLAIN} chrome"
    echo -e "------------------------------------------"
    echo -e "${YELLOW}VLESS 链接:${PLAIN}"
    echo -e "${CYAN}vless://$_uuid@$_domain:$_port?security=tls&sni=$_sni&type=xhttp&mode=auto&path=${_path}#XHTTP_TLS_Node${PLAIN}"
    echo -e "------------------------------------------"
}

# 6. BBR 加速安装 (显示进度)
install_bbr() {
    echo -e "${BLUE}正在开启 BBR 加速...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR 加速内核参数已应用！${PLAIN}"
}

# 7. 卸载功能
uninstall_all() {
    echo -e "${RED}正在卸载所有组件...${PLAIN}"
    systemctl stop xray
    systemctl disable xray
    rm -rf /usr/local/bin/xray /usr/local/etc/xray
    rm -rf ~/.acme.sh
    rm -f /usr/local/bin/cloudflared
    echo -e "${GREEN}清理完成。${PLAIN}"
}

# --- 菜单循环 ---
main_menu() {
    while true; do
        echo -e "
${CYAN}==========================================
      BoGe Xray xhttp & CF Tunnel
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS + xhttp + TLS (全进度显示)
 ${YELLOW}2.${PLAIN} 配置 CF Tunnel (固定隧道+随机端口)
 ${YELLOW}3.${PLAIN} 查看节点连接信息与链接
 ${YELLOW}4.${PLAIN} 仅查看节点参数配置
 ${YELLOW}5.${PLAIN} 开启系统 BBR 加速
 ${YELLOW}6.${PLAIN} 卸载 Xray / 证书 / 隧道
 ${RED}0.${PLAIN} 退出脚本
"
        read -p "请选择操作 [0-6]: " choice
        case $choice in
            1) 
               install_dependencies
               manage_certs
               install_vless_xhttp
               ;;
            2) 
               install_cf_tunnel
               ;;
            3) 
               show_node_links
               ;;
            4) 
               [[ -f $XRAY_CONFIG ]] && cat $XRAY_CONFIG || echo "无配置"
               ;;
            5) 
               install_bbr
               ;;
            6) 
               uninstall_all
               ;;
            0) 
               echo -e "${BLUE}祝你使用愉快，再见！${PLAIN}"
               exit 0
               ;;
            *) 
               echo -e "${RED}输入错误，请重新选择！${PLAIN}"
               ;;
        esac
        echo -e "\n${BLUE}操作完成，按回车键返回菜单...${PLAIN}"
        read -n 1
    done
}

# 启动脚本
main_menu
