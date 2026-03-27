#!/bin/bash

# ====================================================
# Project: Xray xhttp & CF Tunnel 一键脚本
# Author: BoGe & User (caojiaxia)
# System: Debian/Ubuntu/CentOS
# ====================================================

# 颜色和路径定义 (保持不变)
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

# --- [模块 4: BBR 加速] ---
enable_bbr() {
    echo -e "${BLUE}[进度] 正在检查 BBR 状态...${PLAIN}"
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo -e "${GREEN}[提示] BBR 已经处于开启状态，无需重复操作。${PLAIN}"
    else
        echo -e "${YELLOW}正在写入 BBR 配置...${PLAIN}"
        # 优化：先清理旧的配置再写入，防止重复叠加
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
    
    # 创建配置和证书目录
    mkdir -p /usr/local/etc/xray $CERT_DIR

    # 预装 Xray 获取 Service 文件
    if [[ ! -f /etc/systemd/system/xray.service ]]; then
        echo -e "${YELLOW}检测到 Xray 未安装，执行官方安装脚本...${PLAIN}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # --- 脚本层面修复：修改 Service 文件 ---
    echo -e "${BLUE}[进度] 正在修正 Systemd 服务配置...${PLAIN}"
    
    # 修复 1: 改为 -confdir 模式，避免加载 certs 文件夹导致崩溃
    sed -i 's|run -config /usr/local/etc/xray/config.json|run -confdir /usr/local/etc/xray/|g' /etc/systemd/system/xray.service
    
    # 修复 2: 将 User=nobody 改为 User=root，解决证书读取权限问题
    sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service

    # 修复 3: 清理可能存在的旧冲突
    rm -rf /etc/systemd/system/xray.service.d
    rm -f /usr/local/etc/xray/config.json

    systemctl daemon-reload
}

# --- 2. 安装 VLESS+xhttp+TLS ---
install_vless_direct() {
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (兼容 CDN) ---${PLAIN}"
    
    # --- DNS 守护逻辑：防止 acme.sh 篡改 DNS 导致失败 ---
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"

    read -p "请输入解析域名: " domain
    [[ -z "$domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
    
    # 提醒用户 CDN 端口限制
    echo -e "${YELLOW}注意：若需套 CDN，端口请务必使用 CF 支持的端口 (如 443, 8443, 2053, 2083, 2096)${PLAIN}"
    read -p "请输入端口 (回车随机: $r_port): " port; port=${port:-$r_port}
    
    read -p "请输入UUID (回车随机: $r_uuid): " uuid; uuid=${uuid:-$r_uuid}
    read -p "请输入路径 (回车随机: $r_path): " path; path=${path:-$r_path}
    read -p "请输入指纹fp (回车随机: $r_fp): " fp; fp=${fp:-$r_fp}
    read -p "请输入ALPN (回车随机: $r_alpn): " alpn; alpn=${alpn:-$r_alpn}
    
    echo -e "选择模式: 1.Standalone 2.Cloudflare API"
    read -p "选择 [1-2]: " c_mode

    # 预装 Xray 保证环境
    echo -e "${BLUE}[进度] 正在检查 Xray 核心环境...${PLAIN}"
    [[ ! -f /usr/local/bin/xray ]] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload

    echo -e "${BLUE}[进度] 正在处理证书步骤...${PLAIN}"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    # --- 证书申请逻辑 ---
    if [[ "$c_mode" == "2" ]]; then
        read -p "请输入 CF Email: " cf_e
        read -p "请输入 CF Global API Key: " cf_k
        export CF_Key="$cf_k"
        export CF_Email="$cf_e"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain --force
    else
        # Standalone 模式检查 80 端口
        if [[ ! -f ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            if lsof -i:80 > /dev/null 2>&1; then
                echo -e "${RED}[错误] 80 端口被占用，请停止 Docker/Nginx 后再试！${PLAIN}"
                return 1
            fi
        fi
        ~/.acme.sh/acme.sh --issue -d $domain --standalone --force
    fi

    # --- 证书存在性实地检查 ---
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

    # 强制处理 ALPN 数组格式
    local alpn_formatted=$(echo "$alpn" | sed 's/,/","/g')

    echo -e "${BLUE}[进度] 正在写入核心配置 (兼容 CDN 模式)...${PLAIN}"
    cat <<EOF > $XRAY_CONF_DIRECT
{
    "log": { "loglevel": "warning" },
    "inbounds": [{
        "port": $port, 
        "protocol": "vless",
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
    "outbounds": [{"protocol": "freedom"}]
}
EOF

    # 显式清理旧进程并重启
    pkill -f xray
    systemctl restart xray
    
    sleep 2
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}VLESS+xhttp+TLS 部署成功！${PLAIN}"
        show_node_info
    else
        echo -e "${RED}[错误] Xray 启动失败，请检查端口 $port 是否被占用。${PLAIN}"
    fi
}

# --- 3. 安装 CF Tunnel ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS 模式) ---${PLAIN}"
    
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))
    
    echo -e "选择隧道类型: 1.临时隧道 2.固定隧道"
    read -p "选择 [1-2]: " t_choice
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid
    t_uuid=${t_uuid:-$r_t_uuid}
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path
    t_path=${t_path:-$r_t_path}

    local t_domain=""
    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 Cloudflare 绑定的域名 (如 tunnel.example.com): " t_domain
        [[ -z "$t_domain" ]] && { echo -e "${RED}域名不能为空！${PLAIN}"; return; }
        read -p "请输入 Token: " t_token
        [[ -z "$t_token" ]] && { echo -e "${RED}Token不能为空！${PLAIN}"; return; }
        
        # 将域名存入临时文件供展示函数读取
        echo "$t_domain" > /tmp/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port
        t_port=${t_port:-$r_t_port}
    fi

    # 写入配置 (固定为 WS 协议以适配隧道)
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
    # 修复：删除错误的 mv 指令，保持多配置共存
    systemctl restart xray

    # 下载 Cloudflared
    [[ ! -f $CF_BIN ]] && wget -O $CF_BIN https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x $CF_BIN

    pkill -f cloudflared > /dev/null 2>&1
    rm -f $CF_LOG
    
    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在建立临时隧道...${PLAIN}"
        nohup $CF_BIN tunnel --protocol http2 --url http://localhost:$t_port > $CF_LOG 2>&1 &
        
        for i in {1..30}; do
            echo -ne "\r正在尝试抓取域名: ${i}s..."
            if [[ -f $CF_LOG ]]; then
                tmp_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
                if [[ -n "$tmp_domain" ]]; then
                    echo -e "\n${GREEN}抓取成功！域名: $tmp_domain${PLAIN}"
                    echo "$tmp_domain" > /tmp/cf_tunnel_domain
                    break
                fi
            fi
            sleep 1
        done
    else
        nohup $CF_BIN tunnel --no-autoupdate run --token $t_token > $CF_LOG 2>&1 &
        echo -e "${GREEN}固定隧道已启动！${PLAIN}"
        sleep 2
    fi
    show_node_info
}

# --- 4. 查看当前节点信息与链接 ---
show_node_info() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━ 当前已部署节点列表 ━━━━━━━━━━━━━━${PLAIN}"
    local has_node=false

    # --- 1. 检查并展示：VLESS+xhttp+TLS 直连/CDN 节点 ---
    if [[ -f "$XRAY_CONF_DIRECT" ]]; then
        has_node=true
        local conf="$XRAY_CONF_DIRECT"
        
        # 使用 jq 解析配置参数
        local d_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $conf)
        local d_port=$(jq -r '.inbounds[0].port' $conf)
        local d_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' $conf)
        local d_host=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host' $conf)
        local d_fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint' $conf)
        local d_alpn_raw=$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn | join(",")' $conf)
        
        # URL 编码处理 ALPN
        local d_alpn=$(echo $d_alpn_raw | sed 's/,/%2C/g')

        echo -e "${GREEN}[节点 1: VLESS+xhttp+TLS 直连/CDN]${PLAIN}"
        echo -e "  地址/SNI: ${BLUE}$d_host${PLAIN}"
        echo -e "  端口: ${BLUE}$d_port${PLAIN}"
        echo -e "  UUID: ${BLUE}$d_uuid${PLAIN}"
        echo -e "  路径: ${BLUE}$d_path${PLAIN}"
        echo -e "  链接: ${YELLOW}vless://$d_uuid@$d_host:$d_port?security=tls&sni=$d_host&type=xhttp&mode=auto&path=$(echo $d_path | sed 's/\//%2F/g')&fp=$d_fp&alpn=$d_alpn#Direct_xHTTP${PLAIN}"
        echo -e "------------------------------------------------"
    fi

    # --- 2. 检查并展示：CF Tunnel 隧道节点 ---
    if [[ -f "$XRAY_CONF_TUNNEL" ]]; then
        has_node=true
        local conf="$XRAY_CONF_TUNNEL"
        
        local t_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' $conf)
        local t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' $conf)
        
        local t_url=""
        if [[ -f "/tmp/cf_tunnel_domain" ]]; then
            t_url=$(cat /tmp/cf_tunnel_domain)
        fi

        echo -e "${PURPLE}[节点 2: Cloudflare Tunnel 隧道]${PLAIN}"
        if [[ -n "$t_url" ]]; then
            echo -e "  隧道域名: ${BLUE}$t_url${PLAIN}"
            echo -e "  UUID: ${BLUE}$t_uuid${PLAIN}"
            echo -e "  路径: ${BLUE}$t_path${PLAIN}"
            echo -e "  链接: ${YELLOW}vless://$t_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&path=$(echo $t_path | sed 's/\//%2F/g')#CF_Tunnel_WS${PLAIN}"
        else
            echo -e "  UUID: ${BLUE}$t_uuid${PLAIN}"
            echo -e "  路径: ${BLUE}$t_path${PLAIN}"
            echo -e "  ${RED}提示: 无法获取隧道域名。${PLAIN}"
        fi
        echo -e "------------------------------------------------"
    fi

    if [ "$has_node" = false ]; then
        echo -e "${YELLOW}当前服务器未检测到任何已部署的 Xray 节点。${PLAIN}"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}\n"
    read -p "按回车键返回菜单..."
}

# --- 5. 卸载脚本及相关组件 ---
uninstall_all() {
    echo -e "${RED}确定要卸载所有组件吗？此操作不可逆！${PLAIN}"
    read -p "确认请输入 [y/n]: " confirm
    [[ "$confirm" != "y" ]] && return

    echo -e "${YELLOW}[1/5] 正在停止并卸载 Xray 服务...${PLAIN}"
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service
    rm -rf /etc/systemd/system/xray.service.d
    rm -f /usr/local/bin/xray
    
    echo -e "${YELLOW}[2/5] 正在清理配置文件和证书...${PLAIN}"
    rm -rf /usr/local/etc/xray
    
    echo -e "${YELLOW}[3/5] 正在卸载 Cloudflare Tunnel...${PLAIN}"
    pkill -f cloudflared >/dev/null 2>&1
    rm -f /usr/local/bin/cloudflared
    rm -f /tmp/cf_tunnel.log
    rm -f /tmp/cf_tunnel_domain
    
    echo -e "${YELLOW}[4/5] 正在清理 ACME 证书工具...${PLAIN}"
    if [[ -d ~/.acme.sh ]]; then
        ~/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
        rm -rf ~/.acme.sh
    fi

    echo -e "${YELLOW}[5/5] 正在重载系统服务...${PLAIN}"
    systemctl daemon-reload
    
    echo -e "${GREEN}卸载完成！${PLAIN}"
    read -p "按回车键返回菜单..."
}

main_menu() {
    while true; do
        echo -e "
${CYAN}==========================================
      BoGe Xray & CF Tunnel 一键脚本
==========================================${PLAIN}
 ${YELLOW}1.${PLAIN} 安装 VLESS+xhttp+TLS
 ${YELLOW}2.${PLAIN} 安装 CF Tunnel
 ${YELLOW}3.${PLAIN} 查看当前节点信息与链接
 ${YELLOW}4.${PLAIN} 开启 BBR 加速
 ${YELLOW}5.${PLAIN} 卸载脚本及相关组件
 ${RED}0.${PLAIN} 退出脚本"
        read -p "选择 [0-5]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf && echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf && sysctl -p ;;
            5) uninstall_all ;;
            0) exit 0 ;;
        esac
    done
}

# 核心修复：在这里调用函数
main_menu
