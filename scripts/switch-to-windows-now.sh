#!/bin/zsh

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/logs/switch-to-windows-now.log}"
DISPLAY_INDEX="${DISPLAY_INDEX:-1}"
INPUT_SOURCE="${INPUT_SOURCE:-15}"
LG_ALT_INPUT_SOURCE="${LG_ALT_INPUT_SOURCE:-0xD0}"
DDC_BACKEND="${DDC_BACKEND:-auto}"
DDC_METHOD="${DDC_METHOD:-lg-alt}"
DISPLAY_FIRST="${DISPLAY_FIRST:-0}"
DRY_RUN="${DRY_RUN:-0}"
DDC_COMMAND="${DDC_COMMAND:-}"
LOGI_COMMAND="${LOGI_COMMAND:-}"
LOGI_ENABLED="${LOGI_ENABLED:-1}"
LOGI_TARGET_CHANNEL="${LOGI_TARGET_CHANNEL:-1}"
BETTERDISPLAY_PATH="${BETTERDISPLAY_PATH:-/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay}"

usage() {
  cat <<'EOF'
Usage: scripts/switch-to-windows-now.sh [options]

Options:
  --display N          ddcctl display index. Default: 1
  --input N            Standard DDC input source value. Default: 15 (0x0f, DP1)
  --lg-alt-input N     LG alternate input source value. Default: 0xD0 (DP1)
  --backend NAME       auto, betterdisplay, or ddcctl. Default: auto
  --method NAME        lg-alt or standard. Default: lg-alt
  --ddc-command CMD    Custom display switch command.
  --logi-command CMD   Optional Logitech switch command.
  --no-logi            Skip Logitech switch.
  --logi-channel N     Logitech Easy-Switch target channel. Default: 1.
  --display-first      Switch display before running Logitech command.
  --dry-run            Print commands without executing them.
  -h, --help           Show this help.

Environment variables with the same names are also supported:
  DISPLAY_INDEX, INPUT_SOURCE, LG_ALT_INPUT_SOURCE, DDC_BACKEND, DDC_METHOD,
  DDC_COMMAND, LOGI_COMMAND, LOGI_ENABLED, LOGI_TARGET_CHANNEL,
  DISPLAY_FIRST, DRY_RUN, LOG_PATH

Examples:
  scripts/switch-to-windows-now.sh
  scripts/switch-to-windows-now.sh --method standard --input 15
  scripts/switch-to-windows-now.sh --method lg-alt --lg-alt-input 0xD0
  LOGI_COMMAND='hidapitester ...' scripts/switch-to-windows-now.sh
  DDC_COMMAND='/opt/homebrew/bin/ddcctl -d 1 -i 15' scripts/switch-to-windows-now.sh
EOF
}

log() {
  local level="$1"
  shift
  local message="$*"
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
  mkdir -p "$(dirname "$LOG_PATH")"
  printf '%s\n' "$line" >> "$LOG_PATH"
  printf '%s\n' "$line"
}

run_shell_command() {
  local label="$1"
  local command="$2"

  if [[ -z "$command" ]]; then
    log "WARN" "$label command is empty; skipped"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "ACTION" "dry run: $command"
    return 0
  fi

  log "ACTION" "$label: $command"
  /bin/zsh -lc "$command"
  local exit_code=$?
  log "ACTION" "$label exit code: $exit_code"
  return "$exit_code"
}

switch_display() {
  if [[ -n "$DDC_COMMAND" ]]; then
    run_shell_command "display switch" "$DDC_COMMAND"
    return $?
  fi

  if [[ "$DDC_BACKEND" == "auto" && -x "$BETTERDISPLAY_PATH" ]]; then
    DDC_BACKEND="betterdisplay"
  elif [[ "$DDC_BACKEND" == "auto" ]]; then
    DDC_BACKEND="ddcctl"
  fi

  if [[ "$DDC_BACKEND" == "betterdisplay" ]]; then
    if [[ "$DDC_METHOD" == "lg-alt" ]]; then
      run_shell_command "display switch" "\"$BETTERDISPLAY_PATH\" set --ddcAlt=$LG_ALT_INPUT_SOURCE --vcp=inputSelectAlt"
    elif [[ "$DDC_METHOD" == "standard" ]]; then
      run_shell_command "display switch" "\"$BETTERDISPLAY_PATH\" set --ddc=$INPUT_SOURCE --vcp=inputSelect"
    else
      log "ERROR" "Unknown DDC method: $DDC_METHOD"
      return 2
    fi
    return $?
  fi

  if [[ "$DDC_BACKEND" != "ddcctl" ]]; then
    log "ERROR" "Unknown DDC backend: $DDC_BACKEND"
    return 2
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    run_shell_command "display switch" "ddcctl -d $DISPLAY_INDEX -i $INPUT_SOURCE"
    return $?
  fi

  if ! command -v ddcctl >/dev/null 2>&1; then
    log "ERROR" "ddcctl not found. Install it with: brew install ddcctl"
    log "ERROR" "Or pass a custom command with --ddc-command or DDC_COMMAND."
    return 127
  fi

  local ddcctl_path
  ddcctl_path="$(command -v ddcctl)"
  run_shell_command "display switch" "$ddcctl_path -d $DISPLAY_INDEX -i $INPUT_SOURCE"
}

switch_logitech() {
  if [[ "$LOGI_ENABLED" != "1" ]]; then
    log "WARN" "Logitech switch disabled; skipped."
    return 0
  fi

  if [[ -z "$LOGI_COMMAND" ]]; then
    local default_logi="$ROOT_DIR/scripts/switch-logitech-to-windows-macos.sh --target-channel $LOGI_TARGET_CHANNEL"
    run_shell_command "Logitech switch" "$default_logi"
    local exit_code=$?
    if [[ "$exit_code" -ne 0 ]]; then
      log "WARN" "Logitech switch reported errors; continuing to display switch."
    fi
    return 0
  fi

  run_shell_command "Logitech switch" "$LOGI_COMMAND"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --display)
      DISPLAY_INDEX="$2"
      shift 2
      ;;
    --input)
      INPUT_SOURCE="$2"
      shift 2
      ;;
    --lg-alt-input)
      LG_ALT_INPUT_SOURCE="$2"
      shift 2
      ;;
    --backend)
      DDC_BACKEND="$2"
      shift 2
      ;;
    --method)
      DDC_METHOD="$2"
      shift 2
      ;;
    --ddc-command)
      DDC_COMMAND="$2"
      shift 2
      ;;
    --logi-command)
      LOGI_COMMAND="$2"
      shift 2
      ;;
    --no-logi)
      LOGI_ENABLED="0"
      shift
      ;;
    --logi-channel)
      LOGI_TARGET_CHANNEL="$2"
      shift 2
      ;;
    --display-first)
      DISPLAY_FIRST="1"
      shift
      ;;
    --dry-run)
      DRY_RUN="1"
      shift
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

log "INFO" "manual switch to Windows started"
log "INFO" "display=$DISPLAY_INDEX input=$INPUT_SOURCE lg_alt_input=$LG_ALT_INPUT_SOURCE backend=$DDC_BACKEND method=$DDC_METHOD display_first=$DISPLAY_FIRST dry_run=$DRY_RUN"

display_ok=0
logi_ok=0

if [[ "$DISPLAY_FIRST" == "1" ]]; then
  switch_display
  display_ok=$?
  switch_logitech
  logi_ok=$?
else
  switch_logitech
  logi_ok=$?
  switch_display
  display_ok=$?
fi

if [[ "$display_ok" -eq 0 && "$logi_ok" -eq 0 ]]; then
  log "ACTION" "manual switch to Windows finished"
  exit 0
fi

log "ERROR" "manual switch to Windows finished with errors: logitech=$logi_ok display=$display_ok"
exit 1
