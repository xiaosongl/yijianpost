#!/bin/bash
# ╔══════════════════════════════════════════════════════════════╗
# ║         PowerMTA 5.0 一键部署管理脚本                        ║
# ║         适用于 Ubuntu 22.04 LTS  |  需要 root 权限           ║
# ║         用法: bash pmta.sh                                    ║
# ╚══════════════════════════════════════════════════════════════╝

set -euo pipefail

# ══════════════════════════════════════════════════════════════
#  颜色 & 输出
# ══════════════════════════════════════════════════════════════
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
C='\033[0;36m'  B='\033[1;34m'  W='\033[1;37m'  N='\033[0m'

info()    { echo -e "${C}  ●${N} $1"; }
ok()      { echo -e "${G}  ✔${N} $1"; }
warn()    { echo -e "${Y}  ⚠${N} $1"; }
err()     { echo -e "${R}  ✘${N} $1"; }
die()     { err "$1"; exit 1; }
title()   { echo -e "\n${B}  ══ $1 ══${N}"; }
sep()     { echo -e "${B}  ────────────────────────────────────────${N}"; }

# ══════════════════════════════════════════════════════════════
#  常量
# ══════════════════════════════════════════════════════════════
CONF_FILE="/etc/pmta/pmta_deploy.conf"   # 持久化配置
PMTA_CONF="/etc/pmta/config"
PMTA_LOG="/var/log/pmta"
PMTA_SPOOL="/var/spool/pmta"
PMTA_BIN="/usr/sbin"
WORK_DIR="/tmp/pmta_install_$$"

# GitHub Release 默认下载地址（可在菜单中修改）
DEFAULT_DOWNLOAD_URL="https://github.com/xiaosongl/yijianpost/releases/latest/download/PMTA.tar.gz"

# ══════════════════════════════════════════════════════════════
#  root 检查
# ══════════════════════════════════════════════════════════════
[[ $EUID -ne 0 ]] && die "请使用 root 权限运行: sudo bash pmta.sh"

# ══════════════════════════════════════════════════════════════
#  配置持久化：保存 / 读取
# ══════════════════════════════════════════════════════════════
save_conf() {
    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
DOWNLOAD_URL="$DOWNLOAD_URL"
DOMAIN="$DOMAIN"
MAIL_PREFIX="$MAIL_PREFIX"
SERVER_IP="$SERVER_IP"
CF_API_TOKEN="$CF_API_TOKEN"
CF_ZONE_ID="$CF_ZONE_ID"
EOF
    chmod 600 "$CONF_FILE"
}

load_conf() {
    DOWNLOAD_URL="$DEFAULT_DOWNLOAD_URL"
    DOMAIN=""
    MAIL_PREFIX="mail"
    SERVER_IP=""
    CF_API_TOKEN=""
    CF_ZONE_ID=""
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
    # 自动获取公网 IP（如果没有保存过）
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s --max-time 6 ifconfig.me 2>/dev/null || \
                    curl -s --max-time 6 api.ipify.org 2>/dev/null || \
                    hostname -I | awk '{print $1}')
    fi
}

# ══════════════════════════════════════════════════════════════
#  通用输入函数
#  input_field "提示" 变量名 "默认值"
# ══════════════════════════════════════════════════════════════
input_field() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${Y}[默认: $default]${N}"
    echo -ne "${C}  ${prompt}${hint}: ${N}"
    read -r input
    if [[ -z "$input" && -n "$default" ]]; then
        printf -v "$var_name" '%s' "$default"
    else
        printf -v "$var_name" '%s' "$input"
    fi
}

input_secret() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${Y}[已保存，回车保留]${N}"
    echo -ne "${C}  ${prompt}${hint}: ${N}"
    read -r -s input
    echo ""
    if [[ -z "$input" && -n "$default" ]]; then
        printf -v "$var_name" '%s' "$default"
    else
        printf -v "$var_name" '%s' "$input"
    fi
}

# ══════════════════════════════════════════════════════════════
#  按键确认
# ══════════════════════════════════════════════════════════════
press_any_key() { echo -ne "\n${Y}  按回车键返回菜单...${N}"; read -r; }

confirm() {
    echo -ne "${Y}  $1 (y/N): ${N}"
    read -r ans
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ══════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════
show_banner() {
    clear
    echo -e "${B}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║                                                      ║"
    echo "  ║        PowerMTA 5.0  一键部署管理工具                ║"
    echo "  ║        Ubuntu 22.04 LTS  |  By: 一键邮局             ║"
    echo "  ║                                                      ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${N}"

    # 显示当前状态
    local status_str
    if systemctl is-active --quiet pmta 2>/dev/null; then
        status_str="${G}● 运行中${N}"
    elif pgrep -x pmtad &>/dev/null; then
        status_str="${G}● 运行中${N}"
    else
        status_str="${R}○ 未运行${N}"
    fi

    echo -e "  服务器IP : ${C}${SERVER_IP:-未检测}${N}   PMTA状态: $status_str"
    echo -e "  域名     : ${C}${DOMAIN:-未配置}${N}"
    sep
}

# ══════════════════════════════════════════════════════════════
#  主菜单
# ══════════════════════════════════════════════════════════════
main_menu() {
    while true; do
        load_conf
        show_banner
        echo -e "  ${W}请选择操作:${N}\n"
        echo -e "  ${G}[1]${N}  一键安装 PowerMTA"
        echo -e "  ${G}[2]${N}  配置 Cloudflare DNS 解析"
        echo -e "  ${G}[3]${N}  修改部署配置（域名/IP/下载地址等）"
        echo -e "  ${G}[4]${N}  查看 PMTA 运行状态 & 日志"
        echo -e "  ${G}[5]${N}  启动 / 停止 / 重启 PMTA"
        echo -e "  ${G}[6]${N}  卸载 PowerMTA"
        echo -e "  ${R}[0]${N}  退出\n"
        sep
        echo -ne "  ${W}请输入选项 [0-6]: ${N}"
        read -r choice
        case "$choice" in
            1) menu_install ;;
            2) menu_dns ;;
            3) menu_config ;;
            4) menu_status ;;
            5) menu_service ;;
            6) menu_uninstall ;;
            0) echo -e "\n${G}  再见！${N}\n"; exit 0 ;;
            *) warn "无效选项，请重新输入" ; sleep 1 ;;
        esac
    done
}

# ══════════════════════════════════════════════════════════════
#  [3] 修改部署配置
# ══════════════════════════════════════════════════════════════
menu_config() {
    show_banner
    title "修改部署配置"
    echo ""
    echo -e "  当前配置:"
    echo -e "    安装包   : ${C}${DOWNLOAD_URL}${N}"
    echo -e "    主域名   : ${C}${DOMAIN:-未设置}${N}"
    echo -e "    邮件前缀 : ${C}${MAIL_PREFIX}${N}  →  ${C}${MAIL_PREFIX}.${DOMAIN:-example.com}${N}"
    echo -e "    服务器IP : ${C}${SERVER_IP}${N}"
    echo -e "    CF Token : ${C}${CF_API_TOKEN:+已设置（隐藏）}${CF_API_TOKEN:-未设置}${N}"
    echo -e "    CF ZoneID: ${C}${CF_ZONE_ID:-未设置}${N}"
    echo ""
    sep
    echo ""

    input_field "主域名 (如 example.com)" DOMAIN "$DOMAIN"
    input_field "邮件子域名前缀 (如 mail → mail.example.com)" MAIL_PREFIX "$MAIL_PREFIX"
    input_field "服务器公网 IP" SERVER_IP "$SERVER_IP"
    input_secret "Cloudflare API Token" CF_API_TOKEN "$CF_API_TOKEN"
    input_field "Cloudflare Zone ID" CF_ZONE_ID "$CF_ZONE_ID"

    save_conf
    ok "配置已保存到 $CONF_FILE"
    press_any_key
}

# ══════════════════════════════════════════════════════════════
#  [1] 一键安装
# ══════════════════════════════════════════════════════════════
menu_install() {
    show_banner
    title "一键安装 PowerMTA 5.0"

    # 检查是否已安装
    if command -v pmtad &>/dev/null || [[ -f "$PMTA_BIN/pmtad" ]]; then
        warn "检测到 PowerMTA 已安装"
        if ! confirm "是否重新安装？"; then
            press_any_key; return
        fi
    fi

    # 确认配置
    echo ""
    echo -e "  即将使用以下配置安装:"
    echo -e "    下载地址 : ${C}${DOWNLOAD_URL}${N}"
    echo -e "    主域名   : ${C}${DOMAIN:-（安装后配置）}${N}"
    echo -e "    服务器IP : ${C}${SERVER_IP}${N}"
    echo ""

    if ! confirm "确认开始安装？"; then
        press_any_key; return
    fi

    echo ""
    # ── 步骤 1：安装依赖 ──────────────────────────────────────
    title "步骤 1/6  安装系统依赖"
    apt-get update -qq 2>&1 | tail -1
    apt-get install -y -qq \
        alien wget curl tar jq \
        libssl-dev libpcre3 libpcre3-dev \
        opendkim opendkim-tools \
        net-tools dnsutils ufw 2>/dev/null || true
    ok "依赖安装完成"

    # ── 步骤 2：下载压缩包 ────────────────────────────────────
    title "步骤 2/6  下载 PMTA 安装包"
    mkdir -p "$WORK_DIR"
    info "下载地址: $DOWNLOAD_URL"
    wget -q --show-progress -O "$WORK_DIR/PMTA.tar.gz" "$DOWNLOAD_URL" || \
        die "下载失败，请检查下载地址或网络连接"
    ok "下载完成"

    # ── 步骤 3：解压 ──────────────────────────────────────────
    title "步骤 3/6  解压安装包"
    tar -xzf "$WORK_DIR/PMTA.tar.gz" -C "$WORK_DIR/" 2>/dev/null || \
        die "解压失败，请检查压缩包是否完整"
    ok "解压完成"

    # ── 步骤 4：安装 PowerMTA ─────────────────────────────────
    title "步骤 4/6  安装 PowerMTA"
    _do_install_pmta
    ok "PowerMTA 安装完成"

    # ── 步骤 5：写入配置 ──────────────────────────────────────
    title "步骤 5/6  生成配置文件"
    _gen_pmta_config
    ok "配置文件已生成: $PMTA_CONF"

    # ── 步骤 6：启动服务 ──────────────────────────────────────
    title "步骤 6/6  启动 PowerMTA 服务"
    _setup_service
    _setup_firewall
    _start_pmta

    # 清理
    rm -rf "$WORK_DIR"

    # 摘要
    echo ""
    echo -e "${G}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              安装完成！                              ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${N}"
    echo -e "  配置文件 : ${C}$PMTA_CONF${N}"
    echo -e "  日志目录 : ${C}$PMTA_LOG${N}"
    echo -e "  管理面板 : ${C}http://${SERVER_IP}:8080${N}"
    echo ""
    warn "如需配置 DNS，请返回主菜单选择【配置 Cloudflare DNS 解析】"
    press_any_key
}

# ── 安装 PowerMTA 核心逻辑 ────────────────────────────────────
_do_install_pmta() {
    local rpm_file
    rpm_file=$(find "$WORK_DIR" -name "*.rpm" 2>/dev/null | head -1)

    if [[ -n "$rpm_file" ]]; then
        info "找到 RPM 包，使用 alien 转换为 DEB..."
        cd "$(dirname "$rpm_file")"
        alien --to-deb --scripts "$rpm_file" -q 2>/dev/null || \
            alien -d "$rpm_file" 2>/dev/null || \
            die "RPM 转换失败"

        local deb_file
        deb_file=$(find "$(dirname "$rpm_file")" -name "*.deb" 2>/dev/null | head -1)
        [[ -z "$deb_file" ]] && die "DEB 包生成失败"

        info "安装 DEB 包..."
        dpkg -i "$deb_file" 2>/dev/null || apt-get install -f -y -qq 2>/dev/null || true
    else
        info "未找到 RPM，直接部署二进制文件..."
        _deploy_binary
    fi

    # 安装 license
    local license_file
    license_file=$(find "$WORK_DIR" -name "license" 2>/dev/null | head -1)
    if [[ -n "$license_file" ]]; then
        mkdir -p /etc/pmta
        cp "$license_file" /etc/pmta/license
        ok "License 已安装"
    else
        warn "未找到 license 文件，请手动放置到 /etc/pmta/license"
    fi
}

_deploy_binary() {
    local pmtad pmtahttpd
    pmtad=$(find "$WORK_DIR" -name "pmtad" 2>/dev/null | head -1)
    pmtahttpd=$(find "$WORK_DIR" -name "pmtahttpd" 2>/dev/null | head -1)
    [[ -z "$pmtad" ]] && die "压缩包中未找到 pmtad，请检查压缩包内容"
    cp "$pmtad" "$PMTA_BIN/pmtad" && chmod +x "$PMTA_BIN/pmtad"
    [[ -n "$pmtahttpd" ]] && cp "$pmtahttpd" "$PMTA_BIN/pmtahttpd" && chmod +x "$PMTA_BIN/pmtahttpd"
}

_gen_pmta_config() {
    mkdir -p /etc/pmta "$PMTA_LOG" "$PMTA_SPOOL"
    local domain="${DOMAIN:-mail.example.com}"
    local smtp_domain
    smtp_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    local mail_host="${MAIL_PREFIX:-mail}.${smtp_domain}"

    cat > "$PMTA_CONF" <<EOF
# PowerMTA 5.0 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

smtp-listener 0.0.0.0:25
http-listener 0.0.0.0:8080

log-file $PMTA_LOG/pmta.log
log-rotate daily
log-max-size 100m
spool-dir $PMTA_SPOOL

max-smtp-out 100
max-smtp-in  50

<domain $smtp_domain>
    max-smtp-out 50
    max-msg-rate 1000/h
    bounce-after 3d
    defer-after  2h
</domain>

<source $SERVER_IP>
    smtp-source-host $SERVER_IP $mail_host
</source>

<virtual-mta main>
    smtp-source-host $SERVER_IP $mail_host
</virtual-mta>

<virtual-mta-pool default>
    virtual-mta main
</virtual-mta-pool>

<queue *@*>
    virtual-mta-pool default
    max-msg-rate 500/h
    max-smtp-out 20
</queue>
EOF
}

_setup_service() {
    if [[ ! -f /etc/systemd/system/pmta.service ]] && \
       [[ ! -f /lib/systemd/system/pmta.service ]]; then
        cat > /etc/systemd/system/pmta.service <<EOF
[Unit]
Description=PowerMTA Mail Transfer Agent
After=network.target

[Service]
Type=forking
ExecStart=$PMTA_BIN/pmtad
ExecStop=$PMTA_BIN/pmtad --stop
PIDFile=/var/run/pmtad.pid
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi
    systemctl daemon-reload
    systemctl enable pmta 2>/dev/null || true
}

_setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow 25/tcp   comment "SMTP"     2>/dev/null || true
        ufw allow 465/tcp  comment "SMTPS"    2>/dev/null || true
        ufw allow 587/tcp  comment "SMTP提交"  2>/dev/null || true
        ufw allow 8080/tcp comment "PMTA管理"  2>/dev/null || true
        ok "防火墙端口已开放: 25 / 465 / 587 / 8080"
    fi
}

_start_pmta() {
    systemctl start pmta 2>/dev/null || "$PMTA_BIN/pmtad" 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet pmta 2>/dev/null || pgrep -x pmtad &>/dev/null; then
        ok "PowerMTA 已启动"
    else
        warn "未能自动启动，请检查配置后手动执行: systemctl start pmta"
    fi
}

# ══════════════════════════════════════════════════════════════
#  [2] Cloudflare DNS 配置
# ══════════════════════════════════════════════════════════════
menu_dns() {
    show_banner
    title "配置 Cloudflare DNS 解析"

    # 检查必要配置
    if [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$DOMAIN" ]]; then
        warn "Cloudflare 配置不完整，请先填写"
        echo ""
        input_field "主域名 (如 example.com)" DOMAIN "$DOMAIN"
        input_field "邮件子域名前缀 (如 mail)" MAIL_PREFIX "$MAIL_PREFIX"
        input_field "服务器公网 IP" SERVER_IP "$SERVER_IP"
        input_secret "Cloudflare API Token" CF_API_TOKEN "$CF_API_TOKEN"
        input_field "Cloudflare Zone ID" CF_ZONE_ID "$CF_ZONE_ID"
        save_conf
    fi

    local mail_host="${MAIL_PREFIX}.${DOMAIN}"

    echo ""
    echo -e "  即将添加以下 DNS 记录:"
    sep
    echo -e "  ${G}A${N}     ${C}$mail_host${N}  →  ${C}$SERVER_IP${N}  (不代理)"
    echo -e "  ${G}MX${N}    ${C}$DOMAIN${N}  →  ${C}$mail_host${N}  (优先级 10)"
    echo -e "  ${G}TXT${N}   ${C}$DOMAIN${N}  →  SPF: v=spf1 ip4:$SERVER_IP mx ~all"
    echo -e "  ${G}TXT${N}   ${C}_dmarc.$DOMAIN${N}  →  v=DMARC1; p=none"
    echo -e "  ${G}TXT${N}   ${C}pmta._domainkey.$DOMAIN${N}  →  DKIM 公钥（自动生成）"
    sep
    echo ""

    if ! confirm "确认添加以上 DNS 记录？"; then
        press_any_key; return
    fi

    # 检查依赖
    command -v jq &>/dev/null || apt-get install -y -qq jq

    echo ""
    title "验证 API Token"
    _cf_verify_token || { press_any_key; return; }

    title "添加 DNS 记录"
    _cf_add_record "A"   "$mail_host"       "$SERVER_IP"                              "false"
    _cf_add_record "MX"  "$DOMAIN"          "$mail_host"                              "false" "10"
    _cf_add_record "TXT" "$DOMAIN"          "v=spf1 ip4:$SERVER_IP mx ~all"           "false"
    _cf_add_record "TXT" "_dmarc.$DOMAIN"   "v=DMARC1; p=none; rua=mailto:dmarc@$DOMAIN" "false"

    title "生成并添加 DKIM"
    _gen_and_add_dkim

    echo ""
    echo -e "${G}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              DNS 配置完成！                          ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${N}"
    warn "PTR 反向解析需在服务器提供商控制台手动设置:"
    warn "  将 $SERVER_IP 的 PTR 设置为 $mail_host"
    echo ""
    info "DNS 生效通常需要 1-5 分钟，可用以下命令验证:"
    echo -e "  ${C}dig MX $DOMAIN${N}"
    echo -e "  ${C}dig A $mail_host${N}"
    press_any_key
}

# ── CF API 封装 ───────────────────────────────────────────────
_cf_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    if [[ -n "$data" ]]; then
        curl -s -X "$method" "https://api.cloudflare.com/client/v4/$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "$data"
    else
        curl -s -X "$method" "https://api.cloudflare.com/client/v4/$endpoint" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json"
    fi
}

_cf_verify_token() {
    local res
    res=$(_cf_api GET "user/tokens/verify")
    if [[ "$(echo "$res" | jq -r '.success')" == "true" ]]; then
        ok "API Token 验证通过"
        return 0
    else
        local msg
        msg=$(echo "$res" | jq -r '.errors[0].message // "未知错误"')
        err "API Token 验证失败: $msg"
        return 1
    fi
}

_cf_delete_existing() {
    local type="$1" name="$2"
    local res ids
    res=$(_cf_api GET "zones/$CF_ZONE_ID/dns_records?type=$type&name=$name")
    ids=$(echo "$res" | jq -r '.result[].id' 2>/dev/null || true)
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        _cf_api DELETE "zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
    done <<< "$ids"
}

_cf_add_record() {
    local type="$1" name="$2" content="$3" proxied="${4:-false}" priority="${5:-}"
    _cf_delete_existing "$type" "$name"

    local data
    if [[ "$type" == "MX" ]]; then
        data=$(jq -n --arg t "$type" --arg n "$name" --arg c "$content" \
            --argjson p "${priority:-10}" \
            '{type:$t,name:$n,content:$c,priority:$p,ttl:1}')
    else
        data=$(jq -n --arg t "$type" --arg n "$name" --arg c "$content" \
            --argjson px "$proxied" \
            '{type:$t,name:$n,content:$c,proxied:$px,ttl:1}')
    fi

    local res
    res=$(_cf_api POST "zones/$CF_ZONE_ID/dns_records" "$data")
    if [[ "$(echo "$res" | jq -r '.success')" == "true" ]]; then
        ok "添加 $type  $name → $content"
    else
        local msg
        msg=$(echo "$res" | jq -r '.errors[0].message // "未知错误"')
        warn "添加 $type 失败: $msg"
    fi
}

_gen_and_add_dkim() {
    command -v opendkim-genkey &>/dev/null || \
        apt-get install -y -qq opendkim-tools 2>/dev/null || { warn "opendkim-tools 不可用，跳过 DKIM"; return; }

    local dkim_dir="/etc/pmta/dkim"
    mkdir -p "$dkim_dir"
    opendkim-genkey -b 2048 -d "$DOMAIN" -s "pmta" -D "$dkim_dir/" 2>/dev/null || \
        { warn "DKIM 密钥生成失败，跳过"; return; }

    # 提取公钥
    local pub_key
    pub_key=$(grep -oP '(?<=p=)[A-Za-z0-9+/=]+' "$dkim_dir/pmta.txt" 2>/dev/null | tr -d '\n')
    if [[ -z "$pub_key" ]]; then
        # 备用提取方式
        pub_key=$(cat "$dkim_dir/pmta.txt" | tr -d '\n' | grep -oP 'p=[A-Za-z0-9+/=]+' | sed 's/p=//')
    fi

    if [[ -n "$pub_key" ]]; then
        _cf_add_record "TXT" "pmta._domainkey.$DOMAIN" "v=DKIM1; k=rsa; p=$pub_key" "false"
        ok "DKIM 私钥: $dkim_dir/pmta.private"
    else
        warn "无法提取 DKIM 公钥，请手动添加"
        info "公钥文件: $dkim_dir/pmta.txt"
    fi
}

# ══════════════════════════════════════════════════════════════
#  [4] 查看状态 & 日志
# ══════════════════════════════════════════════════════════════
menu_status() {
    show_banner
    title "PMTA 运行状态"
    echo ""

    # 服务状态
    if systemctl is-active --quiet pmta 2>/dev/null; then
        echo -e "  服务状态 : ${G}● 运行中${N}"
    else
        echo -e "  服务状态 : ${R}○ 未运行${N}"
    fi

    # 进程信息
    local pid
    pid=$(pgrep -x pmtad 2>/dev/null || echo "")
    if [[ -n "$pid" ]]; then
        echo -e "  进程 PID : ${C}$pid${N}"
        local mem
        mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}' || echo "N/A")
        echo -e "  内存占用 : ${C}$mem${N}"
    fi

    # 端口监听
    echo ""
    echo -e "  端口监听:"
    ss -tlnp 2>/dev/null | grep -E ':(25|465|587|8080)\s' | while read -r line; do
        echo -e "    ${G}✔${N} $line"
    done || echo -e "    ${Y}未检测到监听端口${N}"

    # 日志
    echo ""
    sep
    echo -e "  ${W}最近日志 (最后 20 行):${N}"
    sep
    if [[ -f "$PMTA_LOG/pmta.log" ]]; then
        tail -20 "$PMTA_LOG/pmta.log" | sed 's/^/  /'
    else
        warn "日志文件不存在: $PMTA_LOG/pmta.log"
    fi

    echo ""
    echo -e "  ${C}实时日志: tail -f $PMTA_LOG/pmta.log${N}"
    press_any_key
}

# ══════════════════════════════════════════════════════════════
#  [5] 启动 / 停止 / 重启
# ══════════════════════════════════════════════════════════════
menu_service() {
    show_banner
    title "PMTA 服务控制"
    echo ""
    echo -e "  ${G}[1]${N}  启动 PMTA"
    echo -e "  ${G}[2]${N}  停止 PMTA"
    echo -e "  ${G}[3]${N}  重启 PMTA"
    echo -e "  ${G}[4]${N}  查看 systemctl 状态"
    echo -e "  ${R}[0]${N}  返回\n"
    sep
    echo -ne "  ${W}请输入选项: ${N}"
    read -r sc
    case "$sc" in
        1)
            systemctl start pmta 2>/dev/null || "$PMTA_BIN/pmtad" 2>/dev/null || warn "启动失败"
            sleep 1
            systemctl is-active --quiet pmta 2>/dev/null && ok "PMTA 已启动" || warn "启动可能失败，请查看日志"
            ;;
        2)
            systemctl stop pmta 2>/dev/null || pkill pmtad 2>/dev/null || warn "停止失败"
            ok "PMTA 已停止"
            ;;
        3)
            systemctl restart pmta 2>/dev/null || { pkill pmtad 2>/dev/null; sleep 1; "$PMTA_BIN/pmtad" 2>/dev/null; }
            sleep 1
            ok "PMTA 已重启"
            ;;
        4)
            systemctl status pmta 2>/dev/null || echo "systemd 服务未注册"
            ;;
        0) return ;;
    esac
    press_any_key
}

# ══════════════════════════════════════════════════════════════
#  [6] 卸载
# ══════════════════════════════════════════════════════════════
menu_uninstall() {
    show_banner
    title "卸载 PowerMTA"
    echo ""
    warn "此操作将删除 PowerMTA 程序、配置文件和日志！"
    echo ""
    if ! confirm "确认卸载 PowerMTA？"; then
        press_any_key; return
    fi

    info "停止服务..."
    systemctl stop pmta 2>/dev/null || pkill pmtad 2>/dev/null || true
    systemctl disable pmta 2>/dev/null || true
    rm -f /etc/systemd/system/pmta.service
    systemctl daemon-reload 2>/dev/null || true

    info "删除程序文件..."
    rm -f "$PMTA_BIN/pmtad" "$PMTA_BIN/pmtahttpd"

    info "删除配置和日志..."
    rm -rf /etc/pmta "$PMTA_LOG" "$PMTA_SPOOL"

    # 尝试卸载 deb 包
    dpkg -r powermta 2>/dev/null || true
    dpkg -r powermta-mta 2>/dev/null || true

    ok "PowerMTA 已卸载完成"
    press_any_key
}

# ══════════════════════════════════════════════════════════════
#  入口
# ══════════════════════════════════════════════════════════════
load_conf
main_menu
