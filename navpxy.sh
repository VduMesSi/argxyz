
#!/usr/bin/env bash
#
# NaiveProxy Manager
# Ubuntu 22.04 / 24.04
# Caddy + klzgrad/forwardproxy@naive
#
# Usage:
#   sudo bash naiveproxy.sh
#

set -Eeuo pipefail

APP="NaiveProxy"
BIN="/usr/local/bin/caddy"
CONFIG_DIR="/etc/caddy"
CONFIG="$CONFIG_DIR/Caddyfile"
SERVICE="/etc/systemd/system/caddy.service"
DATA_DIR="/var/lib/caddy"
LOG_DIR="/var/log/caddy"
BUILD_DIR="/tmp/naiveproxy-build"
MODULE="github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

pause() {
    read -rp "按 Enter 键继续..."
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "请使用 root 或 sudo 运行"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法识别操作系统"
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]] ||
       [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
        error "仅支持 Ubuntu 22.04 / 24.04"
        exit 1
    fi
}

check_arch() {
    case "$(uname -m)" in
        x86_64)
            GOARCH="amd64"
            ;;
        aarch64|arm64)
            GOARCH="arm64"
            ;;
        *)
            error "不支持的 CPU 架构: $(uname -m)"
            exit 1
            ;;
    esac

    info "系统架构: $GOARCH"
}

install_dependencies() {
    info "安装系统依赖..."

    apt-get update

    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl \
        wget \
        jq \
        tar \
        gzip \
        git \
        build-essential \
        ca-certificates \
        debianutils \
        libcap2-bin \
        openssl \
        iproute2
}

install_go() {
    info "检查 Go 环境..."

    local go_version
    local go_file
    local go_url

    go_version=$(curl -fsSL https://go.dev/dl/?mode=json |
        jq -r '[.[] | select(.stable == true)][0].version')

    if [[ -z "$go_version" || "$go_version" == "null" ]]; then
        error "无法获取 Go 版本"
        return 1
    fi

    go_file=$(curl -fsSL https://go.dev/dl/?mode=json |
        jq -r --arg arch "$GOARCH" \
        '[.[] | select(.stable == true)][0].files[] |
        select(.os == "linux" and .arch == $arch and .kind == "archive") |
        .filename' | head -n1)

    if [[ -z "$go_file" ]]; then
        error "无法获取 Go 下载文件"
        return 1
    fi

    go_url="https://go.dev/dl/$go_file"

    if command -v go >/dev/null 2>&1; then
        local current
        current=$(go version | awk '{print $3}')

        if [[ "$current" == "$go_version" ]]; then
            info "Go 已是最新版本: $current"
            return 0
        fi
    fi

    info "安装 Go: $go_version"

    mkdir -p "$BUILD_DIR"

    curl -fL --retry 3 "$go_url" \
        -o "$BUILD_DIR/$go_file"

    rm -rf /usr/local/go

    tar -C /usr/local -xzf "$BUILD_DIR/$go_file"

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
}

build_caddy() {
    info "开始编译 NaiveProxy Caddy..."

    mkdir -p "$BUILD_DIR"

    export PATH="/usr/local/go/bin:/usr/local/bin:$PATH"
    export GOPATH="/root/go"
    export GOBIN="/usr/local/bin"

    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

    cd "$BUILD_DIR"

    rm -f ./caddy

    /usr/local/bin/xcaddy build \
        --with "$MODULE"

    if [[ ! -s "$BUILD_DIR/caddy" ]]; then
        error "Caddy 编译失败"
        return 1
    fi

    chmod 755 "$BUILD_DIR/caddy"

    if ! "$BUILD_DIR/caddy" list-modules |
        grep -qx 'http.handlers.forward_proxy'; then
        error "编译结果缺少 forward_proxy 模块"
        return 1
    fi

    info "Caddy 编译及模块检查成功"
}

create_user() {
    if ! id caddy >/dev/null 2>&1; then
        useradd \
            --system \
            --home-dir "$DATA_DIR" \
            --shell /usr/sbin/nologin \
            caddy
    fi

    mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"

    chown -R caddy:caddy "$DATA_DIR" "$LOG_DIR"
    chown root:caddy "$CONFIG_DIR"

    chmod 750 "$CONFIG_DIR"
}

create_service() {
    info "创建 systemd 服务..."

    cat > "$SERVICE" <<'EOF'
[Unit]
Description=Caddy NaiveProxy Server
Documentation=https://github.com/klzgrad/naiveproxy
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy/.local/share
Environment=XDG_CONFIG_HOME=/var/lib/caddy/.config
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=/var/lib/caddy /var/log/caddy
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable caddy
}

generate_config() {
    local domain email username password mask

    echo
    info "开始配置 NaiveProxy"

    read -rp "请输入代理域名: " domain
    read -rp "请输入证书邮箱: " email

    read -rp "请输入伪装网站 [https://www.wikipedia.org]: " mask
    mask="${mask:-https://www.wikipedia.org}"

    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        error "域名格式错误"
        return 1
    fi

    if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        error "邮箱格式错误"
        return 1
    fi

    if [[ ! "$mask" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$ ]]; then
        error "伪装网站必须使用有效 HTTPS URL"
        return 1
    fi

    username="np$(openssl rand -hex 4)"
    password="$(openssl rand -hex 16)"

    cat > "$CONFIG" <<EOF
{
    order forward_proxy before file_server
}

:443, ${domain} {
    tls ${email}

    encode

    route {
        forward_proxy {
            basic_auth ${username} ${password}
            hide_ip
            hide_via
            probe_resistance
        }

        reverse_proxy ${mask} {
            header_up Host {upstream_hostport}
        }
    }
}
EOF

    chmod 640 "$CONFIG"
    chown root:caddy "$CONFIG"

    # 保存账户信息，限制仅 root 可读
    cat > /root/naiveproxy-info.txt <<EOF
NaiveProxy Information
======================

Domain: ${domain}
Port: 443
Username: ${username}
Password: ${password}
Mask Site: ${mask}

Client:
{
    "listen": "socks://127.0.0.1:1080",
    "proxy": "https://${username}:${password}@${domain}"
}
EOF

    chmod 600 /root/naiveproxy-info.txt

    echo
    info "代理配置已生成"
    info "账户信息: /root/naiveproxy-info.txt"
}

check_ports() {
    info "检查端口占用..."

    if ss -lntp | grep -E ':(80|443)[[:space:]]' ; then
        warn "发现 80 或 443 端口已有监听服务"
        warn "请确认是否会与 Caddy 冲突"
    else
        info "80/443 端口当前无监听服务"
    fi
}

install_proxy() {
    check_root
    check_os
    check_arch

    if [[ -f "$CONFIG" ]]; then
        error "检测到现有配置，请使用更新功能"
        return 1
    fi

    check_ports
    pause

    install_dependencies
    install_go
    build_caddy

    create_user

    install -m 755 "$BUILD_DIR/caddy" "$BIN"
    setcap cap_net_bind_service=+ep "$BIN"

    generate_config
    create_service

    info "验证 Caddy 配置..."

    if ! "$BIN" validate --config "$CONFIG"; then
        error "配置验证失败，请检查 Caddyfile"
        return 1
    fi

    info "启动 NaiveProxy..."

    systemctl restart caddy

    sleep 3

    if systemctl is-active --quiet caddy; then
        info "NaiveProxy 安装成功"
        show_status
        cat /root/naiveproxy-info.txt
    else
        error "服务启动失败"
        journalctl -u caddy -n 50 --no-pager
        return 1
    fi
}

update_proxy() {
    check_root
    check_os
    check_arch

    if [[ ! -f "$CONFIG" ]]; then
        error "未发现现有配置，请先安装"
        return 1
    fi

    install_dependencies
    install_go
    build_caddy

    local backup="${BIN}.backup"

    if [[ -f "$BIN" ]]; then
        cp -a "$BIN" "$backup"
    fi

    install -m 755 "$BUILD_DIR/caddy" "$BIN"
    setcap cap_net_bind_service=+ep "$BIN"

    if ! "$BIN" validate --config "$CONFIG"; then
        error "新版本配置验证失败，恢复旧版本"
        if [[ -f "$backup" ]]; then
            cp -a "$backup" "$BIN"
        fi
        return 1
    fi

    if systemctl restart caddy &&
       systemctl is-active --quiet caddy; then
        rm -f "$backup"
        info "NaiveProxy 更新成功"
    else
        error "更新后启动失败，尝试回滚"

        systemctl stop caddy || true

        if [[ -f "$backup" ]]; then
            cp -a "$backup" "$BIN"
            systemctl restart caddy || true
        fi

        return 1
    fi
}

show_status() {
    echo
    echo "========== NaiveProxy 状态 =========="

    if systemctl is-active --quiet caddy; then
        info "服务状态: RUNNING"
    else
        error "服务状态: STOPPED"
    fi

    echo
    echo "--- systemd ---"
    systemctl status caddy --no-pager -l || true

    echo
    echo "--- 端口监听 ---"
    ss -lntp | grep -E ':(80|443)[[:space:]]' || true

    echo
    echo "--- Caddy 版本 ---"

    if [[ -x "$BIN" ]]; then
        "$BIN" version

        echo
        echo "--- Naive 模块 ---"

        "$BIN" list-modules |
            grep 'forward_proxy' || true
    fi

    echo
    echo "--- TLS 证书 ---"

    if [[ -f "$CONFIG" ]]; then
        local domain
        domain=$(awk '/^:443,/ {
            gsub(",", "", $2)
            print $2
            exit
        }' "$CONFIG")

        if [[ -n "$domain" ]]; then
            timeout 8 openssl s_client \
                -connect "127.0.0.1:443" \
                -servername "$domain" </dev/null 2>/dev/null |
                openssl x509 -noout -subject -dates 2>/dev/null ||
                warn "暂时无法读取 TLS 证书"
        fi
    fi

    echo
    echo "--- 最近日志 ---"
    journalctl -u caddy -n 10 --no-pager || true

    echo "====================================="
}

uninstall_proxy() {
    check_root

    echo
    warn "此操作将删除 NaiveProxy、Caddy 配置及证书数据"
    read -rp "确认卸载？请输入 YES: " confirm

    if [[ "$confirm" != "YES" ]]; then
        info "已取消卸载"
        return
    fi

    local backup="/root/naiveproxy-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    if [[ -d "$CONFIG_DIR" ]]; then
        tar -czf "$backup" \
            "$CONFIG_DIR" \
            /root/naiveproxy-info.txt 2>/dev/null || true
    fi

    systemctl disable --now caddy 2>/dev/null || true

    rm -f "$SERVICE"
    rm -f "$BIN"
    rm -rf "$CONFIG_DIR"
    rm -rf "$DATA_DIR"
    rm -rf "$LOG_DIR"
    rm -f /root/naiveproxy-info.txt
    rm -rf "$BUILD_DIR"

    systemctl daemon-reload
    systemctl reset-failed

    info "NaiveProxy 已卸载"
    info "备份文件: $backup"
    warn "未删除 Go 和系统依赖"
}

show_menu() {
    clear 2>/dev/null || true

    echo "=================================="
    echo "       NaiveProxy Manager"
    echo "=================================="
    echo "  1. 安装 NaiveProxy"
    echo "  2. 更新 NaiveProxy"
    echo "  3. 卸载 NaiveProxy"
    echo "  4. 状态检测"
    echo "  5. 查看账户配置"
    echo "  0. 退出"
    echo "=================================="

    read -rp "请选择操作: " choice

    case "$choice" in
        1) install_proxy ;;
        2) update_proxy ;;
        3) uninstall_proxy ;;
        4) show_status ;;
        5)
            if [[ -f /root/naiveproxy-info.txt ]]; then
                cat /root/naiveproxy-info.txt
            else
                warn "未找到账户配置"
            fi
            ;;
        0) exit 0 ;;
        *) error "无效选项" ;;
    esac
}

main() {
    check_root
    show_menu
}

main "$@"
