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

SCRIPT_VERSION="2026-05-01.8-resume-raspotify-check"

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
CONFIGURE_INNOMAKER_HAT="1"
DISABLE_ONBOARD_AUDIO="1"
AUTO_REBOOT_AFTER_HAT_CONFIG="0"
RUN_AUDIO_TEST="1"
ROOM_NODE_STATE_DIR="/var/lib/room-node"

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
  --no-innomaker-hat      Do not configure /boot/firmware/config.txt for InnoMaker AMP Pro
  --keep-onboard-audio    Do not add dtparam=audio=off when configuring the HAT
  --auto-reboot           Reboot automatically if HAT boot config changes
  --no-audio-test         Do not offer the post-install speaker test
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
    --no-innomaker-hat) CONFIGURE_INNOMAKER_HAT="0"; shift ;;
    --keep-onboard-audio) DISABLE_ONBOARD_AUDIO="0"; shift ;;
    --auto-reboot) AUTO_REBOOT_AFTER_HAT_CONFIG="1"; shift ;;
    --no-audio-test) RUN_AUDIO_TEST="0"; shift ;;
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

install_resume_helper() {
  sudo tee /usr/local/bin/room-node-resume >/dev/null <<'ROOMNODERESUME_EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/room-node"
COMMAND_FILE="${STATE_DIR}/resume-command"
REASON_FILE="${STATE_DIR}/resume-reason"

if [[ ! -s "$COMMAND_FILE" ]]; then
  echo "No pending room-node install resume command found."
  exit 1
fi

if [[ -s "$REASON_FILE" ]]; then
  echo "Pending room-node install:"
  sed 's/^/  /' "$REASON_FILE"
  echo
fi

echo "Running saved resume command:"
sed 's/^/  /' "$COMMAND_FILE"
echo

exec bash -lc "$(cat "$COMMAND_FILE")"
ROOMNODERESUME_EOF
  sudo chmod +x /usr/local/bin/room-node-resume
}

script_path() {
  readlink -f "$0" 2>/dev/null || printf '%s\n' "$0"
}

rerun_command() {
  local args=(
    --room "$ROOM_NAME"
    --ha "$HA_HOST"
    --duck "$DUCK_LEVEL"
  )
  [[ -n "$MIC_DEVICE" ]] && args+=(--mic-device "$MIC_DEVICE")
  [[ -n "$SET_SINK_ID" ]] && args+=(--sink-id "$SET_SINK_ID")
  [[ "$INSTALL_AIRPLAY" == "0" ]] && args+=(--no-airplay)
  [[ "$INSTALL_BLUETOOTH" == "1" ]] && args+=(--with-bluetooth)
  [[ "$DISABLE_WIFI" == "0" ]] && args+=(--keep-wifi)
  [[ "$DISABLE_BLUETOOTH" == "0" ]] && args+=(--keep-bluetooth)
  [[ "$CONFIGURE_INNOMAKER_HAT" == "0" ]] && args+=(--no-innomaker-hat)
  [[ "$DISABLE_ONBOARD_AUDIO" == "0" ]] && args+=(--keep-onboard-audio)
  [[ "$RUN_AUDIO_TEST" == "0" ]] && args+=(--no-audio-test)
  [[ "$NONINTERACTIVE" == "1" ]] && args+=(--noninteractive)

  printf 'sudo %q' "$(script_path)"
  printf ' %q' "${args[@]}"
  printf '\n'
}

write_resume_state() {
  local reason="$1"
  local tmp_command tmp_reason

  install_resume_helper
  tmp_command="$(mktemp)"
  tmp_reason="$(mktemp)"
  printf '%s\n' "$(rerun_command)" >"$tmp_command"
  printf '%s\n' "$reason" >"$tmp_reason"

  sudo mkdir -p "$ROOM_NODE_STATE_DIR"
  sudo install -o root -g root -m 0644 "$tmp_command" "${ROOM_NODE_STATE_DIR}/resume-command"
  sudo install -o root -g root -m 0644 "$tmp_reason" "${ROOM_NODE_STATE_DIR}/resume-reason"
  rm -f "$tmp_command" "$tmp_reason"
}

clear_resume_state() {
  sudo rm -f "${ROOM_NODE_STATE_DIR}/resume-command" "${ROOM_NODE_STATE_DIR}/resume-reason" 2>/dev/null || true
}

merus_card_present() {
  if [[ -r /proc/asound/cards ]] && grep -Eqi 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro' /proc/asound/cards; then
    return 0
  fi
  if command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -Eqi 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro'; then
    return 0
  fi
  return 1
}

write_innomaker_boot_config() {
  local boot_config="$1"
  local tmp
  tmp="$(mktemp)"

  awk '
    BEGIN { skip=0; pending_blank="" }
    function emit(line) {
      printf "%s%s\n", pending_blank, line
      pending_blank=""
    }
    /^# room-node: BEGIN managed InnoMaker AMP Pro audio$/ { skip=1; pending_blank=""; next }
    /^# room-node: END managed InnoMaker AMP Pro audio$/ { skip=0; pending_blank=""; next }
    skip { next }
    /^[[:space:]]*$/ { pending_blank = pending_blank $0 "\n"; next }
    /^[[:space:]]*dtoverlay=merus-amp[[:space:]]*(#.*)?$/ {
      emit("# room-node moved into managed [all] block: " $0)
      next
    }
    /^[[:space:]]*dtparam=audio=off[[:space:]]*(#.*)?$/ {
      emit("# room-node moved into managed [all] block: " $0)
      next
    }
    { emit($0) }
  ' "$boot_config" >"$tmp"

  {
    echo ""
    echo "# room-node: BEGIN managed InnoMaker AMP Pro audio"
    echo "[all]"
    if [[ "$DISABLE_ONBOARD_AUDIO" == "1" ]]; then
      echo "# Disable Pi PWM/headphone audio so the I2S amplifier becomes the only local playback card."
      echo "dtparam=audio=off"
    else
      echo "# dtparam=audio=off intentionally omitted by --keep-onboard-audio."
    fi
    echo "# InnoMaker HIFI AMP PRO / Infineon MERUS MA12070P."
    echo "dtoverlay=merus-amp"
    echo "# room-node: END managed InnoMaker AMP Pro audio"
  } >>"$tmp"

  if sudo cmp -s "$boot_config" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  sudo cp "$boot_config" "${boot_config}.room-node.bak.$(date +%Y%m%d-%H%M%S)" || true
  sudo install -o root -g root -m 0644 "$tmp" "$boot_config"
  rm -f "$tmp"
  return 0
}

reboot_or_stop_for_hat() {
  local reason="$1"
  write_resume_state "$reason"
  echo
  echo "$reason"
  echo "The InnoMaker/MERUS ALSA card is created by firmware at boot, so it will not show up in PipeWire sink selection until after a reboot."
  echo
  echo "After reboot, rerun:"
  echo "  $(rerun_command)"
  echo "Or run:"
  echo "  sudo room-node-resume"
  echo

  if [[ "$AUTO_REBOOT_AFTER_HAT_CONFIG" == "1" ]]; then
    echo "Rebooting now because --auto-reboot was set."
    sudo reboot
    exit 0
  fi

  if [[ "$NONINTERACTIVE" == "1" || ! -t 0 ]]; then
    echo "Stopping before audio setup so the next run can see the HAT."
    exit 0
  fi

  local answer
  read -rp "Reboot now before choosing audio devices? [Y/n]: " answer
  case "$answer" in
    n|N|no|NO|No)
      echo "Stopping before audio setup. Reboot manually, then rerun the command above."
      exit 0
      ;;
    *)
      sudo reboot
      exit 0
      ;;
  esac
}

log "Room node installer ${SCRIPT_VERSION}"
echo "Room display name: ${ROOM_NAME}"
echo "Hostname:          ${ROOM_SAFE}"
echo "HA/Snapcast host:  ${HA_HOST}"
echo "Linux user:        ${CURRENT_USER}"
echo "Duck level:        ${DUCK_LEVEL}%"
echo "AirPlay:           ${INSTALL_AIRPLAY}"
echo "Bluetooth audio:   ${INSTALL_BLUETOOTH}"
echo "InnoMaker AMP Pro: ${CONFIGURE_INNOMAKER_HAT}"

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


log "InnoMaker AMP Pro / MA12070P HAT boot config"
# Official InnoMaker AMP Pro setup for Raspberry Pi OS Lite is:
#   dtoverlay=merus-amp
# The board powers the Raspberry Pi from its own DC input, so do not also power
# the Pi through USB-C/micro-USB while the HAT is powered.
if [[ "$CONFIGURE_INNOMAKER_HAT" == "1" ]]; then
  BOOT_CONFIG="/boot/firmware/config.txt"
  if [[ ! -f "$BOOT_CONFIG" ]]; then
    BOOT_CONFIG="/boot/config.txt"
  fi

  if [[ ! -f "$BOOT_CONFIG" ]]; then
    echo "WARNING: could not find /boot/firmware/config.txt or /boot/config.txt; skipping HAT overlay."
  else
    if write_innomaker_boot_config "$BOOT_CONFIG"; then
      echo "Installed managed [all] boot config block for dtoverlay=merus-amp."
      if ! merus_card_present; then
        reboot_or_stop_for_hat "HAT boot config changed and the Merus-Amp card is not visible in this boot."
      fi
    else
      echo "Managed dtoverlay=merus-amp boot config already present."
      if ! merus_card_present; then
        reboot_or_stop_for_hat "The Merus-Amp card is still not visible. If this Pi has not rebooted since the overlay was added, reboot first."
      fi
    fi
  fi
else
  echo "Skipping InnoMaker HAT boot overlay config."
fi

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


log "Install Merus/InnoMaker default-output helper"
sudo tee /usr/local/bin/room-audio-default >/dev/null <<'ROOMAUDIODEFAULT_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Tries to make the InnoMaker/MERUS AMP HAT the PipeWire default sink.
# Safe to run repeatedly. If the HAT is not visible yet, it exits without failing.
PREFERRED_RE="${ROOM_PREFERRED_SINK_REGEX:-Merus|MERUS|MA120|ma120|snd_rpi_merus_amp|InnoMaker|innomaker|AMP Pro|Amp Pro|pihat|piHat}"
TRIES="${ROOM_AUDIO_DEFAULT_TRIES:-30}"

for _ in $(seq 1 "$TRIES"); do
  STATUS="$(wpctl status 2>/dev/null || true)"
  ID=""

  while IFS=$'\t' read -r SINK_ID SINK_LINE; do
    [[ -z "${SINK_ID:-}" ]] && continue
    INSPECT="$(wpctl inspect "$SINK_ID" 2>/dev/null || true)"
    if printf '%s\n%s\n' "$SINK_LINE" "$INSPECT" | grep -Eiq "$PREFERRED_RE"; then
      ID="$SINK_ID"
      break
    fi
  done < <(printf '%s\n' "$STATUS" | awk '
    BEGIN { in_audio=0; in_sinks=0 }
    /^Audio$/ { in_audio=1; next }
    /^Video$/ { in_audio=0; in_sinks=0; next }
    in_audio && /Sinks:/ { in_sinks=1; next }
    in_audio && /Sources:/ { in_sinks=0; next }
    in_audio && /Filters:/ { in_sinks=0; next }
    in_audio && /Streams:/ { in_sinks=0; next }
    in_sinks && match($0, /[0-9]+\./) {
      id = substr($0, RSTART, RLENGTH - 1)
      print id "\t" $0
    }
  ')

  if [[ -n "${ID:-}" ]]; then
    echo "Setting default PipeWire sink to ID ${ID} matching ${PREFERRED_RE}"
    wpctl set-default "$ID" || true
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.75 || true
    exit 0
  fi

  sleep 1
done

echo "Preferred InnoMaker/MERUS PipeWire sink not found. Leaving PipeWire default unchanged."
if [[ -r /proc/asound/cards ]] && grep -Eqi 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro' /proc/asound/cards; then
  echo "Merus ALSA card is present, but WirePlumber has not exposed a matching sink yet."
else
  echo "Merus ALSA card is not present. Confirm dtoverlay=merus-amp is active and rebooted."
fi
exit 0
ROOMAUDIODEFAULT_EOF
sudo chmod +x /usr/local/bin/room-audio-default

log "Install clean audio chooser helpers"
sudo tee /usr/local/bin/room-audio-ls >/dev/null <<'ROOMAUDIOLS_EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "=== SPEAKER OUTPUTS / PipeWire Sinks ==="
echo "Use these IDs ONLY for the 'default speaker output' question."
if command -v wpctl >/dev/null 2>&1; then
  wpctl status 2>/dev/null | awk '
    BEGIN { in_audio=0; in_sinks=0 }
    /^Audio$/ { in_audio=1; next }
    /^Video$/ { in_audio=0; in_sinks=0; next }
    in_audio && /Sinks:/ { in_sinks=1; next }
    in_audio && /Sources:/ { in_sinks=0; next }
    in_audio && /Filters:/ { in_sinks=0; next }
    in_audio && /Streams:/ { in_sinks=0; next }
    in_sinks && match($0, /[0-9]+\./) { print "  " $0 }
  '
else
  echo "  wpctl not installed/running yet."
fi

echo
echo "=== INNOMAKER AMP PRO / ALSA PLAYBACK CARD ==="
if [[ -r /proc/asound/cards ]] && grep -Eqi 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro' /proc/asound/cards; then
  grep -Ei 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro' /proc/asound/cards | sed 's/^/  /'
elif command -v aplay >/dev/null 2>&1 && aplay -l 2>/dev/null | grep -Eqi 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro'; then
  aplay -l 2>/dev/null | grep -Ei 'snd_rpi_merus_amp|merus|ma120|innomaker|amp pro' | sed 's/^/  /'
else
  echo "  Not visible. If dtoverlay=merus-amp was just added, reboot before selecting a speaker sink."
fi

echo
echo "=== MICROPHONES / ALSA capture device strings ==="
echo "Use these full strings ONLY for the Wyoming mic question."
echo "Prefer plughw:... over hw:... because plughw can do format conversion."
if command -v arecord >/dev/null 2>&1; then
  arecord -L 2>/dev/null | awk '
    BEGIN { last="" }
    /^[A-Za-z0-9_:-]+(,DEV=[0-9]+)?$/ {
      last=$0
      next
    }
    /^[[:space:]]/ {
      desc=$0
      l=tolower(last " " desc)
      if (last ~ /^(plughw|hw|sysdefault):/ || l ~ /(respeaker|xvf|arrayuac|seeed|usb|microphone|mic)/) {
        print "  " last "  --" desc
      }
      next
    }
  ' | awk '!seen[$0]++'
else
  echo "  arecord not installed."
fi

echo
echo "=== IGNORE THESE HERE ==="
echo "  Audio > Devices: hardware cards, not what you pick for default playback."
echo "  Video: camera/codec stuff, irrelevant."
echo "  Sources from wpctl: PipeWire capture nodes; useful diagnostically, but this script asks for ALSA mic strings from arecord."
ROOMAUDIOLS_EOF
sudo chmod +x /usr/local/bin/room-audio-ls

sudo tee /usr/local/bin/room-audio-test >/dev/null <<'ROOMAUDIOTEST_EOF'
#!/usr/bin/env bash
set -euo pipefail

DURATION_SECONDS="${1:-2.0}"
WAV_FILE="$(mktemp --suffix=.wav)"
trap 'rm -f "$WAV_FILE"' EXIT

python3 - "$WAV_FILE" "$DURATION_SECONDS" <<'PY'
import math
import struct
import sys
import wave

path = sys.argv[1]
duration = float(sys.argv[2])
rate = 48000
amplitude = 0.22
samples = int(rate * duration)
notes = (440.0, 660.0, 880.0)

with wave.open(path, "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    frames = bytearray()
    for i in range(samples):
        note = notes[min(len(notes) - 1, int(i / max(1, samples / len(notes))))]
        envelope = min(1.0, i / (rate * 0.03), (samples - i) / (rate * 0.04))
        value = int(32767 * amplitude * envelope * math.sin(2 * math.pi * note * i / rate))
        frames.extend(struct.pack("<h", value))
    wav.writeframes(frames)
PY

if command -v pw-play >/dev/null 2>&1; then
  exec pw-play "$WAV_FILE"
elif command -v paplay >/dev/null 2>&1; then
  exec paplay "$WAV_FILE"
elif command -v aplay >/dev/null 2>&1; then
  exec aplay -D default "$WAV_FILE"
else
  echo "ERROR: no supported playback command found: pw-play, paplay, or aplay."
  exit 1
fi
ROOMAUDIOTEST_EOF
sudo chmod +x /usr/local/bin/room-audio-test

sudo tee /usr/local/bin/room-mic-auto >/dev/null <<'ROOMMICAUTO_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Return the best-looking ALSA capture device for a USB ReSpeaker/XVF/Array mic.
# Prefer plughw so arecord can get 16 kHz mono even if hardware exposes another native format.
arecord -L 2>/dev/null | awk '
  /^[A-Za-z0-9_:-]+(,DEV=[0-9]+)?$/ {
    dev=$0
    getline desc
    l=tolower(dev " " desc)
    score=0
    if (dev ~ /^plughw:/) score += 100
    if (dev ~ /^hw:/) score += 50
    if (l ~ /respeaker/) score += 1000
    if (l ~ /xvf/) score += 900
    if (l ~ /arrayuac/) score += 800
    if (l ~ /seeed/) score += 700
    if (l ~ /4-mic|4 mic|mic array|microphone/) score += 300
    if (l ~ /usb/) score += 100
    if (score > 0) print score "\t" dev
  }
' | sort -rn | head -n 1 | cut -f2-
ROOMMICAUTO_EOF
sudo chmod +x /usr/local/bin/room-mic-auto

cat > /tmp/room-audio-default.service <<AUDIODEFAULTSVC_EOF
[Unit]
Description=Set preferred audio output for InnoMaker AMP Pro (${ROOM_NAME})
After=pipewire.service pipewire-pulse.service wireplumber.service
Wants=pipewire.service pipewire-pulse.service wireplumber.service

[Service]
Type=oneshot
Environment="ROOM_PREFERRED_SINK_REGEX=Merus|MERUS|MA120|ma120|snd_rpi_merus_amp|InnoMaker|innomaker|AMP Pro|Amp Pro|pihat|piHat"
ExecStart=/usr/local/bin/room-audio-default
RemainAfterExit=yes

[Install]
WantedBy=default.target
AUDIODEFAULTSVC_EOF
sudo install -o "$CURRENT_USER" -g "$USER_GROUP" -m 0644 /tmp/room-audio-default.service "${USER_SYSTEMD_DIR}/room-audio-default.service"
rm -f /tmp/room-audio-default.service

log "Start PipeWire user services"
if [[ -S "${USER_RUNTIME}/bus" ]]; then
  userctl daemon-reload || true
  userctl enable --now pipewire.service pipewire-pulse.service wireplumber.service || true
else
  echo "WARNING: user systemd bus not present at ${USER_RUNTIME}/bus. Reboot will usually fix this."
fi
sleep 2

if [[ -S "${USER_RUNTIME}/bus" ]]; then
  userctl daemon-reload || true
  userctl enable --now room-audio-default.service || true
  run_as_user '/usr/local/bin/room-audio-default || true'
fi

log "Clean audio chooser"
echo "The installer already tried to auto-select the InnoMaker/MERUS AMP HAT."
echo "Only choose a speaker ID if that auto-selection is wrong."
echo
run_as_user '/usr/local/bin/room-audio-ls || true'

if [[ -z "$SET_SINK_ID" && "$NONINTERACTIVE" != "1" && -S "${USER_RUNTIME}/bus" ]]; then
  echo
  echo "For speaker output, use an ID from SPEAKER OUTPUTS / PipeWire Sinks only."
  echo "Do NOT use Audio > Devices, Sources, Video, or microphone IDs."
  read -rp "Speaker sink ID to force [blank = keep auto/default]: " SET_SINK_ID
fi
if [[ -n "$SET_SINK_ID" && -S "${USER_RUNTIME}/bus" ]]; then
  run_as_user "wpctl set-default '${SET_SINK_ID}' || true"
  run_as_user "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.75 || true"
fi

log "Install Raspotify package for prebuilt librespot"
sudo apt-get -y install curl
RASPOTIFY_INSTALLER="$(mktemp --suffix=.raspotify-install.sh)"
if ! curl -fsSL https://dtcooper.github.io/raspotify/install.sh -o "$RASPOTIFY_INSTALLER"; then
  rm -f "$RASPOTIFY_INSTALLER"
  echo "ERROR: Failed to download Raspotify installer."
  exit 1
fi
if ! grep -Eq 'raspotify|librespot|apt' "$RASPOTIFY_INSTALLER"; then
  rm -f "$RASPOTIFY_INSTALLER"
  echo "ERROR: Downloaded Raspotify installer did not look valid; refusing to execute it."
  exit 1
fi
if ! sh "$RASPOTIFY_INSTALLER"; then
  rm -f "$RASPOTIFY_INSTALLER"
  echo "ERROR: Raspotify installer failed."
  exit 1
fi
rm -f "$RASPOTIFY_INSTALLER"
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

log "Install Wyoming Satellite (basic satellite only, no local VAD/noise extras)"
# Important: do NOT install wyoming-satellite[all] on Raspberry Pi OS Trixie/Python 3.13.
# The optional local VAD/noise stack can pull old numpy wheels and fail. Your HA server
# is doing wake word/STT/TTS anyway, so this room node only needs the basic satellite.
cd "$USER_HOME"
if [[ ! -d "${USER_HOME}/wyoming-satellite/.git" ]]; then
  rm -rf "${USER_HOME}/wyoming-satellite"
  sudo -u "$CURRENT_USER" git clone https://github.com/rhasspy/wyoming-satellite.git "${USER_HOME}/wyoming-satellite"
else
  sudo -u "$CURRENT_USER" bash -lc "cd '${USER_HOME}/wyoming-satellite' && git pull --ff-only || true"
fi
cd "${USER_HOME}/wyoming-satellite"
# Remove any failed venv from a previous run that tried to build numpy/pysilero.
sudo -u "$CURRENT_USER" rm -rf .venv
sudo -u "$CURRENT_USER" python3 -m venv .venv
sudo -u "$CURRENT_USER" .venv/bin/python -m pip install --upgrade pip wheel setuptools
sudo -u "$CURRENT_USER" .venv/bin/python -m pip install \
  --extra-index-url 'https://www.piwheels.org/simple' \
  -f 'https://synesthesiam.github.io/prebuilt-apps/' \
  -e .

log "Wyoming microphone selection"
AUTO_MIC="$(/usr/local/bin/room-mic-auto || true)"
if [[ -n "$AUTO_MIC" ]]; then
  echo "Auto-detected likely ReSpeaker/USB mic:"
  echo "  ${AUTO_MIC}"
else
  echo "No obvious ReSpeaker/USB mic auto-detected."
fi
echo
/usr/local/bin/room-audio-ls || true

if [[ -z "$MIC_DEVICE" && "$NONINTERACTIVE" != "1" ]]; then
  echo
  echo "For the Wyoming mic, use a full ALSA string from MICROPHONES, usually plughw:CARD=...,DEV=0."
  echo "Do NOT enter the numeric PipeWire speaker sink ID here."
  if [[ -n "$AUTO_MIC" ]]; then
    read -rp "Mic ALSA device for Wyoming [${AUTO_MIC}]: " MIC_DEVICE
    MIC_DEVICE="${MIC_DEVICE:-$AUTO_MIC}"
  else
    read -rp "Mic ALSA device for Wyoming [default]: " MIC_DEVICE
    MIC_DEVICE="${MIC_DEVICE:-default}"
  fi
elif [[ -z "$MIC_DEVICE" ]]; then
  MIC_DEVICE="${AUTO_MIC:-default}"
fi

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
install_resume_helper

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
echo "=== pending room-node resume state ==="
if [[ -s /var/lib/room-node/resume-command ]]; then
  echo "Reason:"
  sed 's/^/  /' /var/lib/room-node/resume-reason 2>/dev/null || true
  echo "Command:"
  sed 's/^/  /' /var/lib/room-node/resume-command
else
  echo "No pending resume state."
fi
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
echo "=== OS / kernel ==="
cat /etc/os-release 2>/dev/null || true
uname -a || true
echo
echo "=== clean audio summary ==="
/usr/local/bin/room-audio-ls 2>/dev/null || true
echo
echo "=== /proc/asound/cards ==="
cat /proc/asound/cards 2>/dev/null || true
echo
echo "=== ALSA capture devices - full raw list ==="
arecord -L || true
echo
echo "=== ALSA playback devices - full raw list ==="
aplay -L || true
echo
echo "=== ALSA cards ==="
aplay -l || true
echo
echo "=== InnoMaker/Merus boot config snippets ==="
for config_file in /boot/firmware/config.txt /boot/config.txt; do
  if [[ -f "\$config_file" ]]; then
    echo "--- \${config_file} ---"
    grep -nE "\\[|room-node|merus-amp|dtparam=audio|dtoverlay|i2s" "\$config_file" 2>/dev/null || true
  fi
done
echo
echo "=== loaded device-tree overlays ==="
dtoverlay -l 2>/dev/null || true
echo
echo "=== firmware config strings relevant to audio/overlays ==="
vcgencmd get_config str 2>/dev/null | grep -Ei "overlay|audio|i2s|dtparam|merus|ma120" || true
echo
echo "=== firmware config ints relevant to audio/overlays ==="
vcgencmd get_config int 2>/dev/null | grep -Ei "audio|i2s|dtparam" || true
echo
echo "=== kernel log audio / overlay lines ==="
{
  sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null || true
} | grep -Ei "merus|ma120|snd|asoc|i2s|audio|dtoverlay|device tree|dtparam" | tail -n 200 || true
echo
echo "=== firmware boot log audio / overlay lines ==="
vclog --msg 2>/dev/null | grep -Ei "merus|ma120|snd|asoc|i2s|audio|dtoverlay|device tree|dtparam|failed|error" | tail -n 200 || true
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
CONFIGURE_INNOMAKER_HAT="${CONFIGURE_INNOMAKER_HAT}"
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
  userctl enable room-audio-default.service spotify-connect.service snapclient-room.service wyoming-satellite-room.service room-ducker.service || true
  if [[ "$INSTALL_AIRPLAY" == "1" ]]; then userctl enable shairport-sync-user.service || true; fi
  userctl stop snapclient-room.service >/dev/null 2>&1 || true
  userctl restart room-audio-default.service spotify-connect.service wyoming-satellite-room.service room-ducker.service || true
  if [[ "$INSTALL_AIRPLAY" == "1" ]]; then userctl restart shairport-sync-user.service || true; fi
else
  echo "WARNING: user bus unavailable; reboot, then run: audio-mode status"
fi

clear_resume_state

log "Post-install audio test"
if [[ "$RUN_AUDIO_TEST" != "1" ]]; then
  echo "Skipping speaker test because --no-audio-test was set."
elif [[ "$NONINTERACTIVE" == "1" ]]; then
  echo "Skipping interactive speaker test in --noninteractive mode."
  echo "After reboot/setup, run: room-audio-test"
elif [[ ! -S "${USER_RUNTIME}/bus" ]]; then
  echo "Skipping speaker test because the user PipeWire bus is not available."
  echo "After reboot, run: room-audio-test"
else
  echo "This plays a short three-note tone through the current default speaker sink."
  echo "If the HAT was just configured, this should only run after the reboot gate above has passed."
  read -rp "Play speaker test now? [Y/n]: " AUDIO_TEST_ANSWER
  case "$AUDIO_TEST_ANSWER" in
    n|N|no|NO|No)
      echo "Speaker test skipped. Run later with: room-audio-test"
      ;;
    *)
      run_as_user '/usr/local/bin/room-audio-default || true'
      if run_as_user '/usr/local/bin/room-audio-test'; then
        read -rp "Did you hear the tone from the amplifier speakers? [Y/n]: " AUDIO_TEST_HEARD
        case "$AUDIO_TEST_HEARD" in
          n|N|no|NO|No)
            echo "Run room-node-diag and check the InnoMaker/Merus sections before using this room."
            echo "Common causes: HAT not rebooted after overlay, HAT not powered correctly, or PipeWire did not expose the Merus sink."
            ;;
          *)
            echo "Speaker test confirmed."
            ;;
        esac
      else
        echo "Speaker test failed. Run room-node-diag for detailed audio/HAT diagnostics."
      fi
      ;;
  esac
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
echo "  room-audio-default      # retry setting default sink to the Merus/InnoMaker HAT"
echo "  room-audio-test         # play a short test tone through the default speaker"
echo "  room-node-resume        # continue after the HAT reboot gate if pending"
echo "  room-node-diag"
echo
echo "Home Assistant: Settings -> Devices & services -> add/accept Wyoming Protocol for this satellite."
echo "Recommended now: sudo reboot"
