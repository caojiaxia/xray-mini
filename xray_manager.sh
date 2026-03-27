#!/bin/bash

# ====================================================
# Project: Xray xhttp & CF Tunnel 一键脚本
# Author: BoGe & User (caojiaxia)
# System: Debian/Ubuntu/CentOS
# ====================================================

# 颜色和路径定义 (严格保持不变)
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

# --- [模块 4: BBR 加速]  ---
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
    
    mkdir -p /usr/local/etc/xray $CERT_DIR

    # 【步骤 1】：尝试官方脚本安装 
    if [[ ! -f /usr/local/bin/xray ]]; then
        echo -e "${YELLOW}检测到 Xray 核心缺失，正在尝试从官方拉取...${PLAIN}"
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    fi

    # 【步骤 2】：精准定位服务文件路径
    local SERVICE_FILE="/etc/systemd/system/xray.service"
    [[ ! -f "$SERVICE_FILE" ]] && SERVICE_FILE="/lib/systemd/system/xray.service"

    # 【步骤 3】：如果官方没生成服务文件 (NAT 常现)，则手动创建兜底配置
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
        echo -e "${BLUE}[进度] 正在修正服务运行参数...${PLAIN}"
        systemctl stop xray >/dev/null 2>&1
        pkill -9 xray >/dev/null 2>&1
        
        # 即使文件是手动创建的，运行这两行 sed 也没有副作用
        sed -i 's|run -config /usr/local/etc/xray/config.json|run -confdir /usr/local/etc/xray/|g' "$SERVICE_FILE"
        sed -i 's/User=nobody/User=root/g' "$SERVICE_FILE"
        
        # 清理可能存在的冲突目录和默认配置
        rm -rf "${SERVICE_FILE}.d"
        rm -f /usr/local/etc/xray/config.json
        systemctl daemon-reload
        echo -e "${GREEN}[成功] 服务环境配置完毕。${PLAIN}"
    else
        echo -e "${RED}[致命错误] 无法定位 Xray 二进制文件或服务文件，安装失败。${PLAIN}"
        return 1
    fi
}

# --- 2. 安装 VLESS+xhttp+TLS (严格遵循你提供的流程) ---
install_vless_direct() {
    install_base
    echo -e "${CYAN}--- 开始配置 VLESS + xhttp + TLS (兼容 CDN) ---${PLAIN}"
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
    
    local r_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_port=$((RANDOM % 55535 + 10000))
    local r_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_fp="chrome"
    local r_alpn="h2,http/1.1"

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
    [[ ! -f /usr/local/bin/xray ]] && bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    rm -rf /etc/systemd/system/xray.service.d && systemctl daemon-reload

    echo -e "${BLUE}[进度] 正在处理证书步骤...${PLAIN}"
    [[ ! -f ~/.acme.sh/acme.sh ]] && curl https://get.acme.sh | sh -s email=admin@$domain
    source ~/.bashrc
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

    if [[ "$c_mode" == "2" ]]; then
        read -p "请输入 CF Email: " cf_e
        read -p "请输入 CF Global API Key: " cf_k
        export CF_Key="$cf_k"
        export CF_Email="$cf_e"
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d $domain --force
    else
        if [[ ! -f ~/.acme.sh/${domain}_ecc/${domain}.key ]]; then
            if lsof -i:80 > /dev/null 2>&1; then
                echo -e "${RED}[错误] 80 端口被占用，请停止 Docker/Nginx 后再试！${PLAIN}"
                return 1
            fi
        fi
        ~/.acme.sh/acme.sh --issue -d $domain --standalone --force
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

    local alpn_formatted=$(echo "$alpn" | sed 's/,/","/g')

echo -e "${BLUE}[进度] 正在写入核心配置 (IPv6 优先模式)...${PLAIN}"
    cat <<EOF > $XRAY_CONF_DIRECT
{
    "log": { "loglevel": "warning" },
    "dns": {
        "servers": [
            "https+local://1.1.1.1/dns-query",
            "localhost"
        ],
        "queryStrategy": "UseIPv6",
        "tag": "dns_inbound"
    },
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
                "alpn": ["h2","http/1.1"],
                "fingerprint": "chrome"
            }
        }
    }],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIPv6"
            },
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "direct",
                "network": "udp,tcp"
            }
        ]
    }
}
EOF

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

# --- 3. 安装 CF Tunnel  ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS 模式) ---${PLAIN}"
    
    # 生成默认值
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))
    
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
        echo "$t_domain" > /tmp/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port
        t_port=${t_port:-$r_t_port}
    fi
cat <<EOF > $XRAY_CONF_TUNNEL
{
    "log": { "loglevel": "warning" },
    "dns": {
        "servers": [
            "https+local://1.1.1.1/dns-query",
            "localhost"
        ],
        "queryStrategy": "UseIPv6",
        "tag": "dns_inbound"
    },
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
                "domainStrategy": "UseIPv6"
            },
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "outboundTag": "direct",
                "network": "udp,tcp"
            }
        ]
    }
}
EOF
    systemctl restart xray

    # 下载与权限
    if [[ ! -f $CF_BIN ]]; then
        echo -e "${YELLOW}正在下载 cloudflared...${PLAIN}"
        wget -O $CF_BIN https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
        chmod +x $CF_BIN
    fi

    # Systemd 守护进程运行 cloudflared
    echo -e "${BLUE}[进度] 正在配置 cloudflared 服务守护...${PLAIN}"
    systemctl stop cloudflared >/dev/null 2>&1
    pkill -f cloudflared >/dev/null 2>&1
    rm -f $CF_LOG

    local cf_cmd=""
    if [[ "$t_choice" == "1" ]]; then
        cf_cmd="tunnel --protocol http2 --url http://localhost:$t_port"
    else
        cf_cmd="tunnel --no-autoupdate run --token $t_token"
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
                tmp_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare\.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
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
        echo -e "${GREEN}固定隧道已通过服务形式启动！${PLAIN}"
        sleep 2
    fi
    
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
    # 同时停止 xray 和 cloudflared 服务
    systemctl stop xray cloudflared >/dev/null 2>&1
    # 强力杀死所有残留进程
    pkill -9 xray >/dev/null 2>&1
    pkill -9 cloudflared >/dev/null 2>&1
    pkill -f cloudflared >/dev/null 2>&1

    echo -e "${YELLOW}[2/5] 正在移除 Systemd 服务定义...${PLAIN}"
    # 禁用服务并删除 NAT 模式下的 cloudflared.service
    systemctl disable xray cloudflared >/dev/null 2>&1
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reload

    echo -e "${YELLOW}[3/5] 正在清理安装目录与配置...${PLAIN}"
    # 彻底删除整个 xray 目录（含所有 json 和 certs）
    rm -rf /usr/local/etc/xray
    rm -rf $CERT_DIR
    # 删除可执行二进制文件
    rm -f /usr/local/bin/xray
    rm -f /usr/local/bin/cloudflared
    rm -f $CF_BIN

    echo -e "${YELLOW}[4/5] 正在清理临时文件与日志...${PLAIN}"
    rm -f /tmp/cloudflared.log
    rm -f /tmp/cf_tunnel_domain
    rm -f $CF_LOG
    # 清理 acme.sh 证书相关 (根据你的需求选择性保留)
    # rm -rf ~/.acme.sh

    echo -e "${YELLOW}[5/5] 正在清理残留依赖与任务...${PLAIN}"
    # 清理相关的 cron 任务
    crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - >/dev/null 2>&1

    echo -e "------------------------------------------------"
    echo -e "${GREEN}卸载完成！系统已恢复至干净状态。${PLAIN}"
    echo -e "------------------------------------------------"
    read -p "按回车键返回菜单..."
}

# --- [主菜单模块] (严格遵循你要求的横排/纵向样式) ---
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
 ${RED}0.${PLAIN} 退出脚本"
        read -p "选择 [0-5]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) enable_bbr ;; 
            5) uninstall_all ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误${PLAIN}" && sleep 1 ;;
        esac
    done
}

main_menu
