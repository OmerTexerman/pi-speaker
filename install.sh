#!/usr/bin/env bash
set -euo pipefail

echo "=== Home Assistant Room Audio + Voice Node Installer ==="

read -rp "Room name, e.g. Pool, Kitchen, Bedroom: " ROOM_NAME
read -rp "Home Assistant / Snapcast host/IP: " HA_HOST

ROOM_SAFE="$(echo "$ROOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${CURRENT_USER}")"

echo "=== Network check ==="
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo "No internet detected. Plug in Ethernet or fix networking first."
  exit 1
fi

echo "=== Hostname setup ==="
sudo hostnamectl set-hostname "$ROOM_SAFE"

if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${ROOM_SAFE}/" /etc/hosts
else
  echo -e "127.0.1.1\t${ROOM_SAFE}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "=== Optional Wi-Fi unblock, harmless if unused ==="
sudo rfkill unblock wifi || true
sudo raspi-config nonint do_wifi_country US || true

echo "=== Updating system ==="
sudo apt update
sudo apt full-upgrade -y

echo "=== Installing packages ==="
sudo apt install -y \
  curl wget git jq ca-certificates \
  alsa-utils pulseaudio-utils \
  avahi-daemon rfkill \
  python3 python3-venv python3-pip \
  build-essential pkg-config libssl-dev libasound2-dev \
  snapclient

sudo usermod -aG audio "$CURRENT_USER"

echo "=== Installing Rust ==="
if ! command -v cargo >/dev/null 2>&1; then
  sudo -u "$CURRENT_USER" bash -lc 'curl https://sh.rustup.rs -sSf | sh -s -- -y'
fi

echo "=== Installing librespot ==="
sudo -u "$CURRENT_USER" bash -lc 'source "$HOME/.cargo/env" && cargo install librespot'

LIBRESPOT_BIN="${USER_HOME}/.cargo/bin/librespot"

echo "=== Creating librespot service ==="
sudo mkdir -p /var/lib/librespot
sudo chown -R "$CURRENT_USER":"$CURRENT_USER" /var/lib/librespot

sudo tee /etc/systemd/system/librespot.service >/dev/null <<EOF
[Unit]
Description=Spotify Connect receiver (${ROOM_NAME})
After=network-online.target sound.target
Wants=network-online.target

[Service]
User=${CURRENT_USER}
Group=audio
ExecStart=${LIBRESPOT_BIN} \\
  --name "${ROOM_NAME}" \\
  --backend alsa \\
  --device default \\
  --bitrate 320 \\
  --cache /var/lib/librespot \\
  --enable-volume-normalisation
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== Configuring Snapclient ==="
sudo tee /etc/default/snapclient >/dev/null <<EOF
SNAPCLIENT_OPTS="--host ${HA_HOST} --hostID ${ROOM_SAFE} --instance 1"
EOF

echo "=== Installing Wyoming Satellite ==="
cd "$USER_HOME"

if [[ ! -d "$USER_HOME/wyoming-satellite" ]]; then
  sudo -u "$CURRENT_USER" git clone https://github.com/rhasspy/wyoming-satellite.git "$USER_HOME/wyoming-satellite"
else
  sudo -u "$CURRENT_USER" bash -lc "cd '$USER_HOME/wyoming-satellite' && git pull --ff-only || true"
fi

cd "$USER_HOME/wyoming-satellite"
sudo -u "$CURRENT_USER" python3 -m venv .venv
sudo -u "$CURRENT_USER" .venv/bin/pip install --upgrade pip wheel setuptools
sudo -u "$CURRENT_USER" .venv/bin/pip install -f 'https://synesthesiam.github.io/prebuilt-apps/' -e '.[all]'

echo "=== Audio devices ==="
echo "Microphones:"
arecord -L || true
echo
echo "Speakers:"
aplay -L || true
echo

read -rp "Mic ALSA device [default]: " MIC_DEVICE
MIC_DEVICE="${MIC_DEVICE:-default}"

read -rp "Speaker ALSA device [default]: " SND_DEVICE
SND_DEVICE="${SND_DEVICE:-default}"

echo "=== Creating Wyoming Satellite service ==="
sudo tee /etc/systemd/system/wyoming-satellite.service >/dev/null <<EOF
[Unit]
Description=Wyoming Satellite (${ROOM_NAME})
Wants=network-online.target
After=network-online.target sound.target

[Service]
Type=simple
User=${CURRENT_USER}
Group=audio
WorkingDirectory=${USER_HOME}/wyoming-satellite
ExecStart=${USER_HOME}/wyoming-satellite/script/run \\
  --name "${ROOM_NAME}" \\
  --uri "tcp://0.0.0.0:10700" \\
  --mic-command "arecord -D ${MIC_DEVICE} -r 16000 -c 1 -f S16_LE -t raw" \\
  --snd-command "aplay -D ${SND_DEVICE} -r 22050 -c 1 -f S16_LE -t raw"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "=== Creating audio-mode helper ==="
sudo tee /usr/local/bin/audio-mode >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  spotify)
    sudo systemctl stop snapclient || true
    sudo systemctl start librespot
    echo "Spotify mode enabled."
    ;;
  multiroom|snapcast)
    sudo systemctl stop librespot || true
    sudo systemctl start snapclient
    echo "Snapcast multiroom mode enabled."
    ;;
  off)
    sudo systemctl stop librespot || true
    sudo systemctl stop snapclient || true
    echo "Audio playback off. Wyoming voice still running."
    ;;
  status)
    systemctl --no-pager --full status librespot snapclient wyoming-satellite || true
    ;;
  *)
    echo "Usage: audio-mode {spotify|multiroom|snapcast|off|status}"
    exit 1
    ;;
esac
EOF

sudo chmod +x /usr/local/bin/audio-mode

echo "=== Saving config ==="
sudo tee /etc/room-node.conf >/dev/null <<EOF
ROOM_NAME="${ROOM_NAME}"
ROOM_SAFE="${ROOM_SAFE}"
HA_HOST="${HA_HOST}"
MIC_DEVICE="${MIC_DEVICE}"
SND_DEVICE="${SND_DEVICE}"
EOF

echo "=== Enabling services ==="
sudo systemctl daemon-reload
sudo systemctl enable avahi-daemon librespot snapclient wyoming-satellite

echo "=== Starting services ==="
sudo systemctl restart avahi-daemon
sudo systemctl stop snapclient || true
sudo systemctl restart librespot
sudo systemctl restart wyoming-satellite

echo
echo "=== Done ==="
echo "Spotify device name: ${ROOM_NAME}"
echo "Wyoming satellite name: ${ROOM_NAME}"
echo
echo "Commands:"
echo "  audio-mode spotify"
echo "  audio-mode multiroom"
echo "  audio-mode status"
echo
echo "Reboot recommended:"
echo "  sudo reboot"