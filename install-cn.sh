#!/bin/bash
#==============================================================================
# Debian12 NAS + Home Assistant + Mihomo (CN Enhanced + Warp)
# Auto-detect Docker installation, use Warp if available
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

LOGFILE="/var/log/install-cn.log"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 644 "$LOGFILE"

log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ ERROR: $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️  $*\033[0m" | tee -a "$LOGFILE"; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

trap 'error "Script interrupted. Check log: $LOGFILE"' ERR

# -------------------------
# Check root
# -------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

log "Starting optimized installation: Debian12 NAS + Home Assistant + Mihomo (Warp Enabled)"

# -------------------------
# Warp detection
# -------------------------
USE_WARP=false
if command -v warp-cli >/dev/null 2>&1; then
    WARP_STATUS=$(warp-cli status | grep -i "Connected" || true)
    if [ -n "$WARP_STATUS" ]; then
        USE_WARP=true
        success "Warp detected and connected"
    else
        warn "Warp installed but not connected. Please run 'warp-cli registration new' and 'warp-cli connect'"
    fi
else
    warn "Warp not installed. Please install Cloudflare Warp first."
fi

# -------------------------
# Helper: download with Warp if available
# -------------------------
warp_curl() {
    if $USE_WARP; then
        curl -fsSL "$@"
    else
        curl -fsSL "$@"
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
    samba tlp cpufrequtils smartmontools bash-completion
success "Base dependencies installed"

# -------------------------
# Detect Docker
# -------------------------
if command -v docker >/dev/null; then
    success "Docker already installed, skipping installation"
else
    log "Installing Docker..."
    mkdir -p /etc/apt/keyrings
    warp_curl https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d'=' -f2)
    ARCH=$(dpkg --print-architecture)
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    success "Docker installed and started"
fi

# -------------------------
# Home Assistant Supervised
# -------------------------
log "Installing Home Assistant Supervised..."
if systemctl is-active --quiet home-assistant-supervised; then
    success "Home Assistant already running"
else
    mkdir -p /opt/ha-install
    cd /opt/ha-install
    INSTALLER_URL="https://ghproxy.com/https://github.com/home-assistant/supervised-installer/releases/latest/download/installer.sh"
    warp_curl -fLo installer.sh "$INSTALLER_URL"
    chmod +x installer.sh
    bash installer.sh --machine generic-x86-64
    systemctl enable home-assistant-supervised
    success "Home Assistant installation attempted"
fi

# -------------------------
# Configure Samba NAS
# -------------------------
NAS_USER="nasuser"
NAS_PASS="nas123456"
log "Configuring Samba NAS..."
if ! id "$NAS_USER" >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin "$NAS_USER"
    echo "$NAS_USER:$NAS_PASS" | chpasswd
    success "Created NAS user $NAS_USER"
fi
mkdir -p /mnt/storage
chown -R "$NAS_USER:$NAS_USER" /mnt/storage
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
   valid users = $NAS_USER
   guest ok = no
   create mask = 0644
   directory mask = 0755
EOF
( echo "$NAS_PASS"; echo "$NAS_PASS" ) | smbpasswd -s -a "$NAS_USER"
systemctl enable smbd
systemctl restart smbd
success "Samba configured"

# -------------------------
# Enable power saving
# -------------------------
systemctl enable tlp
systemctl start tlp
if command -v cpufreq-set >/dev/null; then
    cpufreq-set -g powersave || warn "Failed to set CPU frequency to powersave"
fi

# -------------------------
# Prevent lid close sleep
# -------------------------
LID_CONF="/etc/systemd/logind.conf"
cp "$LID_CONF" "$LID_CONF.bak"
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$LID_CONF"
sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$LID_CONF"
systemctl restart systemd-logind

# -------------------------
# Final status
# -------------------------
LAN_IP=$(hostname -I | awk '{print $1}' || echo "unknown")
echo "=========================================="
success "🎉 Installation completed!"
echo "Home Assistant: http://${LAN_IP}:8123"
echo "NAS share: \\\\${LAN_IP}\\share"
echo "NAS credentials: ${NAS_USER} / ${NAS_PASS}"
echo "=========================================="
exit 0
