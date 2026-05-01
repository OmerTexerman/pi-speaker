#!/usr/bin/env bash
set -euo pipefail

# Home Assistant Room Audio + Voice Node
# Installs/configures:
#   - PipeWire/PipeWire-Pulse as the mixer for all app audio
#   - Raspotify package only to get a prebuilt librespot binary
#   - User-service Spotify Connect receiver
#   - User-service Snapcast client for whole-home/group playback
#   - User-service Shairport Sync AirPlay receiver for non-Spotify audio from Apple devices
#   - User-service Wyoming Satellite for Home Assistant Assist
#   - User-service ducking daemon that lowers music while Wyoming TTS is speaking

SCRIPT_VERSION="2026-05-01.2"

ROOM_NAME=""
HA_HOST=""
DUCK_LEVEL="35"
INSTALL_AIRPLAY="1"
INSTALL_BLUETOOTH="0"
DISABLE_WIFI="1"
DISABLE_BLUETOOTH="1"
MIC_DEVICE=""
SET_SINK_ID=""
NONINTERACTIVE="0"

usage() {
  cat <<'USAGE'
Usage:
  ./install_room_node_full.sh --room "Pool" --ha 192.168.1.71 [options]

Options:
  --room NAME             Room display name, e.g. "Pool" or "Kitchen"
  --ha HOST_OR_IP         Home Assistant / Snapcast host or IP
  --duck PERCENT          Duck music to this volume while TTS plays. Default: 35
  --mic-device DEVICE     ALSA mic device for Wyoming, e.g. default or plughw:CARD=ArrayUAC10,DEV=0
  --sink-id ID            PipeWire/WirePlumber sink ID to set as default, from `wpctl status`
  --no-airplay            Do not install Shairport Sync / AirPlay receiver
  --with-bluetooth        Install Bluetooth audio packages and keep Bluetooth enabled
  --keep-wifi             Do not disable Wi-Fi
  --keep-bluetooth        Do not disable Bluetooth
  --noninteractive        Do not prompt; require --room and --ha
  -h, --help              Show this help

Examples:
  ./install_room_node_full.sh --room "Pool" --ha 192.168.1.71
  ./install_room_node_full.sh --room "Kitchen" --ha home.texerman.com --duck 25
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --room) ROOM_NAME="${2:-}"; shift 2 ;;
    --ha) HA_HOST="${2:-}"; shift 2 ;;
    --duck) DUCK_LEVEL="${2:-}"; shift 2 ;;
    --mic-device) MIC_DEVICE="${2:-}"; shift 2 ;;
    --sink-id) SET_SINK_ID="${2:-}"; shift 2 ;;
    --no-airplay) INSTALL_AIRPLAY="0"; shift ;;
    --with-bluetooth) INSTALL_BLUETOOTH="1"; DISABLE_BLUETOOTH="0"; shift ;;
    --keep-wifi) DISABLE_WIFI="0"; shift ;;
    --keep-bluetooth) DISABLE_BLUETOOTH="0"; shift ;;
    --noninteractive) NONINTERACTIVE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$ROOM_NAME" && "$NONINTERACTIVE" != "1" ]]; then
  read -rp "Room name, e.g. Pool, Kitchen, Bedroom: " ROOM_NAME
fi
if [[ -z "$HA_HOST" && "$NONINTERACTIVE" != "1" ]]; then
  read -rp "Home Assistant / Snapcast host/IP, e.g. 192.168.1.71 or home.texerman.com: " HA_HOST
fi
if [[ -z "$ROOM_NAME" || -z "$HA_HOST" ]]; then
  echo "ERROR: --room and --ha are required."
  usage
  exit 1
fi
if ! [[ "$DUCK_LEVEL" =~ ^[0-9]+$ ]] || (( DUCK_LEVEL < 1 || DUCK_LEVEL > 100 )); then
  echo "ERROR: --duck must be a number from 1 to 100."
  exit 1
fi

ROOM_SAFE="$(echo "$ROOM_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
if [[ -z "$ROOM_SAFE" ]]; then
  echo "ERROR: sanitized room name is empty. Use letters/numbers."
  exit 1
fi

CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME="$(eval echo "~${CURRENT_USER}")"
USER_ID="$(id -u "$CURRENT_USER")"
USER_GROUP="$(id -gn "$CURRENT_USER")"
USER_RUNTIME="/run/user/${USER_ID}"
USER_BUS="unix:path=${USER_RUNTIME}/bus"
USER_SYSTEMD_DIR="${USER_HOME}/.config/systemd/user"

log() { echo; echo "=== $* ==="; }

run_as_user() {
  sudo -u "$CURRENT_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="$USER_BUS" bash -lc "$*"
}

userctl() {
  sudo -u "$CURRENT_USER" XDG_RUNTIME_DIR="$USER_RUNTIME" DBUS_SESSION_BUS_ADDRESS="$USER_BUS" systemctl --user "$@"
}

log "Room node installer ${SCRIPT_VERSION}"
echo "Room display name: ${ROOM_NAME}"
echo "Hostname:          ${ROOM_SAFE}"
echo "HA/Snapcast host:  ${HA_HOST}"
echo "Linux user:        ${CURRENT_USER}"
echo "Duck level:        ${DUCK_LEVEL}%"
echo "AirPlay:           ${INSTALL_AIRPLAY}"
echo "Bluetooth audio:   ${INSTALL_BLUETOOTH}"

log "Network sanity check"
if getent hosts "$HA_HOST" >/dev/null 2>&1; then
  echo "${HA_HOST} resolves to: $(getent hosts "$HA_HOST" | awk '{print $1}' | paste -sd ',')"
else
  echo "WARNING: ${HA_HOST} does not resolve right now. Continuing."
fi
if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo "WARNING: Internet ping failed. apt/git downloads may fail."
fi

log "Hostname + /etc/hosts"
sudo hostnamectl set-hostname "$ROOM_SAFE"
if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${ROOM_SAFE}/" /etc/hosts
else
  echo -e "127.0.1.1\t${ROOM_SAFE}" | sudo tee -a /etc/hosts >/dev/null
fi

log "Radio power options"
if [[ "$DISABLE_WIFI" == "1" ]]; then sudo rfkill block wifi || true; fi
if [[ "$DISABLE_BLUETOOTH" == "1" ]]; then sudo rfkill block bluetooth || true; fi
sudo raspi-config nonint do_wifi_country US >/dev/null 2>&1 || true

log "Apt update + base packages"
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y --no-install-recommends \
  curl wget git jq ca-certificates apt-transport-https gnupg \
  avahi-daemon rfkill \
  alsa-utils libasound2-plugins pulseaudio-utils \
  pipewire pipewire-bin pipewire-pulse wireplumber \
  python3 python3-venv python3-pip \
  snapclient
sudo systemctl disable --now snapclient.service librespot.service wyoming-satellite.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/librespot.service /etc/systemd/system/wyoming-satellite.service || true
sudo systemctl daemon-reload || true

sudo apt install -y --no-install-recommends pipewire-alsa || true

if [[ "$INSTALL_AIRPLAY" == "1" ]]; then
  sudo apt install -y --no-install-recommends shairport-sync
  sudo systemctl disable --now shairport-sync.service >/dev/null 2>&1 || true
fi

if [[ "$INSTALL_BLUETOOTH" == "1" ]]; then
  sudo apt install -y --no-install-recommends bluez bluetooth libspa-0.2-bluetooth
fi

for grp in audio video input bluetooth; do
  if getent group "$grp" >/dev/null 2>&1; then
    sudo usermod -aG "$grp" "$CURRENT_USER" || true
  fi
done

log "Enable linger for user services"
sudo loginctl enable-linger "$CURRENT_USER" || true
sudo mkdir -p "$USER_SYSTEMD_DIR"
sudo chown -R "$CURRENT_USER:$USER_GROUP" "${USER_HOME}/.config"

log "ALSA default -> PipeWire/Pulse"
sudo -u "$CURRENT_USER" tee "${USER_HOME}/.asoundrc" >/dev/null <<'ASOUNDRC_EOF'
pcm.!default {
    type pulse
}
ctl.!default {
    type pulse
}
ASOUNDRC_EOF

log "Start PipeWire user services"
if [[ -S "${USER_RUNTIME}/bus" ]]; then
  userctl daemon-reload || true
  userctl enable --now pipewire.service pipewire-pulse.service wireplumber.service || true
else
  echo "WARNING: user systemd bus not present at ${USER_RUNTIME}/bus. Reboot will usually fix this."
fi
sleep 2

if [[ -S "${USER_RUNTIME}/bus" ]]; then
  echo "Current PipeWire status:"
  run_as_user 'wpctl status || true'
fi

if [[ -z "$SET_SINK_ID" && "$NONINTERACTIVE" != "1" && -S "${USER_RUNTIME}/bus" ]]; then
  echo
  echo "If the default audio output above is wrong, enter the WirePlumber sink ID now."
  read -rp "Default sink ID from wpctl status [blank]: " SET_SINK_ID
fi
if [[ -n "$SET_SINK_ID" && -S "${USER_RUNTIME}/bus" ]]; then
  run_as_user "wpctl set-default '${SET_SINK_ID}' || true"
  run_as_user "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.75 || true"
fi

log "Install Raspotify package for prebuilt librespot"
sudo apt-get -y install curl
curl -sL https://dtcooper.github.io/raspotify/install.sh | sh
sudo systemctl disable --now raspotify.service >/dev/null 2>&1 || true

LIBRESPOT_BIN="$(command -v librespot || true)"
if [[ -z "$LIBRESPOT_BIN" ]]; then
  LIBRESPOT_BIN="$(dpkg -L raspotify 2>/dev/null | grep -E '/librespot$' | head -n 1 || true)"
fi
if [[ -z "$LIBRESPOT_BIN" || ! -x "$LIBRESPOT_BIN" ]]; then
  echo "ERROR: Could not find librespot binary after installing Raspotify."
  echo "Run: dpkg -L raspotify | grep librespot"
  exit 1
fi
echo "Using librespot: ${LIBRESPOT_BIN}"

log "Create Spotify/Snapcast/AirPlay user services"
sudo -u "$CURRENT_USER" mkdir -p "$USER_SYSTEMD_DIR" "${USER_HOME}/.cache/librespot"

cat > /tmp/spotify-connect.service <<SPOTIFY_EOF
[Unit]
Description=Spotify Connect receiver (${ROOM_NAME})
After=pipewire-pulse.service network-online.target
Wants=pipewire-pulse.service network-online.target

[Service]
Type=simple
ExecStart=${LIBRESPOT_BIN} \\
  --name "${ROOM_NAME}" \\
  --backend alsa \\
  --device default \\
  --bitrate 320 \\
  --cache "${USER_HOME}/.cache/librespot" \\
  --enable-volume-normalisation
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SPOTIFY_EOF
sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/spotify-connect.service "${USER_SYSTEMD_DIR}/spotify-connect.service"
rm -f /tmp/spotify-connect.service

SNAP_PLAYER_ARGS="--player alsa --soundcard default"
if snapclient --player pulse:? >/dev/null 2>&1; then
  SNAP_PLAYER_ARGS="--player pulse"
fi

cat > /tmp/snapclient-room.service <<SNAP_EOF
[Unit]
Description=Snapcast client (${ROOM_NAME})
After=pipewire-pulse.service network-online.target
Wants=pipewire-pulse.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/snapclient --host "${HA_HOST}" --hostID "${ROOM_SAFE}" --instance 1 ${SNAP_PLAYER_ARGS}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SNAP_EOF
sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/snapclient-room.service "${USER_SYSTEMD_DIR}/snapclient-room.service"
rm -f /tmp/snapclient-room.service

if [[ "$INSTALL_AIRPLAY" == "1" ]]; then
  sudo -u "$CURRENT_USER" tee "${USER_HOME}/.config/shairport-sync.conf" >/dev/null <<SHAIRPORT_CONF_EOF
general = {
  name = "${ROOM_NAME} AirPlay";
  output_backend = "alsa";
};
alsa = {
  output_device = "default";
};
SHAIRPORT_CONF_EOF

  cat > /tmp/shairport-sync-user.service <<SHAIRPORT_EOF
[Unit]
Description=AirPlay receiver (${ROOM_NAME})
After=pipewire-pulse.service network-online.target avahi-daemon.service
Wants=pipewire-pulse.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/shairport-sync -c ${USER_HOME}/.config/shairport-sync.conf
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SHAIRPORT_EOF
  sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/shairport-sync-user.service "${USER_SYSTEMD_DIR}/shairport-sync-user.service"
  rm -f /tmp/shairport-sync-user.service
fi

log "Install Wyoming Satellite"
cd "$USER_HOME"
if [[ ! -d "${USER_HOME}/wyoming-satellite" ]]; then
  sudo -u "$CURRENT_USER" git clone https://github.com/rhasspy/wyoming-satellite.git "${USER_HOME}/wyoming-satellite"
else
  sudo -u "$CURRENT_USER" bash -lc "cd '${USER_HOME}/wyoming-satellite' && git pull --ff-only || true"
fi
cd "${USER_HOME}/wyoming-satellite"
sudo -u "$CURRENT_USER" python3 -m venv .venv
sudo -u "$CURRENT_USER" .venv/bin/pip install --upgrade pip wheel setuptools
sudo -u "$CURRENT_USER" bash -lc "cd '${USER_HOME}/wyoming-satellite' && script/setup" || \
  sudo -u "$CURRENT_USER" bash -lc "cd '${USER_HOME}/wyoming-satellite' && .venv/bin/pip install -f 'https://synesthesiam.github.io/prebuilt-apps/' -e '.[all]'"

log "Audio device discovery"
echo "Microphone devices from arecord -L:"
arecord -L || true
echo
echo "PipeWire/WirePlumber status:"
if [[ -S "${USER_RUNTIME}/bus" ]]; then run_as_user 'wpctl status || true'; fi

if [[ -z "$MIC_DEVICE" && "$NONINTERACTIVE" != "1" ]]; then
  echo
  echo "For USB ReSpeaker, look for ArrayUAC10, ReSpeaker, seeed, or plughw:CARD=...,DEV=0."
  read -rp "Mic ALSA device for Wyoming [default]: " MIC_DEVICE
fi
MIC_DEVICE="${MIC_DEVICE:-default}"

log "Create Wyoming I/O wrappers"
sudo tee /usr/local/bin/wyoming-room-snd >/dev/null <<'WYOSND_EOF'
#!/usr/bin/env bash
set -euo pipefail
exec pw-cat --playback --raw --rate=22050 --channels=1 --format=s16 \
  --properties='{"media.name":"wyoming-tts","node.name":"wyoming-tts","application.name":"Wyoming TTS","media.role":"event"}'
WYOSND_EOF
sudo chmod +x /usr/local/bin/wyoming-room-snd

sudo tee /usr/local/bin/wyoming-room-mic >/dev/null <<WYOMIC_EOF
#!/usr/bin/env bash
set -euo pipefail
exec arecord -D "${MIC_DEVICE}" -r 16000 -c 1 -f S16_LE -t raw
WYOMIC_EOF
sudo chmod +x /usr/local/bin/wyoming-room-mic

cat > /tmp/wyoming-satellite-room.service <<WYO_EOF
[Unit]
Description=Wyoming Satellite (${ROOM_NAME})
After=network-online.target pipewire-pulse.service
Wants=network-online.target pipewire-pulse.service

[Service]
Type=simple
WorkingDirectory=${USER_HOME}/wyoming-satellite
ExecStart=${USER_HOME}/wyoming-satellite/script/run \\
  --name "${ROOM_NAME}" \\
  --uri "tcp://0.0.0.0:10700" \\
  --mic-command "/usr/local/bin/wyoming-room-mic" \\
  --snd-command "/usr/local/bin/wyoming-room-snd"
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
WYO_EOF
sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/wyoming-satellite-room.service "${USER_SYSTEMD_DIR}/wyoming-satellite-room.service"
rm -f /tmp/wyoming-satellite-room.service

log "Create ducking daemon"
sudo tee /usr/local/bin/room-ducker >/dev/null <<'DUCKER_EOF'
#!/usr/bin/env python3
import os
import re
import subprocess
import time

DUCK_PERCENT = os.environ.get("ROOM_DUCK_PERCENT", "35")
VOICE_MARKERS = ["wyoming-tts", "Wyoming TTS"]
volume_before = {}

def pactl(args):
    return subprocess.run(["pactl", *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

def list_inputs():
    res = pactl(["list", "sink-inputs"])
    if res.returncode != 0:
        return []
    inputs, current = [], []
    for line in res.stdout.splitlines():
        if line.startswith("Sink Input #"):
            if current:
                inputs.append("\n".join(current))
            current = [line]
        elif current:
            current.append(line)
    if current:
        inputs.append("\n".join(current))

    parsed = []
    for block in inputs:
        m = re.search(r"Sink Input #(\d+)", block)
        if not m:
            continue
        idx = m.group(1)
        is_voice = any(marker in block for marker in VOICE_MARKERS)
        vm = re.search(r"Volume:.*?/(\s*\d+)%", block)
        percent = vm.group(1).strip() if vm else "100"
        parsed.append({"id": idx, "voice": is_voice, "volume": percent})
    return parsed

def set_volume(idx, percent):
    pactl(["set-sink-input-volume", str(idx), f"{percent}%"])

while True:
    try:
        inputs = list_inputs()
        ids = {x["id"] for x in inputs}
        voice_active = any(x["voice"] for x in inputs)
        if voice_active:
            for x in inputs:
                if x["voice"]:
                    continue
                if x["id"] not in volume_before:
                    volume_before[x["id"]] = x["volume"]
                set_volume(x["id"], DUCK_PERCENT)
        else:
            for idx, old_percent in list(volume_before.items()):
                if idx in ids:
                    set_volume(idx, old_percent)
                volume_before.pop(idx, None)
        for idx in list(volume_before.keys()):
            if idx not in ids:
                volume_before.pop(idx, None)
    except Exception as e:
        print(f"room-ducker error: {e}", flush=True)
    time.sleep(0.25)
DUCKER_EOF
sudo chmod +x /usr/local/bin/room-ducker

cat > /tmp/room-ducker.service <<DUCKSVC_EOF
[Unit]
Description=Room audio ducking daemon (${ROOM_NAME})
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=simple
Environment=ROOM_DUCK_PERCENT=${DUCK_LEVEL}
ExecStart=/usr/local/bin/room-ducker
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
DUCKSVC_EOF
sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/room-ducker.service "${USER_SYSTEMD_DIR}/room-ducker.service"
rm -f /tmp/room-ducker.service

log "Create helper commands"
AIRPLAY_START_LINE=""
AIRPLAY_STOP_SERVICE=""
AIRPLAY_STATUS_SERVICE=""
AIRPLAY_LABEL=""
if [[ "$INSTALL_AIRPLAY" == "1" ]]; then
  AIRPLAY_START_LINE='uctl start shairport-sync-user.service || true'
  AIRPLAY_STOP_SERVICE='shairport-sync-user.service'
  AIRPLAY_STATUS_SERVICE='shairport-sync-user.service'
  AIRPLAY_LABEL=' + AirPlay'
fi

sudo tee /usr/local/bin/audio-mode >/dev/null <<AUDIOMODE_EOF
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${CURRENT_USER}"
USER_ID="${USER_ID}"
export XDG_RUNTIME_DIR="/run/user/\${USER_ID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\${XDG_RUNTIME_DIR}/bus"
uctl() {
  if [[ "\$(id -u)" == "\${USER_ID}" ]]; then
    XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS}" systemctl --user "\$@"
  else
    sudo -u "\${USER_NAME}" XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS}" systemctl --user "\$@"
  fi
}
case "\${1:-}" in
  spotify)
    uctl stop snapclient-room.service || true
    uctl start spotify-connect.service
    ${AIRPLAY_START_LINE}
    echo "Spotify${AIRPLAY_LABEL} receiver mode enabled. Snapcast stopped."
    ;;
  airplay)
    uctl stop snapclient-room.service spotify-connect.service || true
    ${AIRPLAY_START_LINE}
    echo "AirPlay mode enabled. Spotify/Snapcast stopped."
    ;;
  receivers|local)
    uctl stop snapclient-room.service || true
    uctl start spotify-connect.service
    ${AIRPLAY_START_LINE}
    echo "Local receivers enabled: Spotify${AIRPLAY_LABEL}."
    ;;
  multiroom|snapcast)
    uctl stop spotify-connect.service ${AIRPLAY_STOP_SERVICE} || true
    uctl start snapclient-room.service
    echo "Snapcast multiroom mode enabled. Local receivers stopped."
    ;;
  all)
    uctl start spotify-connect.service snapclient-room.service room-ducker.service wyoming-satellite-room.service
    ${AIRPLAY_START_LINE}
    echo "All receivers started. PipeWire can mix, but accidental overlapping audio is possible."
    ;;
  off)
    uctl stop spotify-connect.service snapclient-room.service ${AIRPLAY_STOP_SERVICE} || true
    echo "Playback receivers stopped. Wyoming and ducking still running."
    ;;
  voice-restart)
    uctl restart wyoming-satellite-room.service room-ducker.service
    echo "Voice/ducking restarted."
    ;;
  status)
    uctl status spotify-connect.service snapclient-room.service ${AIRPLAY_STATUS_SERVICE} wyoming-satellite-room.service room-ducker.service --no-pager --full || true
    ;;
  *)
    echo "Usage: audio-mode {spotify|airplay|receivers|multiroom|all|off|voice-restart|status}"
    exit 1
    ;;
esac
AUDIOMODE_EOF
sudo chmod +x /usr/local/bin/audio-mode

sudo tee /usr/local/bin/room-node-diag >/dev/null <<DIAG_EOF
#!/usr/bin/env bash
set -euo pipefail
USER_NAME="${CURRENT_USER}"
USER_ID="${USER_ID}"
export XDG_RUNTIME_DIR="/run/user/\${USER_ID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=\${XDG_RUNTIME_DIR}/bus"
echo "=== room-node config ==="
cat /etc/room-node.conf 2>/dev/null || true
echo
echo "=== hostname ==="
hostnamectl || true
echo
echo "=== disk ==="
df -h || true
echo
echo "=== throttling / undervoltage ==="
vcgencmd get_throttled 2>/dev/null || true
echo
echo "=== ALSA capture devices ==="
arecord -L || true
echo
echo "=== ALSA playback devices ==="
aplay -L || true
echo
echo "=== PipeWire status ==="
sudo -u "\${USER_NAME}" XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS}" wpctl status || true
echo
echo "=== Pulse/PipeWire sink inputs ==="
sudo -u "\${USER_NAME}" XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS}" pactl list short sink-inputs || true
echo
echo "=== services ==="
sudo -u "\${USER_NAME}" XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR}" DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS}" systemctl --user --no-pager --full status spotify-connect.service snapclient-room.service ${AIRPLAY_STATUS_SERVICE} wyoming-satellite-room.service room-ducker.service || true
DIAG_EOF
sudo chmod +x /usr/local/bin/room-node-diag

sudo tee /etc/room-node.conf >/dev/null <<CONF_EOF
ROOM_NAME="${ROOM_NAME}"
ROOM_SAFE="${ROOM_SAFE}"
HA_HOST="${HA_HOST}"
MIC_DEVICE="${MIC_DEVICE}"
DUCK_LEVEL="${DUCK_LEVEL}"
AIRPLAY="${INSTALL_AIRPLAY}"
BLUETOOTH="${INSTALL_BLUETOOTH}"
SNAP_PLAYER_ARGS="${SNAP_PLAYER_ARGS}"
LIBRESPOT_BIN="${LIBRESPOT_BIN}"
CONF_EOF

log "Enable and start user services"
if [[ -S "${USER_RUNTIME}/bus" ]]; then
  userctl daemon-reload || true
  userctl enable --now pipewire.service pipewire-pulse.service wireplumber.service || true
  userctl enable spotify-connect.service snapclient-room.service wyoming-satellite-room.service room-ducker.service || true
  if [[ "$INSTALL_AIRPLAY" == "1" ]]; then userctl enable shairport-sync-user.service || true; fi
  userctl stop snapclient-room.service >/dev/null 2>&1 || true
  userctl restart spotify-connect.service wyoming-satellite-room.service room-ducker.service || true
  if [[ "$INSTALL_AIRPLAY" == "1" ]]; then userctl restart shairport-sync-user.service || true; fi
else
  echo "WARNING: user bus unavailable; reboot, then run: audio-mode status"
fi

log "Install complete"
echo "Spotify Connect target: ${ROOM_NAME}"
if [[ "$INSTALL_AIRPLAY" == "1" ]]; then echo "AirPlay target:         ${ROOM_NAME} AirPlay"; fi
echo "Wyoming satellite:     ${ROOM_NAME} on port 10700"
echo "Snapcast client ID:    ${ROOM_SAFE}"
echo
echo "Commands:"
echo "  audio-mode spotify       # Spotify/AirPlay local receiver mode"
echo "  audio-mode multiroom     # Snapcast grouped playback mode"
echo "  audio-mode airplay       # AirPlay only"
echo "  audio-mode all           # allow all sources to mix"
echo "  audio-mode status"
echo "  room-node-diag"
echo
echo "Home Assistant: Settings -> Devices & services -> add/accept Wyoming Protocol for this satellite."
echo "Recommended now: sudo reboot"
