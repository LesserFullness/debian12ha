#!/bin/bash
# =============================================================================
# Debian12 NAS + Home Assistant + Mihomo (CN Enhanced)
# 自动安装脚本（中国大陆网络增强版）
# 功能：
#   - Warp 代理 fallback
#   - 国内 Docker 镜像 + GPG key 修复
#   - Home Assistant Supervised
#   - Mihomo
#   - Samba NAS
#   - Tailscale
#   - 节能优化
# 作者：YourName
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# 配置参数
# -------------------------
NAS_USERNAME="nasuser"
NAS_PASSWORD="nas123456"
HA_MACHINE_TYPE="generic-x86-64"
Mihomo_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-amd64-compatible.gz"
SUBSCRIBE_URL="https://c.bbydy.org/api/bby/client/subscribe?token=fbbf3f0bb28e2f5fad03ac382aba5695"

LOGFILE="/var/log/install-cn.log"

DOCKER_MIRRORS=(
    "https://mirrors.aliyun.com/docker-ce/linux/debian"
    "https://mirrors.cloud.tencent.com/docker-ce/linux/debian"
    "https://hub-mirror.c.163.com/docker-ce/linux/debian"
)

# -------------------------
# 日志函数
# -------------------------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️ $*\033[0m" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 644 "$LOGFILE"

trap 'error "脚本中断，请查看日志: $LOGFILE"' ERR

log "开始安装 Debian12 NAS + Home Assistant + Mihomo (CN增强版)"

# -------------------------
# 系统检查
# -------------------------
if [ "$(id -u)" -ne 0 ]; then error "请以 root 执行"; fi
if ! grep -qi "debian.*12" /etc/os-release; then
    warn "系统不是 Debian 12，可能存在兼容性问题"
    read -r -p "是否继续？[y/N] " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && error "用户取消"
fi

# -------------------------
# Step 0: 检测 GitHub
# -------------------------
log "检测 GitHub 连通性..."
if ping -c 2 github.com >/dev/null 2>&1 || curl -s --max-time 5 https://github.com >/dev/null 2>&1; then
    success "GitHub 可访问"
    USE_WARP=0
else
    warn "GitHub 不可访问，将使用 Warp"
    USE_WARP=1
fi

# -------------------------
# Step 1: 系统更新
# -------------------------
log "更新系统..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt full-upgrade -y
success "系统更新完成"

# -------------------------
# Step 2: 安装基础依赖
# -------------------------
log "安装基础依赖..."
apt install -y curl wget ca-certificates gnupg lsb-release jq apparmor \
    apparmor-utils avahi-daemon dbus network-manager systemd-journal-remote \
    software-properties-common samba tlp cpufrequtils smartmontools bash-completion
success "基础依赖安装完成"

# -------------------------
# Step 3: Warp 安装（如需要）
# -------------------------
if [ "$USE_WARP" -eq 1 ]; then
    log "安装 Cloudflare Warp..."
    if curl -fsSL https://git.io/warp.sh | bash -s -- -y; then
        warp s || warn "warp 启动失败"
    fi
    if curl -s --max-time 6 https://github.com >/dev/null 2>&1; then
        success "Warp 启用，GitHub 可访问"
    else
        error "Warp 安装后 GitHub 仍不可访问"
    fi
else
    log "跳过 Warp 安装"
fi

# -------------------------
# Step 4: 安装 Docker（国内镜像 + key 自动修复）
# -------------------------
log "安装 Docker..."
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)

for MIRROR in "${DOCKER_MIRRORS[@]}"; do
    log "尝试镜像: $MIRROR"
    if curl -sSf "$MIRROR/gpg" -o /etc/apt/keyrings/docker.gpg; then
        echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $MIRROR $CODENAME stable" \
            > /etc/apt/sources.list.d/docker.list
        if apt update -y; then
            success "镜像可用: $MIRROR"
            break
        fi
    fi
done

# 如果仍然不可用，使用官方源
if ! apt update -y; then
    warn "国内镜像不可用，使用官方源 + Warp"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list
    apt update -y
fi

apt install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
success "Docker 安装完成"

# -------------------------
# Step 5: Home Assistant Supervised
# -------------------------
log "安装 Home Assistant Supervised..."
mkdir -p /opt/ha-install
cd /opt/ha-install
curl -fsSL https://ghproxy.com/https://github.com/home-assistant/supervised-installer/releases/latest/download/installer.sh -o installer.sh
chmod +x installer.sh
bash installer.sh --machine "$HA_MACHINE_TYPE"
systemctl enable home-assistant-supervised
success "Home Assistant 安装完成"

# -------------------------
# Step 6: Mihomo 下载
# -------------------------
log "下载 Mihomo..."
mkdir -p /opt/mihomo
curl -fLo /opt/mihomo/mihomo.gz "$Mihomo_URL" || warn "Mihomo 下载失败"
gunzip -f /opt/mihomo/mihomo.gz
chmod +x /opt/mihomo/mihomo
success "Mihomo 安装完成"

# -------------------------
# Step 7: 配置 Samba NAS
# -------------------------
log "配置 Samba NAS..."
if id "$NAS_USERNAME" >/dev/null 2>&1; then
    warn "用户 $NAS_USERNAME 已存在，更新密码"
    echo "${NAS_USERNAME}:${NAS_PASSWORD}" | chpasswd
else
    useradd -m -s /usr/sbin/nologin "$NAS_USERNAME"
    echo "${NAS_USERNAME}:${NAS_PASSWORD}" | chpasswd
    success "创建 NAS 用户: $NAS_USERNAME"
fi

mkdir -p /mnt/storage
chown -R "$NAS_USERNAME:$NAS_USERNAME" /mnt/storage
chmod 755 /mnt/storage

cat >/etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = HomeNAS
   map to guest = Bad User
   smb encrypt = auto
   log file = /var/log/samba/log.%m
   max log size = 1000
[share]
   comment = Home Assistant NAS Share
   path = /mnt/storage
   browseable = yes
   read only = no
   valid users = $NAS_USERNAME
   guest ok = no
   create mask = 0644
   directory mask = 0755
EOF

( echo "$NAS_PASSWORD"; echo "$NAS_PASSWORD" ) | smbpasswd -s -a "$NAS_USERNAME"
systemctl enable smbd
systemctl restart smbd
success "Samba 配置完成"

# -------------------------
# Step 8: 安装 Tailscale
# -------------------------
if ! command -v tailscale >/dev/null; then
    log "安装 Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/install.sh | sh
    systemctl enable tailscaled
    systemctl start tailscaled
    success "Tailscale 安装完成"
else
    success "Tailscale 已安装"
fi

# -------------------------
# Step 9: 节能优化
# -------------------------
log "启用节能模式..."
systemctl enable tlp || warn "无法启用 TLP"
systemctl start tlp || warn "无法启动 TLP"
command -v cpufreq-set >/dev/null && cpufreq-set -g powersave && success "CPU 设置为 powersave"

# -------------------------
# Step 10: 防止笔记本盖上睡眠
# -------------------------
log "配置 lid close ignore..."
LID_CONF="/etc/systemd/logind.conf"
cp "$LID_CONF" "${LID_CONF}.bak" || true
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LID_CONF"
systemctl restart systemd-logind || warn "logind restart 失败"

# -------------------------
# 完成提示
# -------------------------
