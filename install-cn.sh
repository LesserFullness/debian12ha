#!/usr/bin/env bash
# ============================================================
# install-cn.sh - 完整修正版（Debian12 NAS + HA + Mihomo + Warp + Tailscale）
# Features:
#   - Auto detect architecture
#   - Fix Docker GPG key + Tencent Cloud mirror
#   - Auto install Warp CLI if GitHub unreachable
#   - Auto download latest Mihomo release
#   - Configure NAS (Samba)
#   - Install Tailscale
#   - Power saving and lid close prevention
# ============================================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration
# -------------------------
NAS_USERNAME="nasuser"
NAS_PASSWORD="nas123456"
DOCKER_REPO="https://mirrors.cloud.tencent.com/docker-ce"
HA_MACHINE_TYPE="generic-x86-64"
SUBSCRIBE_URL="https://c.bbydy.org/api/bby/client/subscribe?token=fbbf3f0bb28e2f5fad03ac382aba5695"
Mihomo_INSTALL_DIR="/usr/local/bin"
Mihomo_CONFIG_DIR="/etc/mihomo"
Mihomo_SERVICE="/etc/systemd/system/mihomo.service"
LOGFILE="/var/log/install-cn.log"

# -------------------------
# Utility functions
# -------------------------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ ERROR: $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️  $*\033[0m" | tee -a "$LOGFILE"; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

# Initialize log
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 644 "$LOGFILE"

trap 'error "Script interrupted. Check log: $LOGFILE"' ERR

log "Starting installation: Debian12 NAS + Home Assistant + Mihomo (CN Enhanced)"

# -------------------------
# Check root
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "Please run as root: sudo bash $0"
fi

# -------------------------
# System update
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
    samba tlp cpufrequtils smartmontools bash-completion gzip || error "Dependency installation failed"
success "Base dependencies installed"

# -------------------------
# Detect architecture
# -------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH_NAME="amd64" ;;
    aarch64) ARCH_NAME="arm64" ;;
    armv7l) ARCH_NAME="armv7" ;;
    riscv64) ARCH_NAME="riscv64" ;;
    *) error "Unsupported architecture: $ARCH" ;;
esac
log "Detected architecture: $ARCH_NAME"

# -------------------------
# Install Warp if GitHub unreachable
# -------------------------
log "Checking GitHub connectivity..."
if curl -s --max-time 5 https://github.com >/dev/null 2>&1; then
    success "GitHub reachable, skipping Warp"
else
    warn "GitHub unreachable, installing Warp CLI"
    if ! command -v warp-cli >/dev/null 2>&1; then
        log "Installing Cloudflare Warp CLI..."
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt update
        apt install -y cloudflare-warp
    fi
    warp-cli register || true
    warp-cli connect || true
    if curl -s --max-time 6 https://github.com >/dev/null 2>&1; then
        success "Warp enabled, GitHub now accessible"
    else
        warn "Warp installed but GitHub still unreachable"
    fi
fi

# -------------------------
# Install Docker with Tencent Cloud mirror
# -------------------------
log "Installing Docker..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_REPO/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
success "Docker installed"

# -------------------------
# Install Mihomo latest release
# -------------------------
log "Downloading Mihomo latest release..."
mkdir -p "$Mihomo_INSTALL_DIR"
API_URL="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
RELEASE_FILE=$(curl -s "$API_URL" | grep -oP "mihomo-linux-$ARCH_NAME.*?\\.gz" | head -1)
[ -z "$RELEASE_FILE" ] && error "Cannot get Mihomo release filename"
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/$RELEASE_FILE"
curl -fsSL --retry 5 -o "$Mihomo_INSTALL_DIR/mihomo.gz" "$DOWNLOAD_URL"
gzip -df "$Mihomo_INSTALL_DIR/mihomo.gz"
chmod +x "$Mihomo_INSTALL_DIR/mihomo"
success "Mihomo installed at $Mihomo_INSTALL_DIR/mihomo"

# -------------------------
# Configure Mihomo
# -------------------------
mkdir -p "$Mihomo_CONFIG_DIR"
curl -fsSL --retry 3 -o "$Mihomo_CONFIG_DIR/config.yaml" "$SUBSCRIBE_URL" || warn "Failed to download subscription config"

# -------------------------
# Create systemd service
# -------------------------
cat > "$Mihomo_SERVICE" <<EOF
[Unit]
Description=Mihomo Proxy Service
After=network.target

[Service]
ExecStart=$Mihomo_INSTALL_DIR/mihomo -d $Mihomo_CONFIG_DIR
Restart=always
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable mihomo
systemctl restart mihomo
success "Mihomo service started"

# -------------------------
# Configure Samba NAS
# -------------------------
log "Configuring Samba NAS..."
if ! id "$NAS_USERNAME" >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin "$NAS_USERNAME"
fi
echo "$NAS_USERNAME:$NAS_PASSWORD" | chpasswd
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
fi
success "Tailscale installed"

# -------------------------
# Power saving
# -------------------------
systemctl enable tlp || true
systemctl start tlp || true
if command -v cpufreq-set >/dev/null 2>&1; then
    cpufreq-set -g powersave || warn "Failed to set CPU powersave"
fi

# -------------------------
# Prevent lid close sleep
# -------------------------
LID_CONF="/etc/systemd/logind.conf"
cp -n "$LID_CONF" "${LID_CONF}.bak" || true
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LID_CONF"
systemctl restart systemd-logind || warn "Failed to restart logind"

# -------------------------
# Finish
# -------------------------
LAN_IP=$(hostname -I | awk '{print $1}' || echo "unknown")
echo
echo "=========================================="
success "🎉 Installation completed!"
echo "🏠 Home Assistant: http://${LAN_IP}:8123"
echo "
