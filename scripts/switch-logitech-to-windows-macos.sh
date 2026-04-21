#!/bin/zsh

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HID_SEND="${HID_SEND:-$ROOT_DIR/bin/hid-send}"
TARGET_CHANNEL="${TARGET_CHANNEL:-1}"
DRY_RUN="${DRY_RUN:-0}"
KEYBOARD_VIDPID="${KEYBOARD_VIDPID:-046D:B38E}"
MOUSE_VIDPID="${MOUSE_VIDPID:-046D:B034}"
KEYBOARD_PRODUCT="${KEYBOARD_PRODUCT:-Alto Keys K98M}"
MOUSE_PRODUCT="${MOUSE_PRODUCT:-MX Master 3S}"
KEYBOARD_FEATURE_INDEX="${KEYBOARD_FEATURE_INDEX:-0x0A}"
MOUSE_FEATURE_INDEX="${MOUSE_FEATURE_INDEX:-0x0A}"
INTER_DEVICE_DELAY="${INTER_DEVICE_DELAY:-3}"

usage() {
  cat <<'EOF'
Usage: scripts/switch-logitech-to-windows-macos.sh [options]

Options:
  --target-channel N       Physical Easy-Switch channel. Default: 1.
  --inter-delay SECONDS    Seconds to wait between keyboard and mouse switch
                           so a sleeping Windows host has time to wake via BT
                           HID before the mouse probes the new channel.
                           Default: 3. Set 0 to disable.
  --dry-run                Print commands without sending HID reports.
  --list                   List HID devices using bin/hid-send.
  -h, --help               Show this help.

Environment overrides:
  KEYBOARD_VIDPID, MOUSE_VIDPID, KEYBOARD_PRODUCT, MOUSE_PRODUCT,
  KEYBOARD_FEATURE_INDEX, MOUSE_FEATURE_INDEX, INTER_DEVICE_DELAY, HID_SEND
EOF
}

log() {
  printf '%s\n' "$*"
}

channel_to_host_index_hex() {
  local channel="$1"
  local host_index=$(( channel - 1 ))
  if (( host_index < 0 || host_index > 2 )); then
    log "Target channel must be 1, 2, or 3." >&2
    return 1
  fi
  printf '0x%02X' "$host_index"
}

make_payload() {
  local feature_index="$1"
  local host_index="$2"
  printf '0x11,0x00,%s,0x1E,%s,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00' "$feature_index" "$host_index"
}

send_device() {
  local label="$1"
  local vidpid="$2"
  local product="$3"
  local payload="$4"

  local command=(
    "$HID_SEND"
    --vidpid "$vidpid"
    --usage-page 0xff43
    --usage 0x0202
    --product "$product"
    --send "$payload"
  )

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry run: ${(q)command[@]}"
    return 0
  fi

  log "Switching $label ($product) to channel $TARGET_CHANNEL"
  "${command[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-channel)
      TARGET_CHANNEL="$2"
      shift 2
      ;;
    --inter-delay)
      INTER_DEVICE_DELAY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
      ;;
    --list)
      "$HID_SEND" --list
      exit $?
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$HID_SEND" ]]; then
  if [[ -f "$ROOT_DIR/tools/hid-send.c" ]] && command -v cc >/dev/null 2>&1; then
    log "Building $HID_SEND"
    cc "$ROOT_DIR/tools/hid-send.c" -I/opt/homebrew/include -L/opt/homebrew/lib -lhidapi -o "$HID_SEND" || exit 1
  else
    log "Missing executable: $HID_SEND" >&2
    exit 1
  fi
fi

host_index="$(channel_to_host_index_hex "$TARGET_CHANNEL")" || exit 2
keyboard_payload="$(make_payload "$KEYBOARD_FEATURE_INDEX" "$host_index")"
mouse_payload="$(make_payload "$MOUSE_FEATURE_INDEX" "$host_index")"

result_status=0
send_device "keyboard" "$KEYBOARD_VIDPID" "$KEYBOARD_PRODUCT" "$keyboard_payload" || result_status=1

if [[ "$DRY_RUN" != "1" && "$INTER_DEVICE_DELAY" != "0" ]]; then
  log "Waiting ${INTER_DEVICE_DELAY}s for target host to wake before switching mouse"
  sleep "$INTER_DEVICE_DELAY"
fi

send_device "mouse" "$MOUSE_VIDPID" "$MOUSE_PRODUCT" "$mouse_payload" || result_status=1

exit "$result_status"
