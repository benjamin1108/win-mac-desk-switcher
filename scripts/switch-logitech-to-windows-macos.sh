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
CHECK_ONLY=0
LOGI_TRANSPORT="${LOGI_TRANSPORT:-receiver}"
RECEIVER_VIDPID="${RECEIVER_VIDPID:-046D:C548}"
RECEIVER_PRODUCT="${RECEIVER_PRODUCT:-USB Receiver}"
RECEIVER_USAGE="${RECEIVER_USAGE:-0x0001}"
KEYBOARD_SLOT="${KEYBOARD_SLOT:-2}"
MOUSE_SLOT="${MOUSE_SLOT:-3}"
HIDPP_TIMEOUT_MS="${HIDPP_TIMEOUT_MS:-1500}"
KEYBOARD_VIDPID="${KEYBOARD_VIDPID:-046D:B38E}"
MOUSE_VIDPID="${MOUSE_VIDPID:-}"
KEYBOARD_PRODUCT="${KEYBOARD_PRODUCT:-Alto Keys K98M}"
MOUSE_PRODUCT="${MOUSE_PRODUCT:-MX Master 4}"
KEYBOARD_FEATURE_INDEX="${KEYBOARD_FEATURE_INDEX:-0x0A}"
MOUSE_FEATURE_INDEX="${MOUSE_FEATURE_INDEX:-}"
CHANGE_HOST_FUNCTION="${CHANGE_HOST_FUNCTION:-0x12}"
INTER_DEVICE_DELAY="${INTER_DEVICE_DELAY:-3}"

usage() {
  cat <<'EOF'
Usage: scripts/switch-logitech-to-windows-macos.sh [options]

Options:
  --target-channel N       Physical Easy-Switch channel. Default: 1.
  --transport MODE         auto, receiver, or bluetooth. Default: receiver.
  --keyboard-slot N        Logitech receiver HID++ slot for keyboard. Default: 2.
  --mouse-slot N           Logitech receiver HID++ slot for mouse. Default: 3.
  --hidpp-timeout-ms N     Receiver HID++ reply timeout. Default: 1500.
  --probe-receiver         Read online receiver devices, names and host information.
  --check                  Verify both configured devices without switching.
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

Bluetooth requires explicitly verified MOUSE_VIDPID and MOUSE_FEATURE_INDEX.
The previous MX Master 3S Bluetooth defaults are no longer used.
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
  local expected_name="$4"

  local command=(
    "$HID_SEND"
    --receiver-change-host
    --vidpid "$RECEIVER_VIDPID"
    --usage-page 0xff00
    --usage "$RECEIVER_USAGE"
    --product "$RECEIVER_PRODUCT"
    --device "$slot"
    --expect-name "$expected_name"
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
      if [[ "$DRY_RUN" == "1" ]]; then
        log "dry run: probe receiver usage=$usage slot=$device (ping/info only)"
        probe_status=0
        continue
      fi
      if "$HID_SEND" \
        --receiver-ping \
        --vidpid "$RECEIVER_VIDPID" \
        --usage-page 0xff00 \
        --usage "$usage" \
        --product "$RECEIVER_PRODUCT" \
        --device "$device" \
        --timeout-ms "$HIDPP_TIMEOUT_MS"; then
        probe_status=0
        "$HID_SEND" --receiver-info --vidpid "$RECEIVER_VIDPID" \
          --usage-page 0xff00 --usage "$usage" --product "$RECEIVER_PRODUCT" \
          --device "$device" --timeout-ms "$HIDPP_TIMEOUT_MS" || probe_status=1
      fi
    done
  done

  return "$probe_status"
}

hid_send_supports_receiver() {
  [[ -x "$HID_SEND" ]] && "$HID_SEND" --help 2>&1 | grep -q -- '--expect-name'
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

check_receiver_device() {
  local slot="$1"
  local expected_name="$2"
  local command=("$HID_SEND" --receiver-info --vidpid "$RECEIVER_VIDPID"
    --usage-page 0xff00 --usage "$RECEIVER_USAGE" --product "$RECEIVER_PRODUCT"
    --device "$slot" --expect-name "$expected_name" --timeout-ms "$HIDPP_TIMEOUT_MS")
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry run: ${(q)command[@]}"
    return 0
  fi
  "${command[@]}"
}

check_receiver() {
  check_receiver_device "$KEYBOARD_SLOT" "$KEYBOARD_PRODUCT" &&
    check_receiver_device "$MOUSE_SLOT" "$MOUSE_PRODUCT"
}

check_bluetooth_config() {
  if [[ -z "$MOUSE_VIDPID" || -z "$MOUSE_FEATURE_INDEX" ]]; then
    log "Bluetooth is not configured for MX Master 4. Verify MOUSE_VIDPID and MOUSE_FEATURE_INDEX first." >&2
    return 1
  fi
  if [[ "$CHECK_ONLY" == "1" ]]; then
    log "--check currently supports the verified Bolt receiver configuration only." >&2
    return 1
  fi
}

wait_for_host() {
  if [[ "$DRY_RUN" != "1" && "$INTER_DEVICE_DELAY" != "0" ]]; then
    log "Waiting ${INTER_DEVICE_DELAY}s for target host to wake before switching mouse"
    sleep "$INTER_DEVICE_DELAY"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-channel|--transport|--keyboard-slot|--mouse-slot|--hidpp-timeout-ms|--inter-delay)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        log "Missing value for $1" >&2
        exit 2
      fi
      ;;
  esac
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
    --check)
      CHECK_ONLY=1
      shift
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
      [[ -x "$HID_SEND" ]] || build_hid_send
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

case "$LOGI_TRANSPORT" in
  auto|receiver|bluetooth) ;;
  *) log "Transport must be auto, receiver, or bluetooth." >&2; exit 2 ;;
esac
case "$TARGET_CHANNEL" in
  1|2|3) ;;
  *) log "Target channel must be 1, 2, or 3." >&2; exit 2 ;;
esac
if [[ "$KEYBOARD_SLOT" != [1-6] || "$MOUSE_SLOT" != [1-6] || "$KEYBOARD_SLOT" == "$MOUSE_SLOT" ]]; then
  log "Keyboard and mouse slots must be distinct numbers from 1 to 6." >&2
  exit 2
fi
if [[ "$HIDPP_TIMEOUT_MS" != <1-60000> || ! "$INTER_DEVICE_DELAY" =~ '^[0-9]+([.][0-9]+)?$' ]]; then
  log "Invalid timeout or inter-device delay." >&2
  exit 2
fi

if [[ ! -x "$HID_SEND" ]]; then
  build_hid_send
elif [[ "$LOGI_TRANSPORT" != "bluetooth" ]] && ! hid_send_supports_receiver; then
  log "$HID_SEND lacks receiver identity checks; rebuilding"
  build_hid_send
fi

if [[ "$PROBE_RECEIVER" == "1" ]]; then
  probe_receiver
  exit $?
fi

host_index_decimal="$(channel_to_host_index_decimal "$TARGET_CHANNEL")" || exit 2
host_index="$(channel_to_host_index_hex "$TARGET_CHANNEL")" || exit 2

if [[ "$LOGI_TRANSPORT" != "bluetooth" ]]; then
  if check_receiver; then
    [[ "$CHECK_ONLY" == "1" ]] && exit 0
    send_receiver_slot "keyboard" "$KEYBOARD_SLOT" "$host_index_decimal" "$KEYBOARD_PRODUCT" || exit 1
    wait_for_host
    send_receiver_slot "mouse" "$MOUSE_SLOT" "$host_index_decimal" "$MOUSE_PRODUCT"
    exit $?
  fi
  [[ "$LOGI_TRANSPORT" == "receiver" || "$CHECK_ONLY" == "1" ]] && exit 1
  log "Receiver preflight failed; checking explicitly configured Bluetooth devices"
fi

check_bluetooth_config || exit 1
keyboard_payload="$(make_payload "$KEYBOARD_FEATURE_INDEX" "$host_index")"
mouse_payload="$(make_payload "$MOUSE_FEATURE_INDEX" "$host_index")"
send_device "keyboard" "$KEYBOARD_VIDPID" "$KEYBOARD_PRODUCT" "$keyboard_payload" || exit 1
wait_for_host
send_device "mouse" "$MOUSE_VIDPID" "$MOUSE_PRODUCT" "$mouse_payload"
exit $?
