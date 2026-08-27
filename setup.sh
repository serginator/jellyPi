#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[flexPi]${NC} $1"; }
warn() { echo -e "${YELLOW}[flexPi]${NC} $1"; }
die()  { echo -e "${RED}[flexPi]${NC} $1"; exit 1; }

[[ $EUID -ne 0 ]] && die "Run with: sudo bash setup.sh"

STORAGE=/mnt/storage
MAIN_USER=$(getent passwd 1000 | cut -d: -f1)

# ── 1. HDD ────────────────────────────────────────────────────────────────────
log "Available block devices:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -v loop
echo
read -rp "Enter HDD device (e.g. sda or sda1): " HDD_INPUT
HDD="/dev/${HDD_INPUT}"
[[ -b $HDD ]] || die "Device $HDD not found"

warn "This will ERASE all data on $HDD"
read -rp "Type 'yes' to confirm: " CONFIRM
[[ $CONFIRM == "yes" ]] || die "Aborted"

# ── 2. Format & mount ─────────────────────────────────────────────────────────
log "Formatting $HDD as ext4..."
mkfs.ext4 -L jellypi -F "$HDD"

log "Mounting at $STORAGE..."
mkdir -p "$STORAGE"
UUID=$(blkid -s UUID -o value "$HDD")
grep -q "$UUID" /etc/fstab || \
    echo "UUID=$UUID  $STORAGE  ext4  defaults,noatime  0  2" >> /etc/fstab
mount "$STORAGE"

# ── 3. Directory structure ────────────────────────────────────────────────────
# torrents/ and media/ share the same mount → Sonarr/Radarr use hardlinks (zero copy)
log "Creating directory structure..."
mkdir -p \
    "$STORAGE/data/torrents/movies" \
    "$STORAGE/data/torrents/tv" \
    "$STORAGE/data/media/movies" \
    "$STORAGE/data/media/tv" \
    "$STORAGE/config/jellyfin" \
    "$STORAGE/config/sonarr" \
    "$STORAGE/config/radarr" \
    "$STORAGE/config/prowlarr" \
    "$STORAGE/config/qbittorrent" \
    "$STORAGE/config/jellyseerr" \
    "$STORAGE/docker"

chown -R 1000:1000 "$STORAGE"

# ── 4. Disable swap ───────────────────────────────────────────────────────────
log "Disabling swap (Pi 4 has enough RAM)..."
dphys-swapfile swapoff   2>/dev/null || true
dphys-swapfile uninstall 2>/dev/null || true
systemctl disable dphys-swapfile 2>/dev/null || true

# ── 5. fstab: tmpfs for /tmp ──────────────────────────────────────────────────
log "Adding tmpfs mounts..."
grep -q "tmpfs.*/tmp " /etc/fstab || \
    echo "tmpfs  /tmp      tmpfs  defaults,noatime,size=100m  0  0" >> /etc/fstab
grep -q "tmpfs.*/var/tmp" /etc/fstab || \
    echo "tmpfs  /var/tmp  tmpfs  defaults,noatime,size=30m   0  0" >> /etc/fstab

# Add commit=60 to root partition (groups writes in 60s bursts instead of 5s)
if ! grep -q "commit=" /etc/fstab; then
    sed -i '/[[:space:]]\/[[:space:]].*ext4/s/noatime/noatime,commit=60/' /etc/fstab
    # Fallback: if noatime was not already present
    grep -q "commit=" /etc/fstab || \
        sed -i '/[[:space:]]\/[[:space:]].*ext4/s/defaults/defaults,noatime,commit=60/' /etc/fstab
fi

mount -a

# ── 6. log2ram ────────────────────────────────────────────────────────────────
if ! command -v log2ram &>/dev/null; then
    log "Installing log2ram..."
    echo "deb [signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] \
http://packages.azlux.fr/debian/ bookworm main" \
        | tee /etc/apt/sources.list.d/azlux.list
    wget -qO /usr/share/keyrings/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
    apt-get update -qq && apt-get install -y log2ram
else
    log "log2ram already installed, skipping"
fi

# ── 7. Docker ─────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$MAIN_USER"
    warn "User $MAIN_USER added to docker group. Log out and back in for it to take effect."
fi

log "Configuring Docker data-root to HDD..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$STORAGE/docker",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

systemctl restart docker

# ── 8. Pi 4 GPU memory for Jellyfin hardware acceleration ────────────────────
CONFIG=/boot/firmware/config.txt
[[ -f $CONFIG ]] || CONFIG=/boot/config.txt
if ! grep -q "gpu_mem=128" "$CONFIG"; then
    log "Setting gpu_mem=128 for Jellyfin V4L2 hardware acceleration..."
    echo "gpu_mem=128" >> "$CONFIG"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
IP=$(hostname -I | awk '{print $1}')
log "Setup complete! Reboot the Pi, then run: docker compose up -d"
echo
echo "  Jellyfin (media):    http://$IP:8096"
echo "  Jellyseerr (request): http://$IP:5055"
echo "  Sonarr (TV):         http://$IP:8989"
echo "  Radarr (movies):     http://$IP:7878"
echo "  Prowlarr (indexers): http://$IP:9696"
echo "  qBittorrent:         http://$IP:8080"
