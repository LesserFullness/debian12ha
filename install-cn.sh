#!/bin/bash
#==============================================================================#
# Debian12 NAS + Home Assistant + Mihomo (CN Enhanced)
# Features:
#   - Detect network & WARP connection
#   - Download dependencies via WARP if available
#   - Install Docker (official)
#   - Install Home Assistant Supervised
#   - Configure Samba NAS
#   - Install Tailscale
#   - Power saving (TLP + CPU powersave)
#==============================================================================#

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration
# -------------------------
NAS_USERNAME="nasuser"
NAS_PASSWORD="nas123456"
HA_MACHINE_TYPE="generic-x86-64"
LOGFILE="/var/log/install-cn.log"

# Mihomo / Clash or other dependencies download links
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-amd64-compatible.gz"

# -------------------------
# Logging functions
# -------------------------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ ERROR: $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️ $*\033[0m" | tee -a "$LOGFILE"; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

# Initialize log
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 644 "$LOGFILE"
trap 'error "Script interrupted. Check log: $LOGFILE"' ERR

# -------------------------
# Ensure root
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "Please run as root"
fi

# -------------------------
# System check
# -------------------------
if ! grep -qi "debian.*12" /etc/os-release; then
    warn "System is not Debian 12. Continue at your own risk."
    read -r -p "Continue? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && error "User cancelled"
fi

log "Starting installation: Debian12 NAS + Home Assistant + Mihomo"

# -------------------------
# Check WARP
# -------------------------
USE_WARP=0
if command -v warp-cli >/dev/null 2>&1; then
    WARP_STATUS=$(warp-cli status 2>/dev/null | grep -i "Status update" | awk '{print $3}' || echo "Disconnected")
    if [[ "$WARP_STATUS" == "Connected" ]]; then
        log "WARP 已连接，可用于下载被墙资源"
        USE_WARP=1
    else
        warn "WARP 未连接，下载墙外资源可能失败"
    fi
else
    warn "未安装 WARP CLI，可选安装 https://pkg.cloudflareclient.com/"
fi

# -------------------------
# Helper download function
# -------------------------
download_with_warp() {
    local URL="$1"
    local OUTPUT="$2"
    if [[ "$USE_WARP" -eq 1 ]]; then
        curl -L --retry 5 --connect-timeout 10 "$URL" -o "$OUTPUT" || error "下载失败: $URL"
    else
        curl -L --retry 5 --connect-timeout 10 "$URL" -o "$OUTPUT" || warn "下载失败（未使用 WARP）: $URL"
    fi
}

# -------------------------
# Update system
# -------------------------
log "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt full-upgrade -y
success "System updated"

# -------------------------
# Install base dependencies
# -------------------------
log "Installing base dependencies..."
apt install -y curl wget ca-certificates apt-transport-https gnupg lsb-release \
    jq apparmor apparmor-utils avahi-daemon dbus network-manager \
    systemd-journal-remote software-properties-common \
    samba tlp cpufrequtils smartmontools bash-completion || error "Dependencies failed"
success "Base dependencies installed"

# -------------------------
# Install Docker
# -------------------------
log "Installing Docker..."
mkdir -p /etc/apt/keyrings
download_with_warp "https://download.docker.com/linux/debian/gpg" /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io || error "Docker installation failed"
systemctl enable docker
systemctl start docker
success "Docker installed"

# -------------------------
# Install Home Assistant Supervised
# -------------------------
log "Installing Home Assistant Supervised..."
mkdir -p /opt/ha-install
cd /opt/ha-install
download_with_warp "https://ghproxy.com/https://github.com/home-assistant/supervised-installer/releases/latest/download/installer.sh" installer.sh
chmod +x installer.sh
bash installer.sh --machine "$HA_MACHINE_TYPE" || warn "HA installer returned non-zero"
success "HA installation attempted"

# -------------------------
# Download Mihomo
# -------------------------
log "Downloading Mihomo..."
mkdir -p /opt/mihomo
download_with_warp "$MIHOMO_URL" /opt/mihomo/mihomo.gz
gzip -d /opt/mihomo/mihomo.gz
chmod +x /opt/mihomo/mihomo
success "Mihomo downloaded"

# -------------------------
# Configure Samba NAS
# -------------------------
log "Configuring Samba NAS..."
if id "$NAS_USERNAME" >/dev/null 2>&1; then
    warn "User $NAS_USERNAME exists, updating password"
    echo "${NAS_USERNAME}:${NAS_PASSWORD}" | chpasswd
else
    useradd -m -s /usr/sbin/nologin "$NAS_USERNAME"
    echo "${NAS_USERNAME}:${NAS_PASSWORD}" | chpasswd
    success "Created NAS user"
fi

mkdir -p /mnt/storage
chown -R "$NAS_USERNAME:$NAS_USERNAME" /mnt/storage
chmod 755 /mnt/storage

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = HomeNAS
   map to guest = Bad User
   smb encrypt = auto
   log file = /var/log/samba/log.%m
   max log size = 1000
   server role = standalone server

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
success "Samba configured"

# -------------------------
# Install Tailscale
# -------------------------
if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/install.sh | sh
    systemctl enable tailscaled
    systemctl start tailscaled
    success "Tailscale installed"
else
    success "Tailscale already installed"
fi

# -------------------------
# Power saving
# -------------------------
systemctl enable tlp
systemctl start tlp
if command -v cpufreq-set >/dev/null; then
    cpufreq-set -g powersave || warn "Failed to set CPU to powersave"
fi
success "Power saving enabled"

# -------------------------
# Final status
# -------------------------
LAN_IP=$(hostname -I | awk '{print $1}' || echo "unknown")
echo
echo "=========================================="
success "🎉 Installation completed!"
echo "Home Assistant: http://${LAN_IP}:8123"
echo "NAS share path: \\\\${LAN_IP}\\share"
echo "NAS username/password: ${NAS_USERNAME} / ${NAS_PASSWORD}"
echo "Tailscale: sudo tailscale up"
echo "Logs: /var/log/install-cn.log"
echo "=========================================="
exit 0
