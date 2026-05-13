#!/bin/zsh

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${HID_SEND:-}" ]]; then
  if [[ -x "$ROOT_DIR/bin/hid-send-macos" ]]; then
    HID_SEND="$ROOT_DIR/bin/hid-send-macos"
  else
    HID_SEND="$ROOT_DIR/bin/hid-send"
  fi
fi
TARGET_CHANNEL="${TARGET_CHANNEL:-1}"
DRY_RUN="${DRY_RUN:-0}"
PROBE_RECEIVER="${PROBE_RECEIVER:-0}"
LOGI_TRANSPORT="${LOGI_TRANSPORT:-auto}"
RECEIVER_VIDPID="${RECEIVER_VIDPID:-046D:C548}"
RECEIVER_PRODUCT="${RECEIVER_PRODUCT:-USB Receiver}"
RECEIVER_USAGE="${RECEIVER_USAGE:-0x0001}"
KEYBOARD_SLOT="${KEYBOARD_SLOT:-1}"
MOUSE_SLOT="${MOUSE_SLOT:-2}"
HIDPP_TIMEOUT_MS="${HIDPP_TIMEOUT_MS:-1500}"
KEYBOARD_VIDPID="${KEYBOARD_VIDPID:-046D:B38E}"
MOUSE_VIDPID="${MOUSE_VIDPID:-046D:B034}"
KEYBOARD_PRODUCT="${KEYBOARD_PRODUCT:-Alto Keys K98M}"
MOUSE_PRODUCT="${MOUSE_PRODUCT:-MX Master 3S}"
KEYBOARD_FEATURE_INDEX="${KEYBOARD_FEATURE_INDEX:-0x0A}"
MOUSE_FEATURE_INDEX="${MOUSE_FEATURE_INDEX:-0x0A}"
CHANGE_HOST_FUNCTION="${CHANGE_HOST_FUNCTION:-0x12}"
INTER_DEVICE_DELAY="${INTER_DEVICE_DELAY:-3}"

usage() {
  cat <<'EOF'
Usage: scripts/switch-logitech-to-windows-macos.sh [options]

Options:
  --target-channel N       Physical Easy-Switch channel. Default: 1.
  --transport MODE         auto, receiver, or bluetooth. Default: auto.
  --keyboard-slot N        Logitech receiver HID++ slot for keyboard. Default: 3.
  --mouse-slot N           Logitech receiver HID++ slot for mouse. Default: 4.
  --hidpp-timeout-ms N     Receiver HID++ reply timeout. Default: 1500.
  --probe-receiver         Probe receiver usage/device combinations without switching.
  --inter-delay SECONDS    Seconds to wait between keyboard and mouse switch
                           so a sleeping Windows host has time to wake via BT
                           HID before the mouse probes the new channel.
                           Default: 3. Set 0 to disable.
  --dry-run                Print commands without sending HID reports.
  --list                   List HID devices using bin/hid-send.
  -h, --help               Show this help.

Environment overrides:
  LOGI_TRANSPORT, RECEIVER_VIDPID, RECEIVER_PRODUCT, RECEIVER_USAGE, KEYBOARD_SLOT,
  MOUSE_SLOT, HIDPP_TIMEOUT_MS, KEYBOARD_VIDPID, MOUSE_VIDPID,
  KEYBOARD_PRODUCT, MOUSE_PRODUCT,
  KEYBOARD_FEATURE_INDEX, MOUSE_FEATURE_INDEX, CHANGE_HOST_FUNCTION,
  INTER_DEVICE_DELAY, HID_SEND
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

channel_to_host_index_decimal() {
  local channel="$1"
  local host_index=$(( channel - 1 ))
  if (( host_index < 0 || host_index > 2 )); then
    log "Target channel must be 1, 2, or 3." >&2
    return 1
  fi
  printf '%d' "$host_index"
}

make_payload() {
  local feature_index="$1"
  local host_index="$2"
  printf '0x11,0x00,%s,%s,%s,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00' "$feature_index" "$CHANGE_HOST_FUNCTION" "$host_index"
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

send_receiver_slot() {
  local label="$1"
  local slot="$2"
  local target_host_index="$3"

  local command=(
    "$HID_SEND"
    --receiver-change-host
    --vidpid "$RECEIVER_VIDPID"
    --usage-page 0xff00
    --usage "$RECEIVER_USAGE"
    --product "$RECEIVER_PRODUCT"
    --device "$slot"
    --target-host-index "$target_host_index"
    --timeout-ms "$HIDPP_TIMEOUT_MS"
  )

  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry run: ${(q)command[@]}"
    return 0
  fi

  log "Switching $label receiver slot $slot to channel $TARGET_CHANNEL"
  "${command[@]}"
}

probe_receiver() {
  local probe_status=1
  local usage
  local device

  for usage in 0x0001 0x0002; do
    for device in 1 2 3 4 5 6; do
      log "Probing receiver usage=$usage device=$device"
      "$HID_SEND" \
        --receiver-ping \
        --vidpid "$RECEIVER_VIDPID" \
        --usage-page 0xff00 \
        --usage "$usage" \
        --product "$RECEIVER_PRODUCT" \
        --device "$device" \
        --timeout-ms "$HIDPP_TIMEOUT_MS" && probe_status=0
    done
  done

  return "$probe_status"
}

hid_send_supports_receiver() {
  [[ -x "$HID_SEND" ]] && "$HID_SEND" --help 2>&1 | grep -q -- '--receiver-change-host'
}

build_hid_send() {
  if [[ "$(uname -s)" == "Darwin" && -f "$ROOT_DIR/tools/hid-send-macos.c" ]] && command -v cc >/dev/null 2>&1; then
    if [[ "$HID_SEND" == "$ROOT_DIR/bin/hid-send" && -e "$HID_SEND" && ! -w "$HID_SEND" ]]; then
      HID_SEND="$ROOT_DIR/bin/hid-send-macos"
    fi
    log "Building $HID_SEND"
    cc "$ROOT_DIR/tools/hid-send-macos.c" -framework IOKit -framework CoreFoundation -o "$HID_SEND" || exit 1
  elif [[ -f "$ROOT_DIR/tools/hid-send.c" ]] && command -v cc >/dev/null 2>&1; then
    log "Building $HID_SEND"
    cc "$ROOT_DIR/tools/hid-send.c" -I/opt/homebrew/include -L/opt/homebrew/lib -lhidapi -o "$HID_SEND" || exit 1
  else
    log "Missing executable: $HID_SEND" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-channel)
      TARGET_CHANNEL="$2"
      shift 2
      ;;
    --transport)
      LOGI_TRANSPORT="$2"
      shift 2
      ;;
    --keyboard-slot)
      KEYBOARD_SLOT="$2"
      shift 2
      ;;
    --mouse-slot)
      MOUSE_SLOT="$2"
      shift 2
      ;;
    --hidpp-timeout-ms)
      HIDPP_TIMEOUT_MS="$2"
      shift 2
      ;;
    --probe-receiver)
      PROBE_RECEIVER="1"
      shift
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
  build_hid_send
elif [[ "$LOGI_TRANSPORT" == "auto" || "$LOGI_TRANSPORT" == "receiver" ]]; then
  if ! hid_send_supports_receiver; then
    log "$HID_SEND does not support receiver CHANGE_HOST; rebuilding"
    build_hid_send
  fi
fi

if [[ "$PROBE_RECEIVER" == "1" ]]; then
  probe_receiver
  exit $?
fi

case "$LOGI_TRANSPORT" in
  auto|receiver|bluetooth) ;;
  *)
    log "Transport must be auto, receiver, or bluetooth." >&2
    exit 2
    ;;
esac

host_index_decimal="$(channel_to_host_index_decimal "$TARGET_CHANNEL")" || exit 2
host_index="$(channel_to_host_index_hex "$TARGET_CHANNEL")" || exit 2
keyboard_payload="$(make_payload "$KEYBOARD_FEATURE_INDEX" "$host_index")"
mouse_payload="$(make_payload "$MOUSE_FEATURE_INDEX" "$host_index")"

result_status=0

if [[ "$LOGI_TRANSPORT" == "auto" || "$LOGI_TRANSPORT" == "receiver" ]]; then
  receiver_status=0
  send_receiver_slot "keyboard" "$KEYBOARD_SLOT" "$host_index_decimal" || receiver_status=1

  if [[ "$DRY_RUN" != "1" && "$INTER_DEVICE_DELAY" != "0" ]]; then
    log "Waiting ${INTER_DEVICE_DELAY}s for target host to wake before switching mouse"
    sleep "$INTER_DEVICE_DELAY"
  fi

  send_receiver_slot "mouse" "$MOUSE_SLOT" "$host_index_decimal" || receiver_status=1

  if [[ "$receiver_status" -eq 0 || "$LOGI_TRANSPORT" == "receiver" ]]; then
    exit "$receiver_status"
  fi

  log "Receiver switch failed; falling back to Bluetooth direct devices"
fi

send_device "keyboard" "$KEYBOARD_VIDPID" "$KEYBOARD_PRODUCT" "$keyboard_payload" || result_status=1

if [[ "$DRY_RUN" != "1" && "$INTER_DEVICE_DELAY" != "0" ]]; then
  log "Waiting ${INTER_DEVICE_DELAY}s for target host to wake before switching mouse"
  sleep "$INTER_DEVICE_DELAY"
fi

send_device "mouse" "$MOUSE_VIDPID" "$MOUSE_PRODUCT" "$mouse_payload" || result_status=1

exit "$result_status"
