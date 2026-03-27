#!/bin/bash

# ====================================================
# Project: Xray xhttp & CF Tunnel 独立随机化全能脚本 (自动输出版)
# Author: BoGe & User (caojiaxia)
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

# 路径
XRAY_CONF_DIRECT="/usr/local/etc/xray/config.json"
XRAY_CONF_TUNNEL="/usr/local/etc/xray/tunnel_config.json"
CERT_DIR="/usr/local/etc/xray/certs"
CF_LOG="/tmp/cloudflared.log"
CF_BIN="/usr/local/bin/cloudflared"

# --- 1. 基础环境安装 ---
install_base() {
    echo -e "${BLUE}[进度] 正在安装系统基础依赖...${PLAIN}"
    if [[ -f /usr/bin/apt ]]; then
        apt update && apt install -y curl wget jq socat cron openssl tar
    else
        yum install -y curl wget jq socat crontabs openssl tar
    fi
    mkdir -p /usr/local/etc/xray $CERT_DIR
}

# --- 2. 安装 VLESS+xhttp+TLS (选项1) ---
install_vless_direct() {
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (直连/CDN模式) ---${PLAIN}"
    
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"

    read -p "请输入解析域名: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }

    read -p "请输入UUID (回车随机: $r_uuid): " uuid
    uuid=${uuid:-$r_uuid}
    read -p "请输入端口 (回车随机: $r_port): " port
    port=${port:-$r_port}
    read -p "请输入路径 (回车随机: $r_path): " path
    path=${path:-$r_path}
    read -p "请输入指纹fp (回车随机: $r_fp): " fp
    fp=${fp:-$r_fp}
    read -p "请输入ALPN (回车随机: $r_alpn): " alpn
    alpn=${alpn:-$r_alpn}
    
    echo -e "${BLUE}[进度] 正在准备 acme.sh 证书申请...${PLAIN}"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    echo -e "选择证书申请模式: 1.Standalone 2.Cloudflare API"
    read -p "请选择 [1-2]: " c_mode
    if [[ "$c_mode" == "2" ]]; then
        read -p "CF Email: " cf_e && read -p "CF Key: " cf_k
        export CF_Key="$cf_k" && export CF_Email="$cf_e"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain
    else
        ~/.acme.sh/acme.sh --issue -d $domain --standalone
    fi

    ~/.acme.sh/acme.sh --install-cert -d $domain --key-file $CERT_DIR/server.key --fullchain-file $CERT_DIR/server.crt --reloadcmd "systemctl restart xray"

    echo -e "${BLUE}[进度] 正在写入 Xray 配置...${PLAIN}"
    cat <<EOF > $XRAY_CONF_DIRECT
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port, "protocol": "vless",
        "settings": { "clients": [{"id": "$uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": { "path": "$path", "mode": "auto", "host": "$domain" },
            "tlsSettings": {
                "certificates": [{ "certificateFile": "$CERT_DIR/server.crt", "keyFile": "$CERT_DIR/server.key" }],
                "alpn": ["$(echo $alpn | sed 's/,/","/g')"], "fingerprint": "$fp"
            }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    [[ ! -f /usr/local/bin/xray ]] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray && systemctl restart xray
    
    echo -e "${GREEN}VLESS+xhttp+TLS 安装成功！${PLAIN}"
    sleep 1
    show_node_info  # <--- 自动触发结果展示
}

# --- 3. 安装 CF Tunnel (选项2) ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS 传输模式) ---${PLAIN}"
    
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))
    
    echo -e "选择隧道类型: 1.临时隧道 2.固定隧道 (Token模式)"
    read -p "选择 [1-2]: " t_choice
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid
    t_uuid=${t_uuid:-$r_t_uuid}
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path
    t_path=${t_path:-$r_t_path}

    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 CF Tunnel Token: " t_token
        [[ -z "$t_token" ]] && { echo -e "${RED}Token不能为空！${PLAIN}"; return; }
    else
        read -p "请输入临时隧道回源端口 (回车随机: $r_t_port): " t_port
        t_port=${t_port:-$r_t_port}
    fi

    echo -e "${BLUE}[进度] 正在写入隧道后端配置...${PLAIN}"
    cat <<EOF > $XRAY_CONF_TUNNEL
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $t_port, "protocol": "vless",
        "settings": { "clients": [{"id": "$t_uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "ws", "security": "none",
            "wsSettings": { "path": "$t_path" }
        }
    }],
    "outbounds": [{"protocol": "freedom"}]
}
EOF
    mv $XRAY_CONF_TUNNEL $XRAY_CONF_DIRECT
    systemctl restart xray

    echo -e "${BLUE}[进度] 正在下载 Cloudflared...${PLAIN}"
    [[ ! -f $CF_BIN ]] && wget -O $CF_BIN https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x $CF_BIN

    pkill -f cloudflared > /dev/null 2>&1
    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在建立临时隧道...${PLAIN}"
        nohup $CF_BIN tunnel --protocol http2 --url http://localhost:$t_port > $CF_LOG 2>&1 &
        for i in {1..20}; do
            echo -ne "\r获取域名进度: ${i}s..."
            if [[ -f $CF_LOG ]] && grep -q "trycloudflare.com" $CF_LOG; then
                echo -e "\n${GREEN}临时隧道启动成功！${PLAIN}"
                break
            fi
            sleep 1
        done
    else
        nohup $CF_BIN tunnel --no-autoupdate run --token $t_token > $CF_LOG 2>&1 &
        echo -e "${GREEN}固定隧道已成功启动！${PLAIN}"
        sleep 2
    fi
    
    show_node_info  # <--- 自动触发结果展示
}

# --- 4. 节点输出展示 ---
show_node_info() {
    # 如果检测到刚安装完还没清理屏幕，可以在这加 clear
    echo -e "\n${CYAN}━━━━━━━━━━━━━━ 节点部署详情 ━━━━━━━━━━━━━━${PLAIN}"
    if [[ -f $XRAY_CONF_DIRECT ]]; then
        local d_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF_DIRECT)
        local d_port=$(jq -r '.inbounds[0].port' $XRAY_CONF_DIRECT)
        local d_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path' $XRAY_CONF_DIRECT)
        local d_net=$(jq -r '.inbounds[0].streamSettings.network' $XRAY_CONF_DIRECT)
        
        echo -e "UUID: ${BLUE}$d_uuid${PLAIN}"
        echo -e "路径: ${BLUE}$d_path${PLAIN}"
        echo -e "协议: ${BLUE}$d_net${PLAIN}"
        
        if [[ "$d_net" == "xhttp" ]]; then
            local domain=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $XRAY_CONF_DIRECT)
            echo -e "${GREEN}[直连/CDN节点链接]${PLAIN}"
            echo -e "${YELLOW}vless://$d_uuid@$domain:$d_port?security=tls&sni=$domain&type=xhttp&mode=auto&path=$d_path#Direct_xHTTP${PLAIN}"
        fi

        if pgrep -x "cloudflared" > /dev/null; then
            local t_url=$(grep -oE "[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1)
            echo -e "${PURPLE}[隧道节点链接]${PLAIN}"
            if [[ -n "$t_url" ]]; then
                echo -e "域名: $t_url"
                echo -e "${YELLOW}vless://$d_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&path=$d_path#CF_Tunnel_WS${PLAIN}"
            else
                echo -e "固定隧道运行中，请结合 CF 面板域名接入。"
            fi
        fi
    else
        echo -e "${RED}未发现配置文件，请先执行安装！${PLAIN}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}\n"
}

# --- 5. 卸载与加速 ---
uninstall_all() {
    echo -e "${RED}正在全面卸载组件...${PLAIN}"
    systemctl stop xray && systemctl disable xray
    pkill -f cloudflared
    rm -rf /usr/local/etc/xray /usr/local/bin/xray /usr/local/bin/cloudflared $CF_LOG
    echo -e "${GREEN}卸载完成。${PLAIN}"
}

# --- 主菜单 ---
main_menu() {
    while true; do
        echo -e "
${CYAN}==========================================
      BoGe Xray & CF Tunnel 一键脚本
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS+xhttp+TLS (参数随机/自定义)
 ${YELLOW}2.${PLAIN} 安装 CF Tunnel (WS协议/固定+临时)
 ${YELLOW}3.${PLAIN} 查看当前节点信息与链接
 ${YELLOW}4.${PLAIN} 开启 BBR 加速
 ${YELLOW}5.${PLAIN} 卸载脚本及相关组件
 ${RED}0.${PLAIN} 退出脚本
"
        read -p "请选择 [0-5]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf && sysctl -p ;;
            5) uninstall_all ;;
            0) exit 0 ;;
            *) echo "无效输入" ;;
        esac
        echo -ne "\n操作完成，按回车键返回菜单..."
        read -n 1
    done
}

main_menu
