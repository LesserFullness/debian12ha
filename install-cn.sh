#!/usr/bin/env bash
# ============================================================
# install-clash.sh - 修正版（自动获取最新 Mihomo release + Warp fallback）
# 适用于 Debian/Ubuntu/Armbian x86_64 / ARM / RISC-V
# ============================================================

set -euo pipefail

# === 配置区 ===
APP_NAME="mihomo"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/mihomo.service"
SUBSCRIBE_URL="https://c.bbydy.org/api/bby/client/subscribe?token=fbbf3f0bb28e2f5fad03ac382aba5695"
CONFIG_DIR="/etc/mihomo"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# === 自动检测架构 ===
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_NAME="amd64" ;;
    aarch64) ARCH_NAME="arm64" ;;
    armv7l) ARCH_NAME="armv7" ;;
    riscv64) ARCH_NAME="riscv64" ;;
    *) echo "❌ 不支持的架构: $ARCH" && exit 1 ;;
esac
echo "✅ 检测到架构: $ARCH_NAME"

# === 检测可用镜像 ===
echo "🌐 检测可用 GitHub 镜像..."
MIRRORS=(
    "https://github.com"
    "https://mirror.ghproxy.com/https://github.com"
    "https://hub.fastgit.xyz"
)
GH_MIRROR=""
for mirror in "${MIRRORS[@]}"; do
    if curl -fsSL --max-time 5 "$mirror/MetaCubeX/mihomo" >/dev/null 2>&1; then
        GH_MIRROR="$mirror"
        echo "✅ 使用镜像: $GH_MIRROR"
        break
    fi
done
if [ -z "$GH_MIRROR" ]; then
    echo "⚠️ 所有镜像不可用，尝试使用 Warp 代理..."
    if ! command -v warp-cli >/dev/null 2>&1; then
        apt update && apt install -y cloudflare-warp
        warp-cli register || true
        warp-cli connect || true
    fi
    GH_MIRROR="https://github.com"
fi

# === 获取最新 Mihomo release 文件名 ===
echo "🔍 获取最新 release 文件名..."
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
RELEASE_FILE=$(curl -s "$API_URL" | grep -oP "mihomo-linux-$ARCH_NAME.*?\\.gz" | head -1)

if [ -z "$RELEASE_FILE" ]; then
    echo "❌ 无法获取最新 release 文件名，请检查网络或仓库是否有发布"
    exit 1
fi
DOWNLOAD_URL="$GH_MIRROR/MetaCubeX/mihomo/releases/latest/download/$RELEASE_FILE"
echo "⬇️ 下载 Mihomo: $DOWNLOAD_URL"

# === 下载与安装 ===
mkdir -p "$INSTALL_DIR"
curl -fsSL --retry 5 -o "$INSTALL_DIR/mihomo.gz" "$DOWNLOAD_URL"
gzip -df "$INSTALL_DIR/mihomo.gz"
chmod +x "$INSTALL_DIR/mihomo"
echo "✅ Mihomo 已安装到 $INSTALL_DIR/mihomo"

# === 创建配置目录 ===
mkdir -p "$CONFIG_DIR"
cd "$CONFIG_DIR"

# === 下载订阅配置 ===
echo "🌍 下载订阅配置..."
curl -fsSL --retry 3 -o "$CONFIG_FILE" "$SUBSCRIBE_URL"
if [ ! -s "$CONFIG_FILE" ]; then
    echo "⚠️ 订阅下载失败，尝试使用 Warp..."
    warp-cli connect || true
    curl -fsSL --retry 3 -o "$CONFIG_FILE" "$SUBSCRIBE_URL" || echo "❌ 无法获取订阅，请稍后重试。"
fi
echo "✅ 配置文件已保存到 $CONFIG_FILE"

# === 创建 systemd 服务 ===
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo Proxy Service
After=network.target

[Service]
ExecStart=$INSTALL_DIR/mihomo -d $CONFIG_DIR
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# === 启动服务 ===
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable mihomo
systemctl restart mihomo

echo "✅ 安装完成！"
echo "📁 配置文件: $CONFIG_FILE"
echo "🚀 服务状态: systemctl status mihomo"
echo "🧠 更新订阅: curl -fsSL '$SUBSCRIBE_URL' -o '$CONFIG_FILE' && systemctl restart mihomo"
