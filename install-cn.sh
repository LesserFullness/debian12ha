#!/bin/bash
set -euo pipefail

# ==========================================================
# Clash.Meta CN 增强一键安装脚本（带自动代理检测 + Warp fallback）
# 适用：Debian 12/13 x86_64
# 作者：LesserFullness + GPT-5 助理
# 功能：
#   1. 自动检测 GitHub 访问
#   2. 自动安装 Warp（若被墙）
#   3. 自动下载 Clash.Meta（多镜像源）
#   4. 自动安装 Dashboard（yacd）
#   5. 设置 Systemd + 开机自启
#   6. 自动配置系统全局代理
# ==========================================================

# ---------- 基本配置 ----------
CLASH_DIR="/opt/clash"
CLASH_BIN="/usr/local/bin/clash-meta"
DASHBOARD_DIR="${CLASH_DIR}/dashboard"
SERVICE_FILE="/etc/systemd/system/clash-meta.service"
CONFIG_FILE="${CLASH_DIR}/config.yaml"
SUBSCRIBE_URL="https://c.bbydy.org/api/bby/client/subscribe?token=fbbf3f0bb28e2f5fad03ac382aba5695"   # ← 请替换为你自己的订阅地址
PROXY_PORT=7890
HTTP_PORT=7891

# ---------- 输出格式 ----------
log() { echo -e "\033[36m[$(date +'%H:%M:%S')] $1\033[0m"; }
ok() { echo -e "\033[32m✅ $1\033[0m"; }
warn() { echo -e "\033[33m⚠️  $1\033[0m"; }
err() { echo -e "\033[31m❌ $1\033[0m" >&2; exit 1; }

# ---------- 检查 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 身份运行：sudo bash $0"
fi

log "🚀 开始安装 Clash.Meta CN 增强版"

# ---------- 安装依赖 ----------
log "安装依赖..."
apt update -y
apt install -y curl wget unzip tar jq ca-certificates systemd

# ---------- 检测 GitHub 连接 ----------
log "检测 GitHub 连通性..."
if curl -fs --connect-timeout 5 https://github.com > /dev/null 2>&1; then
    ok "GitHub 可访问"
    USE_WARP=0
else
    warn "GitHub 无法访问，将尝试安装 Cloudflare Warp"
    USE_WARP=1
fi

# ---------- 安装 Warp（如需要） ----------
if [ "$USE_WARP" -eq 1 ]; then
    log "安装 Cloudflare Warp..."
    if ! command -v warp &>/dev/null; then
        apt install -y curl
        bash <(curl -fsSL https://git.io/warp.sh) install
    fi
    warp s || err "Warp 启动失败"
    sleep 5

    log "重新检测 GitHub..."
    if curl -fs --connect-timeout 5 https://github.com > /dev/null 2>&1; then
        ok "Warp 已生效，GitHub 可访问"
    else
        err "Warp 启动后仍无法访问 GitHub，请检查网络"
    fi
fi

# ---------- 创建目录 ----------
mkdir -p "$CLASH_DIR"
cd "$CLASH_DIR"

# ---------- 自动镜像检测 ----------
log "检测可用镜像源..."
MIRRORS=(
  "https://mirror.ghproxy.com/"
  "https://gh-proxy.com/"
  ""
)

DOWNLOAD_OK=0
for MIRROR in "${MIRRORS[@]}"; do
    log "尝试镜像：${MIRROR:-官方源}"
    if curl -fsSL --connect-timeout 10 "${MIRROR}https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-amd64-compatible.gz" -o mihomo.gz; then
        DOWNLOAD_OK=1
        ok "成功使用镜像：${MIRROR:-官方源}"
        break
    else
        warn "镜像 ${MIRROR:-官方源} 失败"
    fi
done

if [ "$DOWNLOAD_OK" -ne 1 ]; then
    err "所有镜像均无法访问，请检查网络或手动配置代理"
fi

# ---------- 解压安装 ----------
log "安装 Clash.Meta 二进制..."
gzip -d mihomo.gz
mv mihomo "$CLASH_BIN"
chmod +x "$CLASH_BIN"
ok "Clash.Meta 安装完成"

# ---------- 下载 Dashboard ----------
log "安装 Dashboard（yacd）..."
rm -rf "$DASHBOARD_DIR"
mkdir -p "$DASHBOARD_DIR"
if ! curl -fsSL --connect-timeout 10 https://gh-proxy.com/https://github.com/haishanh/yacd/archive/refs/heads/gh-pages.zip -o dashboard.zip; then
    warn "主镜像失败，使用备用镜像..."
    curl -fsSL https://mirror.ghproxy.com/https://github.com/haishanh/yacd/archive/refs/heads/gh-pages.zip -o dashboard.zip || err "Dashboard 下载失败"
fi
unzip -q dashboard.zip -d "$DASHBOARD_DIR"
rm -f dashboard.zip
ok "Dashboard 安装完成"

# ---------- 生成基础配置 ----------
log "生成 Clash.Meta 基础配置..."
cat > "$CONFIG_FILE" <<EOF
mixed-port: ${PROXY_PORT}
allow-lan: true
bind-address: '*'
mode: Rule
log-level: info
external-controller: 0.0.0.0:${HTTP_PORT}
external-ui: ${DASHBOARD_DIR}/yacd-gh-pages

proxy-providers:
  mysub:
    type: http
    url: ${SUBSCRIBE_URL}
    interval: 3600
    path: ./subs/mysub.yaml
    health-check:
      enable: true
      interval: 600
      lazy: true

rules:
  - MATCH,Proxy
EOF
ok "配置文件生成完成：$CONFIG_FILE"

# ---------- 创建 Systemd 服务 ----------
log "创建 Systemd 服务..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Clash.Meta Proxy Service
After=network.target

[Service]
ExecStart=${CLASH_BIN} -d ${CLASH_DIR}
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable clash-meta
systemctl restart clash-meta
ok "Systemd 服务启动完成"

# ---------- 配置系统代理 ----------
log "配置全局系统代理..."
ENV_FILE="/etc/profile.d/clash-proxy.sh"
cat > "$ENV_FILE" <<EOF
export http_proxy="http://127.0.0.1:${PROXY_PORT}"
export https_proxy="http://127.0.0.1:${PROXY_PORT}"
export all_proxy="socks5://127.0.0.1:${PROXY_PORT}"
EOF
source "$ENV_FILE"
ok "系统代理已启用"

# ---------- 最终输出 ----------
echo
echo "=========================================="
echo "🎉 Clash.Meta 安装完成！"
echo "=========================================="
echo "📍 配置文件：$CONFIG_FILE"
echo "🧩 Dashboard 地址：http://$(hostname -I | awk '{print $1}'):${HTTP_PORT}"
echo "🌐 代理端口：HTTP/SOCKS5 = ${PROXY_PORT}"
echo "🔄 订阅地址：${SUBSCRIBE_URL}"
echo "⚙️  开机启动：systemctl enable clash-meta"
echo "🧰  启停命令：systemctl restart clash-meta"
echo "=========================================="
ok "Clash.Meta 已部署成功 ✅"
