#!/bin/bash
#==============================================================================
# Debian12 NAS + Home Assistant (CN Enhanced) - install-cn.sh
# Features:
#   - Auto detect network, install Warp if GitHub unreachable
#   - Install Docker via Tencent Cloud mirror (auto fallback to USTC)
#   - Install Home Assistant Supervised via ghproxy
#   - Configure secure Samba NAS share
#   - Install Tailscale for remote access
#   - Enable power saving (TLP + CPU powersave)
#   - Prevent lid close sleep (for laptop NAS mode)
# Usage:
#   1. Save as ./install-cn.sh
#   2. chmod +x install-cn.sh
#   3. sudo ./install-cn.sh
#==============================================================================

set -euo pipefail
IFS=$'\n\t'

NAS_USERNAME="nasuser"
NAS_PASSWORD="nas123456"
DOCKER_REPO_TENCENT="https://mirrors.cloud.tencent.com/docker-ce"
DOCKER_REPO_USTC="https://mirrors.ustc.edu.cn/docker-ce"
HA_MACHINE_TYPE="generic-x86-64"
WARP_SCRIPT="https://raw.githubusercontent.com/fscarmen/warp/main/menu.sh"
GH_PROXY="https://ghproxy.com/https://github.com"
LOGFILE="/var/log/install-cn.log"

# -------------------------
# Utility functions
# -------------------------
log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOGFILE"; }
warn() { echo -e "\033[33m[$(date +'%F %T')] ⚠️  $*\033[0m" | tee -a "$LOGFILE"; }
error() { echo -e "\033[31m[$(date +'%F %T')] ❌ ERROR: $*\033[0m" | tee -a "$LOGFILE" >&2; exit 1; }
success() { echo -e "\033[32m[$(date +'%F %T')] ✅ $*\033[0m" | tee -a "$LOGFILE"; }

mkdir -p "$(dirname "$LOGFILE")" && touch "$LOGFILE" && chmod 644 "$LOGFILE"
trap 'error "Script interrupted. Check log: $LOGFILE"' ERR

log "Starting installation: Debian12 NAS + Home Assistant (CN Enhanced)"

# -------------------------
# Step 0: Environment check
# -------------------------
if [ "$(id -u)" -ne 0 ]; then error "This script must be run as root"; fi

if ! grep -qi "debian.*12" /etc/os-release; then
    warn "System is not Debian 12. Continue anyway?"
    read -rp "[y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && error "Aborted by user."
fi

# -------------------------
# Step 1: Network test
# -------------------------
log "Checking GitHub connectivity..."
if curl -s --max-time 6 https://github.com >/dev/null 2>&1; then
    success "GitHub reachable ✅"
    USE_WARP=0
else
    warn "GitHub unreachable — installing Warp to enable proxy"
    USE_WARP=1
fi

# -------------------------
# Step 2: System update
# -------------------------
log "Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update -y && apt full-upgrade -y
success "System updated successfully"

# -------------------------
# Step 3: Base dependencies
# -------------------------
log "Installing base dependencies..."
apt install -y curl wget ca-certificates apt-transport-https gnupg lsb-release jq \
    apparmor apparmor-utils avahi-daemon dbus network-manager \
    systemd-journal-remote software-properties-common samba \
    tlp cpufrequtils smartmontools bash-completion udisks2 || error "Dependency installation failed"
success "Base dependencies installed"

# -------------------------
# Step 4: Install Warp (if needed)
# -------------------------
if [ "$USE_WARP" -eq 1 ]; then
    log "Installing Cloudflare Warp..."
    if curl -fsSL "$WARP_SCRIPT" -o /tmp/warp.sh; then
        bash /tmp/warp.sh d || warn "Warp script exit non-zero"
    else
        warn "Primary Warp script failed, trying git.io"
        curl -fsSL https://git.io/warp.sh | bash || warn "Fallback Warp install failed"
    fi

    sleep 5
    if curl -s --max-time 8 https://github.com >/dev/null 2>&1; then
        success "Warp enabled successfully, GitHub now accessible"
    else
        error "Warp installed but GitHub still unreachable"
    fi
else
    log "Skipping Warp installation"
fi

# -------------------------
# Step 5: Docker installation (Tencent → fallback USTC)
# -------------------------
if command -v docker >/dev/null 2>&1; then
    success "Docker already installed, skipping"
else
    log "Installing Docker (Tencent Cloud mirror, GPG fix)"
    mkdir -p /etc/apt/keyrings
    if ! curl -fsSL ${DOCKER_REPO_TENCENT}/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
        warn "Failed to get Tencent key, switching to USTC"
        curl -fsSL ${DOCKER_REPO_USTC}/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || error "Cannot get Docker GPG key"
    fi
    chmod a+r /etc/apt/keyrings/docker.gpg

    ARCH=$(dpkg --print-architecture)
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO_TENCENT}/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list

    if ! apt update -y; then
        warn "Tencent mirror failed, fallback to USTC"
        echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_REPO_USTC}/linux/debian $CODENAME stable" > /etc/apt/sources.list.d/docker.list
        apt update -y || error "Failed to update Docker source"
    fi

    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error "Docker installation failed"

    systemctl enable docker || warn "Cannot enable docker"
    systemctl start docker || error "Cannot start docker"
    mkdir -p /etc/docker

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

    systemctl daemon-reload
    systemctl restart docker || warn "Docker restart failed"
    success "Docker installed & registry mirrors configured"
fi

# -------------------------
# Step 6: Install Home Assistant Supervised
# -------------------------
if systemctl is-active --quiet home-assistant-supervised; then
    success "Home Assistant already running"
else
    log "Installing Home Assistant Supervised..."
    mkdir -p /opt/ha-install && cd /opt/ha-install
    INSTALLER_URL="${GH_PROXY}/home-assistant/supervised-installer/releases/latest/download/installer.sh"
    if curl -fLo installer.sh "$INSTALLER_URL"; then
        chmod +x installer.sh
        bash installer.sh --machine "$HA_MACHINE_TYPE" || warn "Installer exit non-zero"
        systemctl enable home-assistant-supervised || warn "Enable failed"
        success "Home Assistant installation completed"
    else
        error "Failed to download HA installer (ghproxy unreachable)"
    fi
fi

# -------------------------
# Step 7: Configure Samba NAS
# -------------------------
log "Setting up Samba NAS share..."
if ! id "$NAS_USERNAME" >/dev/null 2>&1; then
    useradd -m -s /usr/sbin/nologin "$NAS_USERNAME"
fi
echo "${NAS_USERNAME}:${NAS_PASSWORD}" | chpasswd

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
systemctl enable smbd && systemctl restart smbd
success "Samba NAS configured"

# -------------------------
# Step 8: Install Tailscale
# -------------------------
if command -v tailscale >/dev/null; then
    success "Tailscale already installed"
else
    log "Installing Tailscale..."
    curl -fsSL https://pkgs.tailscale.com/stable/install.sh | sh
    systemctl enable --now tailscaled
    success "Tailscale installed. Run 'sudo tailscale up' to login"
fi

# -------------------------
# Step 9: Power saving & Lid close
# -------------------------
log "Configuring power saving..."
systemctl enable --now tlp || warn "TLP failed"
cpufreq-set -g powersave || warn "Failed to set CPU to powersave"

log "Preventing lid close sleep..."
CONF="/etc/systemd/logind.conf"
sed -i 's/^#*HandleLidSwitch=.*/HandleLidSwitch=ignore/' "$CONF"
sed -i 's/^#*HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' "$CONF"
sed -i 's/^#*HandleLidSwitchDocked=.*/HandleLidSwitchDocked=ignore/' "$CONF"
systemctl restart systemd-logind || true
success "Laptop NAS mode configured"

# -------------------------
# Done
# -------------------------
LAN_IP=$(hostname -I | awk '{print $1}')
echo
echo "=========================================="
success "🎉 Installation completed!"
echo "=========================================="
echo "🏠 Home Assistant: http://${LAN_IP}:8123"
echo "📁 NAS share path: \\\\${LAN_IP}\\share"
echo "🔐 NAS user/pass: ${NAS_USERNAME} / ${NAS_PASSWORD}"
echo "🔗 Tailscale: sudo tailscale up"
echo "=========================================="
success "System ready!"
exit 0
