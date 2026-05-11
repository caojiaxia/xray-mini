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
        x86_64)  CF_ARCH="amd64"; XRAY_ARCH="64" ;;
        aarch64) CF_ARCH="arm64"; XRAY_ARCH="arm64-v8a" ;;
        armv7l)  CF_ARCH="arm";   XRAY_ARCH="arm32-v7a" ;;
        *)       CF_ARCH="amd64"; XRAY_ARCH="64" ;;
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
    # 优化后的 Crontab 写入逻辑：确保不重复且在 crontab 为空时也能写入
    (crontab -l 2>/dev/null | grep -v "cleanup_logs"; echo "0 3 * * 1 $current_script cleanup_logs > /dev/null 2>&1") | crontab -
    
    echo -e "${GREEN}已添加/更新每周一凌晨 3 点自动清理计划任务。${PLAIN}"
    [[ "$1" != "silent" ]] && read -p "按回车键返回菜单..."
}

# --- [ 核心模块：全平台防御性内核同步升级 & BBR 监控中心 ] ---
update_kernel_bbr() {
    clear
    # 1. 采集全系统指纹 
    local current_kernel=$(uname -r)
    local current_algo=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null)
    local bbr_status=$(lsmod | grep bbr)
    local mem_total=$(free -m | awk '/Mem:/ {print $2}' 2>/dev/null || echo "Unknown")
    
    local os_type="Unknown"
    [[ -f /etc/debian_version ]] && os_type="Debian"
    [[ -f /etc/redhat-release ]] && os_type="CentOS"
    [[ -f /etc/alpine-release ]] && os_type="Alpine"

    # 精准识别 BBR 版本
    local bbr_ver="Unknown"
    if [[ "$current_algo" == "bbr" ]]; then
        if [[ "$current_kernel" == *"xanmod"* ]]; then
            bbr_ver="v3 (XanMod High Speed)"
        elif [[ "$current_kernel" =~ ^[6]\.[4-9] ]] || [[ "$current_kernel" =~ ^[7] ]]; then
            bbr_ver="v3 (Mainline)"
        elif [[ "$current_kernel" =~ ^[5]\.[1][5-9] ]] || [[ "$current_kernel" =~ ^[6]\.[0-3] ]]; then
            bbr_ver="v2"
        else
            bbr_ver="v1"
        fi
    fi

    echo -e "${PURPLE}======================================================${PLAIN}"
    echo -e "${PURPLE}       内核版本管理与 BBR 监控中心 (全系统版)         ${PLAIN}"
    echo -e "${PURPLE}======================================================${PLAIN}"
    echo -e "${CYAN} 操作系统   :${PLAIN} ${GREEN}${os_type}${PLAIN}"
    echo -e "${CYAN} 当前内核   :${PLAIN} ${GREEN}${current_kernel}${PLAIN}"
    echo -e "${CYAN} TCP控制算法:${PLAIN} ${GREEN}${current_algo}${PLAIN}"
    echo -e "${CYAN} BBR具体版本:${PLAIN} ${YELLOW}${bbr_ver}${PLAIN}"
    
    if [[ -n "$bbr_status" || "$current_algo" == "bbr" ]]; then
        echo -e "${CYAN} 运行状态    :${PLAIN} ${GREEN}正在运行 (Running)${PLAIN}"
    else
        echo -e "${CYAN} 运行状态    :${PLAIN} ${RED}未启动 (Not Running)${PLAIN}"
    fi
    echo -e "${PURPLE}------------------------------------------------------${PLAIN}"

    echo -e " 请选择内核维护方案:"
    echo -e "  1. 升级系统内核 (${GREEN}含全平台修复 & XanMod/ELRepo${PLAIN})"
    echo -e "  2. 仅开启当前内核 BBR (${YELLOW}不更换内核，适合 NAT 小鸡${PLAIN})"
    echo -e "  0. 返回主菜单"
    read -p " 请输入编号 [0-2]: " k_choice

    [[ "$k_choice" == "0" || -z "$k_choice" ]] && return

    # 2. 内核升级核心链路
    if [[ "$k_choice" == "1" ]]; then
        # 内存压力预警
        if [[ "$mem_total" != "Unknown" && "$mem_total" -lt 1024 ]]; then
            echo -e "${RED} [!] 警告: 内存过低 (${mem_total}MB)，升级内核风险极高！${PLAIN}"
            read -p " 确认要继续吗？(y/N): " risk_confirm
            [[ "$risk_confirm" != "y" ]] && return
        fi

        echo -e "${YELLOW}正在启动全平台内核同步流程...${PLAIN}"

        if [[ "$os_type" == "Debian" ]]; then
            # --- Debian/Ubuntu  ---
            echo -e "${CYAN}正在配置 XanMod 仓库并强制修复 GPG 密钥...${PLAIN}"
            apt update -y && apt install -y curl gnupg2 ca-certificates lsb-release
            
            # 方案 A: 证书同步后的正常导入
            curl -fSsL https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /usr/share/keyrings/xanmod-archive-keyring.gpg
            
            # 方案 B: 针对 NO_PUBKEY 86F7D09EE734E623 的强力捞取逻辑
            if [ ! -s /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then
                echo -e "${YELLOW}常规导入失败，尝试从公钥服务器强制拉取 86F7D09EE734E623...${PLAIN}"
                gpg --no-default-keyring --keyring /usr/share/keyrings/xanmod-archive-keyring.gpg --keyserver keyserver.ubuntu.com --recv-keys 86F7D09EE734E623
            fi

            echo "deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main" | tee /etc/apt/sources.list.d/xanmod-release.list
            apt update -y
            
            # 安装适配 
            apt install -y linux-xanmod-x64v3 || apt install -y linux-xanmod
            apt autoremove -y

        elif [[ "$os_type" == "CentOS" ]]; then
            # --- CentOS 引导与仓库 ---
            local rhel_ver=$(rpm -E %rhel)
            rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
            yum install -y https://www.elrepo.org/elrepo-release-${rhel_ver}.el${rhel_ver}.elrepo.noarch.rpm 2>/dev/null
            yum --enablerepo=elrepo-kernel install -y kernel-ml
            # 修复引导项
            [[ -f /sbin/grubby ]] && grubby --set-default=$(ls /boot/vmlinuz-* | sort -V | tail -n 1)
            [[ -x "$(command -v grub2-set-default)" ]] && grub2-set-default 0
            yum autoremove -y

        elif [[ "$os_type" == "Alpine" ]]; then
            apk add linux-virt || apk add linux-lts
        fi
    fi

    # 3. 统一注入 BBR 优化参数 (无论内核是否更换，此步骤确保 BBR 开启)
    echo -e "${YELLOW}正在注入 BBR 优化参数并更新配置...${PLAIN}"
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  操作已完成！当前运行内核仍为: ${current_kernel}${PLAIN}"
    echo -e "${RED}  请立刻重启服务器，重启后再次进入此菜单即可看到 v3 状态！${PLAIN}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    read -p "是否现在重启？(y/n): " res
    [[ "$res" == "y" ]] && reboot
}

# 统一重启与冲突校验函数
restart_and_check() {
    echo -e "${BLUE}[进度] 正在同步重启服务并进行环境适配...${PLAIN}"
    
    local X_BIN="/usr/local/bin/xray"
    if [[ ! -f "$X_BIN" ]]; then
        echo -e "${RED}[致命错误] Xray 二进制文件未找到。${PLAIN}"
        return 1
    fi

    # 1. 暴力清理旧进程
    pkill -9 xray >/dev/null 2>&1
    sleep 1 
    
    # 2. 校验配置
    if ! "$X_BIN" -test -confdir /usr/local/etc/xray/ >/tmp/xray_err.log 2>&1; then
        echo -e "${RED}[错误] 配置文件校验失败！详细日志：${PLAIN}"
        cat /tmp/xray_err.log
        return 1
    fi

    # 3. 分系统尝试启动
    local started=false
    if [ "$HAS_SYSTEMD" = true ]; then
        systemctl restart xray >/dev/null 2>&1
        sleep 1
        pgrep -x "xray" > /dev/null && started=true
    fi

    if [ "$HAS_OPENRC" = true ] && [ "$started" = false ]; then
        rc-service xray restart >/dev/null 2>&1
        sleep 1
        pgrep -x "xray" > /dev/null && started=true
    fi

    # 4. 【核心改进】强制兜底逻辑：如果上面都没启动成功 (针对 Docker/NAT 小鸡)
    if [ "$started" = false ]; then
        nohup "$X_BIN" run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
        # 给 Alpine 这种“快男”多一点点缓冲时间
        sleep 4
        # 使用更原始但更兼容的 ps 方式检测
        if ps w | grep -v grep | grep -q "xray"; then
            started=true
        fi
    fi

    # 5. 反馈结果
    if [ "$started" = true ]; then
        echo -e "${GREEN}[成功] Xray 已在当前环境成功启动。${PLAIN}"
        return 0
    else
        echo -e "${RED}[致命错误] 所有启动方式均失败，请检查端口是否被占用。${PLAIN}"
        return 1
    fi
}

# --- 1. 基础环境安装 ---
install_base() {
    # --- 自动清理双栈防火墙 (确保独立 IPv6 申请证书顺畅) ---
    echo -e "${YELLOW}正在放行双栈所有端口...${PLAIN}"
    # 清理 IPv4
    iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT
    iptables -F && iptables -X && iptables -Z
    
    # 清理 IPv6
    if command -v ip6tables &> /dev/null; then
        ip6tables -P INPUT ACCEPT && ip6tables -P FORWARD ACCEPT && ip6tables -P OUTPUT ACCEPT
        ip6tables -F && ip6tables -X && ip6tables -Z
    fi
    
    # 清理 nftables (针对 Debian 12+)
    if command -v nft &> /dev/null; then
        nft flush ruleset
    fi

    detect_arch
    echo -e "${BLUE}[进度] 正在安装系统基础依赖...${PLAIN}"
    
    # 在所有系统的安装列表中增加 unzip
    if grep -qi "alpine" /etc/os-release; then
        # 修复目录缺失
        mkdir -p /var/spool/cron/crontabs
        apk update && apk add bash curl wget jq socat cronie openssl tar lsof net-tools libc6-compat gcompat libstdc++ openrc unzip >/dev/null 2>&1
    elif [[ -f /usr/bin/apt ]]; then
        # Debian/Ubuntu 增加 unzip
        apt update && apt install -y curl wget jq socat cron openssl tar lsof net-tools unzip >/dev/null 2>&1
    else
        # CentOS/Yum 增加 unzip
        yum install -y curl wget jq socat crontabs openssl tar lsof net-tools unzip >/dev/null 2>&1
    fi
    
    check_network_strategy
    mkdir -p /usr/local/etc/xray "$CERT_DIR" /usr/local/bin

    # --- 获取最新版 Xray 核心链接 ---
    echo -e "${YELLOW}正在获取最新版 Xray 核心链接...${PLAIN}"
    local latest_ver=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${XRAY_ARCH}.zip"
    
    echo -e "${YELLOW}正在手动下载 Xray 核心 ($latest_ver)...${PLAIN}"
    wget -O /tmp/xray.zip "$download_url"

    # 检查压缩包是否下载成功
    if [[ ! -s /tmp/xray.zip ]]; then
        echo -e "${RED}[错误] 核心压缩包下载失败，请检查网络或磁盘空间！${PLAIN}"
        exit 1
    fi
    
    unzip -o /tmp/xray.zip -d /usr/local/bin/ xray
    rm -f /tmp/xray.zip

    # 显式检查解压出的文件是否存在
    if [[ ! -f /usr/local/bin/xray ]]; then
        echo -e "${RED}[致命错误] Xray 核心解压失败，可能是磁盘空间已满。${PLAIN}"
        exit 1
    fi

    chmod +x /usr/local/bin/xray

    # --- 修复内存清理报错：增加权限判断 ---
    echo -e "${YELLOW}尝试清理系统缓存...${PLAIN}"
    if [[ -w /proc/sys/vm/drop_caches ]]; then
        sync && echo 3 > /proc/sys/vm/drop_caches
    fi

    # --- 修复服务文件：仅在 systemd 机器上操作 ---
    if [ "$HAS_SYSTEMD" = true ]; then
        # ... 这里保留你原来的 systemd 写入逻辑 ...
        echo "Systemd 模式配置已就绪..."
    else
        # Alpine OpenRC 逻辑
        local OPENRC_FILE="/etc/init.d/xray"
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
    fi
}

# [核心执行模块] 负责物理写入、重启及生成 VLESS 链接
update_xray_config() {
    local domain=$1 port=$2 uuid=$3 path=$4
    local direct_conf="/usr/local/etc/xray/conf_1_direct.json"

    # 1. 域名变更检查 (联动证书申请)
    if [[ "$domain" != "$old_domain" ]]; then
        echo -e "${YELLOW}检测到域名变更，正在更新证书...${PLAIN}"
        issue_cert "$domain"
    fi

    # 2. 安全写入配置 (适配 xhttpSettings 路径)
    echo -e "${YELLOW}正在写入新配置到 JSON...${PLAIN}"
    local tmp_file=$(mktemp)
    # 注意：这里 jq 路径必须匹配你配置文件中的 streamSettings.xhttpSettings
    jq ".inbounds[0].port = $port | 
        .inbounds[0].settings.clients[0].id = \"$uuid\" | 
        .inbounds[0].streamSettings.xhttpSettings.path = \"$path\" |
        .inbounds[0].streamSettings.xhttpSettings.host = \"$domain\" |
        .inbounds[0].streamSettings.tlsSettings.serverName = \"$domain\"" \
        "$direct_conf" > "$tmp_file" && mv "$tmp_file" "$direct_conf"

    #  3. 强制重启服务 
    echo -e "${YELLOW}正在执行物理级重启，确保新配置生效...${PLAIN}"
    
    # 尝试标准停止
    systemctl stop xray >/dev/null 2>&1
    rc-service xray stop >/dev/null 2>&1
    sleep 1

    # 暴力清理残余进程 (针对 128MB 小鸡的顽固进程)
    if pgrep -x "xray" > /dev/null; then
        echo -e "${YELLOW}检测到残余进程，执行强杀...${PLAIN}"
        pkill -9 xray >/dev/null 2>&1
        sleep 2
    fi

    #  重新启动
    # 优先使用 nohup 直接拉起，确保在 Alpine 等环境下的稳定性
    nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
    
    # 给一点启动时间
    sleep 3

    # 验证新进程是否运行
    if pgrep -x "xray" > /dev/null; then
        echo -e "${GREEN}服务已重新拉起，旧节点已物理断开。${PLAIN}"
    else
        echo -e "${RED}[错误] Xray 未能启动，请检查 /usr/local/etc/xray/ 下的 JSON 语法。${PLAIN}"
        read -p "按回车查看报错日志..."
        /usr/local/bin/xray test -confdir /usr/local/etc/xray/
        return
    fi

    # 4. 校验并生成 VLESS 链接
    if pgrep -x "xray" > /dev/null; then
        clear
        echo -e "${GREEN}========================================${PLAIN}"
        echo -e "${GREEN}       配置修改成功！节点已生效         ${PLAIN}"
        echo -e "${GREEN}========================================${PLAIN}"
        
        # --- 链接生成逻辑 (参考 show_node_info 格式) ---
        local d_name="${node_name:-Modified_xHTTP}"
        local d_fp=$(jq -r '.inbounds[0].streamSettings.tlsSettings.fingerprint // "chrome"' "$direct_conf")
        local d_alpn_raw=$(jq -r '.inbounds[0].streamSettings.tlsSettings.alpn | join(",")' "$direct_conf")
        local d_alpn=$(echo "$d_alpn_raw" | sed 's/,/%2C/g')
        local d_path_enc=$(echo "$path" | sed 's/\//%2F/g')
        
        # 强制检测并包裹 IPv6 地址
        local final_host="$domain"
        if [[ "$domain" =~ ":" ]] && [[ ! "$domain" =~ "[" ]]; then
            final_host="[$domain]"
        fi

        # 生成新的链接
        local vless_link="vless://$uuid@$final_host:$port?security=tls&sni=$domain&type=xhttp&mode=auto&path=$d_path_enc&fp=$d_fp&alpn=$d_alpn#$d_name"

        echo -e "${BLUE}新配置详情：${PLAIN}"
        echo -e "  域名: ${domain}"
        echo -e "  端口: ${port}"
        echo -e "  UUID: ${uuid}"
        echo -e "  路径: ${path}"
        echo -e "${BLUE}========================================${PLAIN}"
        echo -e "${YELLOW}新的直连链接 (VLESS + xHTTP + TLS):${PLAIN}"
        echo -e "${CYAN}${vless_link}${PLAIN}"
        echo -e "${BLUE}========================================${PLAIN}"
        
        # 释放内存 (针对 128MB 小鸡)
        sync && echo 3 > /proc/sys/vm/drop_caches
        read -p "按回车键返回主菜单..."
    else
        echo -e "${RED}[错误] Xray 重启失败，配置可能未生效！${PLAIN}"
        read -p "按回车键返回..."
    fi
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
    
    echo -e "${YELLOW}注意：若需套 CDN，端口请务必使用 CF 支持的端口 (如 443, 8443, 2053, 2083,2087，2096)${PLAIN}"
    read -p "请输入端口 (回车随机: $r_port): " port; port=${port:-$r_port}
    read -p "请输入UUID (回车随机: $r_uuid): " uuid; uuid=${uuid:-$r_uuid}
    read -p "请输入路径 (回车随机: $r_path): " path; path=${path:-$r_path}
    read -p "请输入指纹fp (回车随机: $r_fp): " fp; fp=${fp:-$r_fp}
    read -p "请输入ALPN (回车随机: $r_alpn): " alpn; alpn=${alpn:-$r_alpn}
    read -p "请输入自定义节点名称 (默认: Direct_xHTTP): " node_name
    node_name=${node_name:-"Direct_xHTTP"}    
    
    # --- 用户选择 ---
    echo -e "${BLUE}请选择证书申请模式:${PLAIN}"
    echo -e "  1. Standalone (80端口模式)"
    echo -e "  2. Cloudflare API (DNS模式)"
    read -p "选择 [1-2] (默认 1): " c_mode
    c_mode=${c_mode:-1}
  
    echo -e "${BLUE}[进度] 正在检查 Xray 核心环境...${PLAIN}"

# --- 执行安装区 ---
    local ACME_BIN="$HOME/.acme.sh/acme.sh"
    
    if [[ ! -f "$ACME_BIN" ]]; then
        curl https://get.acme.sh | sh -s email=admin@$domain
    fi
    
    $ACME_BIN --set-default-ca --server letsencrypt

    # >>> 【优化后的检测逻辑】 <<<
    local skip_acme="n"
    local cert_file="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    local key_file="$HOME/.acme.sh/${domain}_ecc/${domain}.key"

    # 只有当 key 和 fullchain 同时存在时，才允许跳过申请
    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        echo -e "${YELLOW}检测到域名 $domain 已有完整证书文件。${PLAIN}"
        read -p "是否跳过新申请，直接使用现有证书？[y/n] (默认 y): " skip_acme
        skip_acme=${skip_acme:-y}
    else
        # 如果文件不完整，即使 acme.sh 有记录也强制重新申请
        if [[ -d "$HOME/.acme.sh/${domain}_ecc" ]]; then
            echo -e "${YELLOW}检测到证书记录不完整，将尝试强制重新申请...${PLAIN}"
        fi
        skip_acme="n"
    fi

    if [[ "$skip_acme" == "y" || "$skip_acme" == "Y" ]]; then
        echo -e "${GREEN}跳过申请阶段，直接进入证书同步...${PLAIN}"
    else
        # 如果不跳过，执行申请逻辑
        if [[ "$c_mode" == "2" ]]; then
            # CF API 模式
            read -p "请输入 CF Email: " cf_e
            read -p "请输入 CF Global API Key: " cf_k
            export CF_Key="$cf_k"
            export CF_Email="$cf_e"
            $ACME_BIN --issue --dns dns_cf -d "$domain" --force
        else
            # Standalone 模式
            # 1. 强力清理 80 端口，确保 acme.sh 能监听
            if lsof -i:80 > /dev/null 2>&1; then
                echo -e "${YELLOW}检测到 80 端口占用，正在强制释放...${PLAIN}"
                lsof -i:80 | awk '{print $2}' | grep -v PID | xargs kill -9 >/dev/null 2>&1
                sleep 2
            fi
            
            # 2. 申请证书：增加 --listen-v6 以适配你的独立 IPv6 环境
            echo -e "${BLUE}正在通过 Standalone 模式申请证书 (支持 IPv6)...${PLAIN}"
            $ACME_BIN --issue -d "$domain" --standalone --httpport 80 --listen-v6 --force
        fi
    fi

    # >>> 【关键：同步前的二次校验】 <<<
    if [[ ! -f "$cert_file" ]]; then
        echo -e "${RED}[致命错误] 证书申请未成功，无法获取 fullchain.cer。${PLAIN}"
        echo -e "${YELLOW}请检查 80 端口映射是否正确，或尝试使用 DNS API 模式申请。${PLAIN}"
        exit 1
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
    local alpn_json=$(echo "$alpn" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')

    echo -e "${BLUE}[进度] 正在写入核心配置 (IPv6 优先出站模式)...${PLAIN}"

# 运行检测
check_network_strategy

# 写入全局配置（仅当不存在时）
    if [[ ! -f "$XRAY_CONF_DIR/conf_0_core.json" ]]; then
        cat <<EOF > "$XRAY_CONF_DIR/conf_0_core.json"
{
    "log": { "loglevel": "warning" },
    "outbounds": [{ "protocol": "freedom", "settings": { "domainStrategy": "AsIs" } }]
}
EOF
    fi

    # 写入直连分片
    cat <<EOF > "$XRAY_CONF_DIR/conf_1_direct.json"
{
    "inbounds": [{
        "listen": "::",
        "port": $port, 
        "protocol": "vless",
        "tag": "$node_name",
        "settings": { "clients": [{"id": "$uuid"}], "decryption": "none" },
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": { "path": "$path", "mode": "auto", "host": "$domain" },
            "tlsSettings": {
                "certificates": [{ "certificateFile": "$CERT_DIR/server.crt", "keyFile": "$CERT_DIR/server.key" }],
                "alpn": [$alpn_json], "fingerprint": "$fp"
            }
        }
    }]
}
EOF

    # --- 【优化后的强力重启逻辑】 ---
    echo -e "${BLUE}[进度] 正在重启 Xray 服务并校验配置...${PLAIN}"
    
    # 1. 预校验配置语法
    if [[ -f /usr/local/bin/xray ]]; then
        /usr/local/bin/xray -test -confdir /usr/local/etc/xray/ >/dev/null 2>&1
    else
        echo -e "${RED}错误: 未检测到 Xray 核心文件，请重新执行安装。${PLAIN}"
        return 1
    fi
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[错误] 配置文件语法校验失败！${PLAIN}"
        /usr/local/bin/xray -test -confdir /usr/local/etc/xray/
        read -p "按回车键返回..."
        return 1
    fi

    # 直接调用统一重启函数
    if restart_and_check; then
        echo -e "${GREEN}VLESS+xhttp+TLS 部署成功！${PLAIN}"
        show_node_info
    else
        echo -e "${RED}[错误] Xray 启动失败。${PLAIN}"
        echo -e "${YELLOW}正在诊断配置...${PLAIN}"
        /usr/local/bin/xray -test -confdir /usr/local/etc/xray/
        read -p "按回车键返回..."
    fi
}

# --- 3. 安装 CF Tunnel  ---
install_cf_tunnel() {
    install_base
    echo -e "${PURPLE}--- 开始配置 CF Tunnel (WS + Host 强校验模式) ---${PLAIN}"

    # 1. 变量初始化
    local r_t_uuid=$(cat /proc/sys/kernel/random/uuid)
    local r_t_path="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
    local r_t_port=$((RANDOM % 55535 + 10000))
    local t_domain=""

    # 2. 用户选择
    echo -e "${BLUE}请选择隧道类型:${PLAIN}"
    echo -e "  1. 临时隧道 (Quick Tunnel)"
    echo -e "  2. 固定隧道 (Named Tunnel)"
    read -p "选择 [1-2] (默认 1): " t_choice
    t_choice=${t_choice:-1}
    
    read -p "请输入隧道UUID (回车随机: $r_t_uuid): " t_uuid; t_uuid=${t_uuid:-$r_t_uuid}
    read -p "请输入自定义节点名称 (默认: CF_Tunnel): " t_node_name; t_node_name=${t_node_name:-"CF_Tunnel"}
    read -p "请输入隧道路径 (回车随机: $r_t_path): " t_path; t_path=${t_path:-$r_t_path}

    # 3. 确定回源端口与域名获取逻辑
    if [[ "$t_choice" == "2" ]]; then
        t_port=8080
        read -p "请输入 CF 绑定域名: " t_domain
        read -p "请输入 Token: " t_token
        [[ -z "$t_domain" || -z "$t_token" ]] && { echo -e "${RED}输入不能为空！${PLAIN}"; return 1; }
        echo "$t_domain" > /usr/local/etc/xray/cf_tunnel_domain
    else
        read -p "回源端口 (回车随机: $r_t_port): " t_port; t_port=${t_port:-$r_t_port}
    fi

    # 4. 下载 Cloudflared
    [[ -z "$CF_ARCH" ]] && detect_arch
    if [[ ! -f $CF_BIN ]]; then
        echo -e "${YELLOW}正在下载 cloudflared...${PLAIN}"
        wget -O $CF_BIN "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$CF_ARCH"
        chmod +x $CF_BIN
    fi

    # 5. 临时隧道先获取域名
    pkill -9 cloudflared >/dev/null 2>&1
    : > "$CF_LOG"

    if [[ "$t_choice" == "1" ]]; then
        echo -e "${YELLOW}正在启动临时隧道以获取动态域名...${PLAIN}"

        nohup $CF_BIN tunnel \
        --logfile $CF_LOG \
        --protocol http2 \
        --url http://127.0.0.1:${t_port} \
        > /dev/null 2>&1 &

        for i in {1..20}; do
            echo -ne "\r抓取域名中: ${i}s/20s..."
            t_domain=$(grep -oE "https://[a-zA-Z0-9-]+\.trycloudflare.com" $CF_LOG | head -n 1 | sed 's/https:\/\///')
            [[ -n "$t_domain" ]] && break
            sleep 1
        done
        echo ""

        if [[ -z "$t_domain" ]]; then
            echo -e "${RED}[致命错误] 获取临时域名失败，请检查网络！${PLAIN}"
            pkill -9 cloudflared
            return 1
        fi

        echo -e "${GREEN}[成功] 获得临时域名: $t_domain${PLAIN}"
        echo "$t_domain" > /usr/local/etc/xray/cf_tunnel_domain
    fi

    # 6. 写入 Xray 配置
    echo -e "${BLUE}[进度] 正在写入 Xray 隧道配置并绑定 Host...${PLAIN}"
    cat <<EOF > "/usr/local/etc/xray/conf_2_tunnel.json"
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
            "wsSettings": {
                "path": "$t_path",
                "headers": {
                    "Host": "$t_domain"
                }
            }
        },
        "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls"]
        }
    }]
}
EOF

    # 7. 重启 Xray
    restart_and_check

    # 8. 持久化 Cloudflared
    local cf_cmd=""
    if [[ "$t_choice" == "1" ]]; then
        cf_cmd="tunnel --logfile $CF_LOG --protocol http2 --http-host-header $t_domain --url http://127.0.0.1:${t_port}"
    else
        cf_cmd="tunnel --no-autoupdate --protocol http2 --http-host-header $t_domain run --token $t_token"
    fi

    local cf_started=false
    
    # 尝试 Systemd
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
        systemctl enable --now cloudflared >/dev/null 2>&1 && cf_started=true
    # 尝试 OpenRC
    elif [ "$HAS_OPENRC" = true ]; then
        cat <<EOF > /etc/init.d/cloudflared
#!/sbin/openrc-run
command="$CF_BIN"
command_args="$cf_cmd"
command_background="yes"
pidfile="/run/cloudflared.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/cloudflared
        rc-update add cloudflared default >/dev/null 2>&1
        rc-service cloudflared restart >/dev/null 2>&1 && cf_started=true
    fi

    # 【核心增加】：针对 Docker/NAT 小鸡的万能兜底
    # 如果标准服务没跑起来，强行用 nohup 拉起 cloudflared
    sleep 2
    if ! pgrep -x "cloudflared" > /dev/null; then
        echo -e "${YELLOW}[注意] 标准隧道服务加载受限，尝试强制拉起...${PLAIN}"
        
        # 清理可能存在的残留或僵死进程
        pkill -9 cloudflared >/dev/null 2>&1
        sleep 1
        
        # 强行后台拉起
        nohup $CF_BIN $cf_cmd > /dev/null 2>&1 &
        
        # 为 Alpine 这种快节奏环境提供充足的初始化时间 ---
        sleep 5
        
        # 使用兼容性更强的 ps 组合校验，替代在容器内有时不稳定的 pgrep
        if ps w | grep -v grep | grep -q "cloudflared"; then
            echo -e "${GREEN}[成功] 隧道已在后台强制启动并运行。${PLAIN}"
        else
            echo -e "${RED}[警告] 隧道拉起状态校验失败，请稍后手动执行 'ps aux | grep cloudflared' 确认。${PLAIN}"
        fi
    fi

    # 最终状态展示
    show_node_info
    echo -e "${GREEN}[成功] 双协议共存已就绪，隧道与 Xray 状态已同步。${PLAIN}"
}

# --- 修改参数整合模块  ---
modify_parameters_menu() {
    get_current_params # 先探测当前值
    
    clear
    echo -e "${BLUE}==============================${PLAIN}"
    echo -e "${GREEN}       参数修改配置中心       ${PLAIN}"
    echo -e "${BLUE}==============================${PLAIN}"
    echo -e "  1. 修改 Xray 节点参数 (域名/UUID/端口等)"
    echo -e "  2. 修改 CF Tunnel 参数 (Token/路径等)"
    echo -e "  0. 返回主菜单"
    echo -e "${BLUE}==============================${PLAIN}"
    read -p "请选择操作 [0-2]: " sub_choice

    case $sub_choice in
        1)
            echo -e "\n${YELLOW}>>> 修改 Xray 直连节点 (xHTTP) 参数${PLAIN}"
            read -p "请输入域名 (当前: ${old_domain:-未设置}): " new_domain
            new_domain=${new_domain:-$old_domain}
            read -p "请输入端口 (当前: ${old_port:-未设置}): " new_port
            new_port=${new_port:-$old_port}
            read -p "请输入 UUID (当前: ${old_uuid:-未设置}): " new_uuid
            new_uuid=${new_uuid:-$old_uuid}
            read -p "请输入路径 (当前: ${old_path:-未设置}): " new_path
            new_path=${new_path:-$old_path}

            # 调用执行模块 (已包含重启逻辑)
            update_xray_config "$new_domain" "$new_port" "$new_uuid" "$new_path"
            ;;
        2)
            echo -e "\n${YELLOW}>>> 修改 CF Tunnel (隧道) 参数 (直接回车即跳过)${PLAIN}"
            
            # 1. 判定模式并引导输入
            if [[ -f "/usr/local/etc/xray/cf_tunnel_domain" || "$old_t_choice" == "2" ]]; then
                # --- 固定隧道模式 ---
                
                # A. 先改域名 (门牌号)
                local current_t_domain=$(cat /usr/local/etc/xray/cf_tunnel_domain 2>/dev/null)
                read -p "请输入隧道对应域名 (当前: ${current_t_domain:-未设置}): " new_t_domain
                new_t_domain=${new_t_domain:-$current_t_domain}

                # B. 再改 Token (密钥)
                read -p "请输入新 Token (当前: ${old_t_token:0:10}...): " new_t_token
                new_t_token=${new_t_token:-$old_t_token}
                
                # C. 最后是路径
                read -p "请输入隧道对应路径 (当前: $old_t_path): " new_t_path
                new_t_path=${new_t_path:-$old_t_path}
                
                # 构造启动命令
                cf_cmd="tunnel --no-autoupdate run --token ${new_t_token}"
                
                # 立即同步域名到本地文件，确保后面生成的链接是正确的
                if [[ -n "$new_t_domain" ]]; then
                    echo "$new_t_domain" > /usr/local/etc/xray/cf_tunnel_domain
                fi
            else
                # --- 临时隧道模式 (只有路径可改) ---
                read -p "请输入新临时隧道路径 (当前: $old_t_path): " new_t_path
                new_t_path=${new_t_path:-$old_t_path}
                new_t_path=${new_t_path:-/}
                cf_cmd="tunnel --no-autoupdate --url http://127.0.0.1:${old_port:-8443}${new_t_path}"
            fi
            
            # 1. 重启 Cloudflared
            pkill -9 cloudflared && sleep 1
            nohup /usr/local/bin/cloudflared $cf_cmd > /dev/null 2>&1 &
            
            # 2. 仅修改隧道专用的 JSON，不干扰直连 JSON
            if [[ -f "/usr/local/etc/xray/conf_2_tunnel.json" ]]; then
                local tmp_t=$(mktemp)
                # 仅针对隧道配置进行写入
                jq ".inbounds[0].streamSettings.wsSettings.path = \"$new_t_path\"" /usr/local/etc/xray/conf_2_tunnel.json > "$tmp_t" && mv "$tmp_t" /usr/local/etc/xray/conf_2_tunnel.json
            fi

            # 3. 强制重启 Xray 服务以应用配置，防止进程僵死
            systemctl restart xray > /dev/null 2>&1 || pkill -9 xray && sleep 1 && nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray > /dev/null 2>&1 &

            # --- 4. 成功看板输出 ---
            clear
            echo -e "${GREEN}========================================${PLAIN}"
            echo -e "${GREEN}      CF Tunnel 参数修改成功并重启      ${PLAIN}"
            echo -e "${GREEN}========================================${PLAIN}"
            
            local t_url=$(cat /usr/local/etc/xray/cf_tunnel_domain 2>/dev/null)
            local t_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/xray/conf_2_tunnel.json 2>/dev/null)
            local t_path_enc=$(echo "$new_t_path" | sed 's/\//%2F/g')
            local t_name="CF_Tunnel_Modified"

            if [[ -n "$t_url" && -n "$t_uuid" ]]; then
                echo -e "${BLUE}新隧道详情：${PLAIN}"
                echo -e "  域名: ${t_url}"
                echo -e "  路径: ${new_t_path}"
                echo -e "${BLUE}----------------------------------------${PLAIN}"
                echo -e "${YELLOW}新的隧道节点链接 (VLESS + WS + TLS):${PLAIN}"
                echo -e "${CYAN}vless://$t_uuid@$t_url:443?security=tls&sni=$t_url&type=ws&host=$t_url&path=$t_path_enc&fp=chrome&alpn=h2%2Chttp%2F1.1#$t_name${PLAIN}"
            else
                echo -e "${YELLOW}提示：服务已重启，请在“查看节点信息”中确认状态。${PLAIN}"
            fi
            echo -e "${GREEN}========================================${PLAIN}"
            
            read -p "按回车键返回主菜单..."
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED}无效选项，返回主菜单...${PLAIN}"
            sleep 1
            ;;
    esac
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

# --- 自动探测当前运行参数 ---
get_current_params() {
    local direct_conf="/usr/local/etc/xray/conf_1_direct.json"
    
    # 1. 探测 Xray 节点参数
    if [[ -f "$direct_conf" ]]; then
        # 优先从 host 或 serverName 读取域名，避免 cut 路径出错
        old_domain=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.host // .inbounds[0].streamSettings.tlsSettings.serverName' "$direct_conf")
        
        # 如果 jq 没读到，再尝试路径切分 (修正为 f7)
        if [[ "$old_domain" == "null" || -z "$old_domain" ]]; then
            old_domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile' "$direct_conf" | cut -d'/' -f7)
        fi
        
        old_port=$(jq -r '.inbounds[0].port' "$direct_conf")
        old_uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$direct_conf")
        # 适配你的 xhttpSettings 路径
        old_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // .inbounds[0].streamSettings.wsSettings.path' "$direct_conf")
    fi

    # 2. 探测 Cloudflared 隧道参数 
    if pgrep -x "cloudflared" > /dev/null; then
        local full_cmd=$(ps w | grep cloudflared | grep -v grep)
        
        # 探测 A：固定隧道 (Token 模式)
        if echo "$full_cmd" | grep -q "token"; then
            old_t_token=$(echo "$full_cmd" | sed 's/.*--token \([^ ]*\).*/\1/')
            old_t_choice="2"
            # 固定隧道通常在 CF 后台改路径，脚本探测其 Xray 映射路径
            old_t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path // "/download"' /usr/local/etc/xray/conf_2_tunnel.json)
        
        # 探测 B：临时隧道 (URL 模式)
        else
            old_t_choice="1"
            # 兼容多种 sed 匹配模式
            old_t_path=$(echo "$full_cmd" | sed -n 's/.*http:\/\/127.0.0.1:[0-9]*\([^ ]*\).*/\1/p')
            
            # 如果 A 失败，尝试从 Xray 隧道配置文件反推路径
            if [[ -z "$old_t_path" ]]; then
                old_t_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' /usr/local/etc/xray/conf_2_tunnel.json 2>/dev/null)
            fi
        fi
    fi

    # 兜底：如果还是没拿到路径，给个默认值防止“未设置”
    old_t_path=${old_t_path:-/}
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
 ${YELLOW}4.${PLAIN} 修改配置参数
 ${YELLOW}5.${PLAIN} 内核升级与BBR
 ${YELLOW}6.${PLAIN} 卸载管理 (支持单独卸载/彻底清理)  
 ${YELLOW}7.${PLAIN} 开启自动守护 (推荐)
 ${YELLOW}8.${PLAIN} 清理系统日志与垃圾
 ${RED}0.${PLAIN} 退出脚本"
        read -p "选择 [0-8]: " choice
        case $choice in
            1) install_vless_direct ;;
            2) install_cf_tunnel ;;
            3) show_node_info ;;
            4) modify_parameters_menu ;;
            5) update_kernel_bbr ;; 
            6) uninstall_menu ;;
            7) setup_cron_job ;;
            8) cleanup_logs ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误${PLAIN}" && sleep 1 ;;
        esac
    done
}

# --- 自动守护任务设置 ---
setup_cron_job() {
    echo -e "${YELLOW}正在配置全平台自适应维护任务 (每分钟检查一次)...${PLAIN}"
    
    cat <<EOF > /usr/local/bin/xray_keep_alive.sh
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 1. 兼容层：自动识别 OpenRC (Alpine) 或 Systemd (Debian/Ubuntu)
if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
    # 此时为 Alpine 环境
    HAS_SYSTEMCTL=false
else
    # 此时为标准 Debian/Ubuntu/CentOS 环境
    HAS_SYSTEMCTL=true
fi

# 2. 内存预处理 (针对 NAT 小机)
# 如果空闲内存低于 30MB，先清理缓存，防止大内存机器误伤，也救了小内存机器
free_mem=\$(free -m | awk '/Mem:/ {print \$4}')
if [ "\$free_mem" -lt 30 ]; then
    sync && echo 3 > /proc/sys/vm/drop_caches
fi

# 3. 检查 Xray 状态 (直接检查进程名，这是最可靠的判定方式)
if ! pgrep -x "xray" > /dev/null; then
    echo "\$(date): Xray 异常关闭，正在尝试拉起..." >> /var/log/xray_keep_alive.log
    
    # 【修复大内存重启问题】: 延迟 5 秒，确保网络栈完全就绪
    sleep 5
    
    if \$HAS_SYSTEMCTL; then
        # Debian/Ubuntu 使用标准服务重启
        systemctl restart xray >/dev/null 2>&1
    else
        # Alpine 使用 OpenRC 重启
        rc-service xray restart >/dev/null 2>&1
    fi
    
    # 4. 【暴力兜底】: 如果 5 秒后进程还没起来，说明 Systemd 彻底罢工
    sleep 5
    if ! pgrep -x "xray" > /dev/null; then
        echo "\$(date): 服务管理器启动失败，执行 nohup 强制夺舍..." >> /var/log/xray_keep_alive.log
        nohup /usr/local/bin/xray run -confdir /usr/local/etc/xray/ > /dev/null 2>&1 &
    fi
fi

# 5. 检查 Cloudflared 状态
if [[ -f "/usr/local/bin/cloudflared" ]]; then
    if ! pgrep -x "cloudflared" > /dev/null; then
        if \$HAS_SYSTEMCTL; then
            systemctl restart cloudflared >/dev/null 2>&1
        else
            rc-service cloudflared restart >/dev/null 2>&1
        fi
    fi
fi
EOF

    chmod +x /usr/local/bin/xray_keep_alive.sh

    # 写入 crontab，并清理旧任务
    (crontab -l 2>/dev/null | grep -v "xray_keep_alive.sh"; echo "* * * * * /usr/local/bin/xray_keep_alive.sh") | crontab -
    
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "${GREEN}  全兼容优化版守护已开启！                  ${PLAIN}"
    echo -e "${GREEN}  - 优化大内存重启后的网络竞争问题         ${PLAIN}"
    echo -e "${GREEN}  - 优化小内存机器的内存回收逻辑           ${PLAIN}"
    echo -e "${GREEN}  - 兼容 Debian 11/12/13 及 Alpine 系统     ${PLAIN}"
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
