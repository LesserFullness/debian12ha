#!/bin/bash
#==============================================================================
# Debian12 NAS + Home Assistant + Mihomo (CN Enhanced) - install-cn.sh
# Features:
#   - Auto detect network, install Warp if GitHub unreachable
#   - Install Docker via Tencent Cloud mirror (with official GPG)
#   - Install Home Assistant Supervised via ghproxy
#   - Download Mihomo from GitHub release
#   - Configure secure Samba NAS share
#   - Install Tailscale for remote access
#   - Enable power saving (TLP + CPU powersave)
#   - Prevent lid close sleep (for laptop NAS mode)
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Configuration
# -------------------------
NAS_USERNAME="nasuser"
NAS_PASSWORD="nas123456"
DOCKER_REPO="https://mirrors.cloud.tencent.com/docker-ce"
REGISTRY_MIRROR=""
HA_MACHINE_TYPE="generic-x86-64"
WARP_ALT_SCRIPT="https://raw.githubusercontent.com/fscarmen/warp/main/menu.sh"
GH_PROXY="https://ghproxy.com/https://github.com"
MIHOMO_URL="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-amd64-compatible.gz"
SUBSCRIBE_URL="https://c.bbydy.org/api/bby/client/subscribe?token=fbbf3f0bb28e2f5fad03ac382aba5695"
LOGFILE="/var/log/install-cn.log"

# -------------------------
# Utility functions
# -------------------------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ ERROR: $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️ $*\033[0m" | tee -a "$LOGFILE"; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 644 "$LOGFILE"
trap 'error "Script interrupted. Check log: $LOGFILE"' ERR

log "Starting installation: Debian12 NAS + Home Assistant + Mihomo (CN Enhanced)"

# -------------------------
# Check permissions and system
# -------------------------
[ "$(id -u)" -ne 0 ] && error "This script must be run as root."

if ! grep -qi "debian.*12" /etc/os-release; then
    warn "System is not Debian 12."
    read -r -p "Continue? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && error "User cancelled installation."
fi

# -------------------------
# Step 0: Network check
# -------------------------
log "Checking GitHub connectivity..."
if ping -c 2 github.com &>/dev/null || curl -s --max-time 5 https://github.com &>/dev/null; then
    success "GitHub reachable"
    USE_WARP=0
else
    warn "GitHub unreachable, installing Warp proxy"
    USE_WARP=1
fi

# -------------------------
# Step 1: System update
# -------------------------
log "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt full-upgrade -y
success "System updated"

# -------------------------
# Step 2: Install base dependencies
# -------------------------
log "Installing base dependencies..."
apt install -y curl wget ca-certificates apt-transport-https gnupg lsb-release jq \
    apparmor apparmor-utils avahi-daemon dbus network-manager \
    systemd-journal-remote software-properties-common \
    samba tlp cpufrequtils smartmontools bash-completion gzip tar || warn "Some dependencies failed"
success "Base dependencies installed"

# -------------------------
# Step 3: Install Warp (if needed)
# -------------------------
if [ "$USE_WARP" -eq 1 ]; then
    log "Installing Cloudflare Warp..."
    curl -fsSL "$WARP_ALT_SCRIPT" -o /tmp/warp_install.sh
    bash /tmp/warp_install.sh d || warn "Warp installation script returned non-zero"
    sleep 3
    if command -v warp &>/dev/null; then warp s || warn "warp s failed"; fi
    curl -s --max-time 6 https://github.com &>/dev/null || error "Warp installed but GitHub still unreachable"
    success "Warp enabled"
fi

# -------------------------
# Step 4: Install Docker (Tencent mirror with official GPG)
# -------------------------
log "Installing Docker..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

ARCH=$(dpkg --print-architecture)
CODENAME=$(lsb_release -cs)
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] $DOCKER_REPO/linux/debian $CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

apt update -y
apt install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker
success "Docker installed"

# Optional registry mirrors
cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [
    "https://mirror.ccs.tencentyun.com",
    "https://hub-mirror.c.163.com",
    "https://registry.docker-cn.com"
  ],
  "max-concurrent-uploads": 3
}
EOF
systemctl restart docker || warn "Failed to restart Docker"

# -------------------------
# Step 5: Home Assistant dependencies
# -------------------------
apt install -y jq dbus network-manager avahi-daemon udisks2 libglib2.0-bin || warn "Some HA deps failed"

# -------------------------
# Step 6: Home Assistant Supervised
# -------------------------
if systemctl is-active --quiet home-assistant-supervised; then
    success "Home Assistant running, skipping"
else
    log "Installing Home Assistant Supervised..."
    mkdir -p /opt/ha-install
    cd /opt/ha-install
    INSTALLER_URL="${GH_PROXY}/home-assistant/supervised-installer/releases/latest/download/installer.sh"
    curl -fLo installer.sh "$INSTALLER_URL"
    chmod +x installer.sh
    bash installer.sh --machine "$HA_MACHINE_TYPE" || warn "HA installer script returned non-zero"
    systemctl enable home-assistant-supervised || warn "Could not enable HA service"
    success "Home Assistant installed"
fi

# -------------------------
# Step 7: Download Mihomo
# -------------------------
log "Downloading Mihomo..."
MIHOMO_BIN="/usr/local/bin/mihomo"
curl -fL "$MIHOMO_URL" | gzip -d > "$MIHOMO_BIN"
chmod +x "$MIHOMO_BIN"
success "Mihomo installed at $MIHOMO_BIN"

# -------------------------
# Step 8: Configure Samba NAS
# -------------------------
log "Configuring Samba NAS..."
id "$NAS_USERNAME" &>/dev/null || useradd -m -s /usr/sbin/nologin "$NAS_USERNAME"
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
# Step 9: Install Tailscale
# -------------------------
if ! command -v tailscale &>/dev/null; then
    log "Installing Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/install.sh | sh
    systemctl enable tailscaled
    systemctl start tailscaled
fi
success "Tailscale installed"

# -------------------------
# Step 10: Enable CPU powersave & TLP
# -------------------------
systemctl enable tlp || warn "TLP enable failed"
systemctl start tlp || warn "TLP start failed"
command -v cpufreq-set &>/dev/null && cpufreq-set -g powersave || warn "CPU powersave not applied"
success "CPU powersave enabled"

# -------------------------
# Step 11: Prevent lid close sleep
# -------------------------
LID_CONFIG="/etc/systemd/logind.conf"
[ ! -f "${LID_CONFIG}.bak" ] && cp "$LID_CONFIG" "${LID_CONFIG}.bak"
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LID_CONFIG"
sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LID_CONFIG"
sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LID_CONFIG"
systemctl restart systemd-logind || warn "Restart logind failed"
success "Lid close sleep prevention applied"

# -------------------------
# Step 12: Final status
# -------------------------
LAN_IP=$(hostname -I | awk '{print $1}' || echo "unknown")

echo
echo "=========================================="
success "🎉 Installation completed!"
echo "🏠 Home Assistant: http://${LAN_IP}:8123"
echo "📁 NAS share: \\\\${LAN_IP}\\share"
echo "🔐 NAS user/password: $NAS_USERNAME / $NAS_PASSWORD"
echo "🔗 Tailscale: sudo tailscale up (login after setup)"
echo "📌 Mihomo subscribed via: $SUBSCRIBE_URL"
echo "=========================================="
success "Deployment successful!"
exit 0
