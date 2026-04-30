#!/usr/bin/env bash
set -e

echo "=== Room Audio Node Setup ==="

read -p "Room name (e.g. kitchen): " ROOM
read -p "Home Assistant IP: " HA_IP

ROOM_SAFE=$(echo "$ROOM" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

echo "Setting hostname..."
sudo hostnamectl set-hostname $ROOM_SAFE

echo "Updating system..."
sudo apt update && sudo apt upgrade -y

echo "Installing packages..."
sudo apt install -y \
  git curl jq \
  alsa-utils \
  snapclient \
  build-essential pkg-config libasound2-dev

echo "Installing librespot..."
curl https://sh.rustup.rs -sSf | sh -s -- -y
source $HOME/.cargo/env
cargo install librespot

echo "Configuring Snapclient..."
sudo tee /etc/default/snapclient <<EOF
SNAPCLIENT_OPTS="--host $HA_IP --hostID $ROOM_SAFE"
EOF

echo "Creating librespot service..."
sudo tee /etc/systemd/system/librespot.service <<EOF
[Unit]
Description=Spotify Connect ($ROOM)
After=network.target

[Service]
User=$USER
ExecStart=$HOME/.cargo/bin/librespot \\
  --name "$ROOM" \\
  --backend alsa \\
  --device default \\
  --bitrate 320
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "Creating audio mode switcher..."
sudo tee /usr/local/bin/audio-mode <<'EOF'
#!/bin/bash

case "$1" in
  spotify)
    systemctl --user start librespot
    sudo systemctl stop snapclient
    ;;
  multiroom)
    systemctl --user stop librespot
    sudo systemctl start snapclient
    ;;
  *)
    echo "Usage: audio-mode {spotify|multiroom}"
    ;;
esac
EOF

sudo chmod +x /usr/local/bin/audio-mode

echo "Enabling services..."
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable snapclient
sudo systemctl enable librespot

echo "Defaulting to Spotify mode..."
sudo systemctl stop snapclient
sudo systemctl start librespot

echo "Done. Reboot recommended."