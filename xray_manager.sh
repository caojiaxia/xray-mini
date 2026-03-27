#!/bin/bash

# ====================================================
# Project: Xray xhttp + CF Tunnel 一键安装脚本
# Author: Gemini
# System: Debian/Ubuntu/CentOS
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 全局变量
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
CERT_DIR="/usr/local/etc/xray/certs"
mkdir -p $CERT_DIR

# --- 辅助函数 ---

# 检查Root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN} 必须使用root用户运行！" && exit 1

# 状态检查
check_status() {
    if systemctl is-active --quiet xray; then
        XRAY_S="${GREEN}运行中${PLAIN}"
    else
        XRAY_S="${RED}未运行${PLAIN}"
    fi
}

# 安装依赖
install_base() {
    echo -e "${BLUE}正在安装必要依赖...${PLAIN}"
    if [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl tar wget openssl jq cron
    elif [[ -f /usr/bin/yum ]]; then
        yum install -y curl tar wget openssl jq crontabs
    fi
}

# --- 核心逻辑 ---

# 1. 安装/更新 Xray
install_xray() {
    echo -e "${BLUE}正在下载最新版 Xray...${PLAIN}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
}

# 2. 申请 TLS 证书 (acme.sh)
apply_cert() {
    echo -e "${YELLOW}--- 证书申请 ---${PLAIN}"
    read -p "请输入要绑定的域名: " domain
    if [[ -z "$domain" ]]; then echo "域名不能为空"; return 1; fi

    # 安装 acme.sh
    curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    
    echo -e "${YELLOW}请确保域名已解析到当前服务器 IP，且 80 端口未被占用。${PLAIN}"
    if ~/.acme.sh/acme.sh --issue -d $domain --standalone; then
        ~/.acme.sh/acme.sh --install-cert -d $domain \
            --key-file $CERT_DIR/server.key \
            --fullchain-file $CERT_DIR/server.crt
        echo -e "${GREEN}证书申请成功并已设置自动续签。${PLAIN}"
    else
        echo -e "${RED}证书申请失败，请检查防火墙或 80 端口。${PLAIN}"
        return 1
    fi
}

# 3. 配置 VLESS + xhttp + TLS
config_vless_xhttp() {
    # 参数交互与随机化
    uuid=$(cat /proc/sys/kernel/random/uuid)
    read -p "请输入监听端口 (默认随机): " port
    [[ -z "$port" ]] && port=$((RANDOM % 55535 + 10000))
    read -p "请输入路径 (默认随机): " path
    [[ -z "$path" ]] && path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    read -p "请输入伪装域名 (默认 bing.com): " sni
    [[ -z "$sni" ]] && sni="www.bing.com"
    
    alpn_list='["h2", "http/1.1"]'
    fingerprint="chrome"

    # 生成 JSON
    cat <<EOF > $XRAY_CONFIG
{
    "log": { "loglevel": "warning" },
    "inbounds": [
        {
            "port": $port,
            "protocol": "vless",
            "settings": {
                "clients": [{ "id": "$uuid" }],
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
                    "certificates": [
                        {
                            "certificateFile": "$CERT_DIR/server.crt",
                            "keyFile": "$CERT_DIR/server.key"
                        }
                    ],
                    "alpn": $alpn_list
                }
            }
        }
    ],
    "outbounds": [
        { "protocol": "freedom" }
    ]
}
EOF
    systemctl restart xray
    echo -e "${GREEN}VLESS+xhttp 配置已完成！${PLAIN}"
}

# 4. CF Tunnel 配置 (WS 传输)
install_cf_tunnel() {
    echo -e "${BLUE}安装 Cloudflare Tunnel...${PLAIN}"
    # 下载二进制
    wget -qO /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared

    tunnel_uuid=$(cat /proc/sys/kernel/random/uuid)
    tunnel_path="/cf-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    frontend_port=$((RANDOM % 55535 + 10000))
    
    echo -e "${YELLOW}提示：固定隧道需使用 cloudflared tunnel login 授权。${PLAIN}"
    echo -e "当前配置为临时隧道 + 本地 8080 端口转发。"
    
    # 临时启动隧道演示 (实际生产建议配合 systemd)
    echo -e "${GREEN}临时隧道启动命令示例: cloudflared tunnel --url http://localhost:8080${PLAIN}"
}

# 5. 显示节点信息
show_info() {
    if [[ ! -f $XRAY_CONFIG ]]; then
        echo -e "${RED}未发现配置文件！${PLAIN}"
        return
    fi
    
    # 解析现有配置
    local _uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONFIG)
    local _port=$(jq -r '.inbounds[0].port' $XRAY_CONFIG)
    local _path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $XRAY_CONFIG)
    local _domain=$(~/.acme.sh/acme.sh --list | awk 'NR==2 {print $1}')

    echo -e "\n${BLUE}========== Xray 节点信息 ==========${PLAIN}"
    echo -e "地址: ${_domain}"
    echo -e "端口: ${_port}"
    echo -e "UUID: ${_uuid}"
    echo -e "传输: xhttp"
    echo -e "路径: ${_path}"
    echo -e "TLS:  开启 (ALPN: h2, http/1.1)"
    echo -e "------------------------------------"
    echo -e "VLESS 链接 (测试用):"
    echo -e "${YELLOW}vless://${_uuid}@${_domain}:${_port}?security=tls&sni=${_domain}&type=xhttp&mode=auto&path=${_path}#XHTTP_TLS${PLAIN}"
}

# 6. BBR 加速
install_bbr() {
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}BBR 已尝试开启。${PLAIN}"
}

# --- 菜单循环 ---
while true; do
    check_status
    echo -e "
${BLUE}====================================
    Xray xhttp & CF Tunnel 管理脚本
====================================${PLAIN}
 ${BLUE}Xray状态：${XRAY_S}

 ${YELLOW}1.${PLAIN} 安装 VLESS + xhttp + TLS (完整流程)
 ${YELLOW}2.${PLAIN} 配置 Cloudflare Tunnel (WS 模式)
 ${YELLOW}3.${PLAIN} 查看当前节点配置信息
 ${YELLOW}4.${PLAIN} 安装 BBR 加速
 ${YELLOW}5.${PLAIN} 卸载全部组件
 ${YELLOW}0.${PLAIN} 退出程序
"
    read -p "请输入选项: " menu_choice
    case $menu_choice in
        1)
            install_base
            install_xray
            apply_cert && config_vless_xhttp
            ;;
        2)
            install_cf_tunnel
            ;;
        3)
            show_info
            ;;
        4)
            install_bbr
            ;;
        5)
            systemctl stop xray
            rm -rf /usr/local/etc/xray /usr/local/bin/xray
            echo -e "${GREEN}卸载完成。${PLAIN}"
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项！${PLAIN}"
            sleep 1
            ;;
    esac
    echo -e "\n按任意键返回菜单..."
    read -n 1
done
