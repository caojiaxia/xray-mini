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

# 2. 证书申请模块 (包含 Standalone 和 API 模式)
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
            echo -e "${RED}申请失败，请检查 API Key 是否正确。${PLAIN}"
            exit 1
        fi
    else
        echo -e "${YELLOW}使用 Standalone 模式申请...${PLAIN}"
        if ~/.acme.sh/acme.sh --issue -d $domain --standalone --debug; then
            echo -e "${GREEN}Standalone 模式证书申请成功！${PLAIN}"
        else
            echo -e "${RED}申请失败，请确保 80 端口已放行且域名解析正确。${PLAIN}"
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
    
    read -p "设置监听端口 (回车随机, 如需配隧道建议8080): " port
    [[ -z "$port" ]] && port=$((RANDOM % 55535 + 10000))
    
    read -p "设置 xhttp 路径 (回车随机): " path
    [[ -z "$path" ]] && path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    
    read -p "设置伪装域名 (SNI, 回车默认 www.bing.com): " sni
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
    echo -e "${GREEN}Xray 服务已就绪 (端口: $port)！${PLAIN}"
}

# 4. Cloudflare Tunnel 隧道配置 (新增临时隧道逻辑)
install_cf_tunnel() {
    echo -e "${BLUE}[4/5] 正在部署 Cloudflare Tunnel...${PLAIN}"
    echo -e "${YELLOW}正在获取最新版 cloudflared 二进制...${PLAIN}"
    wget -O /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x /usr/local/bin/cloudflared
    
    echo -e "\n${CYAN}请选择隧道类型:${PLAIN}"
    echo -e "1. 固定隧道 (Named Tunnel, 需登录授权)"
    echo -e "2. 临时隧道 (TryCloudflare, 自动生成域名)"
    read -p "请输入选择 [1-2]: " tunnel_type

    if [[ "$tunnel_type" == "2" ]]; then
        echo -e "${YELLOW}正在启动临时隧道...${PLAIN}"
        read -p "请输入 Xray 监听的本地端口 (默认 8080): " local_port
        [[ -z "$local_port" ]] && local_port=8080
        
        # 杀掉之前的临时隧道进程
        pkill -f cloudflared > /dev/null 2>&1
        rm -f $CF_LOG
        
        # 后台运行临时隧道并记录日志
        nohup cloudflared tunnel --url http://localhost:$local_port > $CF_LOG 2>&1 &
        
        echo -n "正在等待隧道分配域名..."
        sleep 5
        tunnel_url=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
        
        if [[ -n "$tunnel_url" ]]; then
            echo -e "\n${GREEN}临时隧道已就绪！${PLAIN}"
            echo -e "隧道地址: ${CYAN}$tunnel_url${PLAIN}"
            echo -e "${YELLOW}注意: 临时隧道重启服务器后需重新运行脚本开启。${PLAIN}"
        else
            echo -e "\n${RED}隧道启动超时，请查看日志: $CF_LOG${PLAIN}"
        fi
    else
        echo -e "${PURPLE}--- 固定隧道配置说明 ---${PLAIN}"
        echo -e "1. 请执行 ${CYAN}cloudflared tunnel login${PLAIN} 进行授权"
        echo -e "2. 固定隧道回源端口建议设为: ${CYAN}8080${PLAIN}"
        echo -e "3. 前端随机端口需在 CF 控制面板手动映射。"
    fi
}

# 5. 节点输出链接
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
    echo -e "${BLUE}ALPN:${PLAIN} h2, http/1.1"
    echo -e "------------------------------------------"
    
    # 尝试显示临时隧道地址
    if [[ -f $CF_LOG ]]; then
        local _tmp_url=$(grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
        if [[ -n "$_tmp_url" ]]; then
            echo -e "${BLUE}临时隧道:${PLAIN} $_tmp_url (回源端口: $_port)"
        fi
    fi
    
    echo -e "${YELLOW}VLESS 链接 (直连/API域名):${PLAIN}"
    echo -e "${CYAN}vless://$_uuid@$_domain:$_port?security=tls&sni=$_sni&type=xhttp&mode=auto&path=${_path}#BoGe_XHTTP_TLS${PLAIN}"
    echo -e "------------------------------------------"
}

# 6. BBR 加速安装
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
    pkill -f cloudflared
    rm -rf /usr/local/bin/xray /usr/local/etc/xray
    rm -rf ~/.acme.sh
    rm -f /usr/local/bin/cloudflared $CF_LOG
    echo -e "${GREEN}清理完成。${PLAIN}"
}

# --- 菜单循环 ---
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
               [[ -f $XRAY_CONFIG ]] && jq . $XRAY_CONFIG || echo "无配置"
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
