#!/usr/bin/env bash
set -euo pipefail

echo "=== Home Assistant Room Audio + Voice Node Installer ==="
echo

read -rp "Room name, e.g. Pool, Kitchen, Bedroom: " ROOM_NAME
read -rp "Home Assistant / Snapcast server host/IP, e.g. 192.168.1.71 or home.texerman.com: " HA_HOST

ROOM_SAFE="$(echo "$ROOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${CURRENT_USER}")"

if [[ -z "$ROOM_SAFE" ]]; then
  echo "Room name became empty after sanitizing. Use letters/numbers."
  exit 1
fi

echo
echo "Room display name: $ROOM_NAME"
echo "Hostname: $ROOM_SAFE"
echo "HA/Snapcast host: $HA_HOST"
echo "Linux user: $CURRENT_USER"
echo

echo "=== Fixing hostname + /etc/hosts ==="
sudo hostnamectl set-hostname "$ROOM_SAFE"

if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${ROOM_SAFE}/" /etc/hosts
else
  echo -e "127.0.1.1\t${ROOM_SAFE}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "=== Updating system ==="
sudo apt update
sudo apt full-upgrade -y

echo "=== Installing base packages ==="
sudo apt install -y --no-install-recommends \
  curl wget git jq ca-certificates \
  alsa-utils pulseaudio-utils \
  avahi-daemon \
  python3 python3-venv python3-pip \
  build-essential pkg-config libssl-dev libasound2-dev \
  snapclient

echo "=== Ensuring audio group access ==="
sudo usermod -aG audio "$CURRENT_USER"

echo "=== Installing Rust if needed ==="
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
if [[ -f /etc/default/snapclient ]]; then
  sudo cp /etc/default/snapclient "/etc/default/snapclient.bak.$(date +%s)"
fi

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

echo
echo "=== Audio device discovery ==="
echo
echo "Microphone devices:"
arecord -L || true
echo
echo "Speaker devices:"
aplay -L || true
echo

echo "For USB ReSpeaker, the mic often appears as something like:"
echo "  plughw:CARD=ArrayUAC10,DEV=0"
echo "or:"
echo "  plughw:CARD=seeed2micvoicec,DEV=0"
echo
echo "If unsure, type: default"
echo

read -rp "Mic ALSA device for Wyoming [default]: " MIC_DEVICE
MIC_DEVICE="${MIC_DEVICE:-default}"

read -rp "Speaker ALSA device for Wyoming TTS [default]: " SND_DEVICE
SND_DEVICE="${SND_DEVICE:-default}"

echo
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

MODE="${1:-}"

case "$MODE" in
  spotify)
    sudo systemctl stop snapclient || true
    sudo systemctl start librespot
    echo "Spotify Connect mode enabled."
    ;;
  multiroom|snapcast)
    sudo systemctl stop librespot || true
    sudo systemctl start snapclient
    echo "Snapcast multiroom mode enabled."
    ;;
  both)
    sudo systemctl start librespot || true
    sudo systemctl start snapclient || true
    echo "Both started. Warning: they may fight for the same audio device."
    ;;
  off)
    sudo systemctl stop librespot || true
    sudo systemctl stop snapclient || true
    echo "Audio playback services stopped. Wyoming voice remains running."
    ;;
  status)
    systemctl --no-pager --full status librespot snapclient wyoming-satellite || true
    ;;
  *)
    echo "Usage: audio-mode {spotify|multiroom|snapcast|both|off|status}"
    exit 1
    ;;
esac
EOF

sudo chmod +x /usr/local/bin/audio-mode

echo "=== Saving room config ==="
sudo tee /etc/room-node.conf >/dev/null <<EOF
ROOM_NAME="${ROOM_NAME}"
ROOM_SAFE="${ROOM_SAFE}"
HA_HOST="${HA_HOST}"
MIC_DEVICE="${MIC_DEVICE}"
SND_DEVICE="${SND_DEVICE}"
EOF

echo "=== Enabling services ==="
sudo systemctl daemon-reload
sudo systemctl enable avahi-daemon
sudo systemctl enable librespot
sudo systemctl enable snapclient
sudo systemctl enable wyoming-satellite

echo "=== Starting default services ==="
sudo systemctl restart avahi-daemon
sudo systemctl stop snapclient || true
sudo systemctl restart librespot
sudo systemctl restart wyoming-satellite

echo
echo "=== Install complete ==="
echo
echo "Spotify Connect device name: ${ROOM_NAME}"
echo "Wyoming satellite name: ${ROOM_NAME}"
echo
echo "Useful commands:"
echo "  audio-mode spotify"
echo "  audio-mode multiroom"
echo "  audio-mode off"
echo "  audio-mode status"
echo
echo "Test mic manually:"
echo "  arecord -D ${MIC_DEVICE} -r 16000 -c 1 -f S16_LE -t wav -d 5 test.wav"
echo
echo "Test speaker manually:"
echo "  aplay -D ${SND_DEVICE} test.wav"
echo
echo "Wyoming logs:"
echo "  journalctl -u wyoming-satellite -f"
echo
echo "Now go to Home Assistant:"
echo "  Settings → Devices & services"
echo "  Add/accept the discovered Wyoming Protocol device."
echo
echo "Reboot recommended:"
echo "  sudo reboot"