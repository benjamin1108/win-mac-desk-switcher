#!/bin/zsh

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-切到Windows}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="${APP_PATH:-$DIST_DIR/$APP_NAME.app}"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
BUNDLE_ID="${BUNDLE_ID:-local.win-mac-desk-switcher.to-windows}"
M1DDC_PATH="${M1DDC_PATH:-$(command -v m1ddc || true)}"
ICON_PATH="${ICON_PATH:-$ROOT_DIR/assets/AppIcon.icns}"
SETUP_SETUID="${SETUP_SETUID:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/build-macos-app.sh [options]

Builds a self-contained macOS app bundle for switching from Mac to Windows.

Options:
  --app-name NAME       Bundle display name. Default: 切到Windows
  --dist DIR            Output directory. Default: ./dist
  --app-path PATH       Full output .app path. Overrides --app-name/--dist.
  --m1ddc PATH          m1ddc binary to bundle. Default: first in PATH.
  --icon PATH           .icns file to bundle. Default: ./assets/AppIcon.icns.
  --setuid              Run sudo chown/chmod for bundled hid-send.
  --no-setuid           Do not run sudo chown/chmod. This is the default.
  -h, --help            Show this help.

Environment overrides:
  APP_NAME, DIST_DIR, APP_PATH, BUNDLE_ID, M1DDC_PATH, ICON_PATH, SETUP_SETUID

Output:
  dist/切到Windows.app

Notes:
  The app is ad-hoc signed by default so macOS privacy settings can identify it.
  The bundled IOKit hid-send does not need Homebrew hidapi or a bundled dylib.
  If you explicitly pass --setuid, this script also runs:
    sudo chown root:wheel Contents/Resources/bin/hid-send
    sudo chmod 4755 Contents/Resources/bin/hid-send
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app-name)
      APP_NAME="$2"
      DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
      APP_PATH="$DIST_DIR/$APP_NAME.app"
      shift 2
      ;;
    --dist)
      DIST_DIR="$2"
      APP_PATH="$DIST_DIR/$APP_NAME.app"
      shift 2
      ;;
    --app-path)
      APP_PATH="$2"
      shift 2
      ;;
    --m1ddc)
      M1DDC_PATH="$2"
      shift 2
      ;;
    --icon)
      ICON_PATH="$2"
      shift 2
      ;;
    --setuid)
      SETUP_SETUID="1"
      shift
      ;;
    --no-setuid)
      SETUP_SETUID="0"
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

require_file() {
  local file_path="$1"
  local label="$2"
  if [[ ! -f "$file_path" ]]; then
    printf 'Missing %s: %s\n' "$label" "$file_path" >&2
    exit 1
  fi
}

require_executable() {
  local file_path="$1"
  local label="$2"
  if [[ ! -x "$file_path" ]]; then
    printf 'Missing executable %s: %s\n' "$label" "$file_path" >&2
    exit 1
  fi
}

realpath_for_bundle() {
  local file_path="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$file_path"
  else
    local dir
    local base
    dir="$(cd "$(dirname "$file_path")" && pwd -P)"
    base="$(basename "$file_path")"
    printf '%s/%s\n' "$dir" "$base"
  fi
}

require_file "$ROOT_DIR/tools/hid-send-macos.c" "macOS hid-send source"
require_file "$ROOT_DIR/scripts/switch-to-windows-now.sh" "switch-to-windows script"
require_file "$ROOT_DIR/scripts/switch-logitech-to-windows-macos.sh" "Logitech switch script"
require_executable "$M1DDC_PATH" "m1ddc"
require_file "$ICON_PATH" "app icon"
if ! command -v cc >/dev/null 2>&1; then
  printf 'Missing compiler: cc. Install Xcode Command Line Tools first.\n' >&2
  exit 1
fi

M1DDC_REAL="$(realpath_for_bundle "$M1DDC_PATH")"

printf 'Building %s\n' "$APP_PATH"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/bin" "$RESOURCES_DIR/scripts" "$RESOURCES_DIR/logs" "$FRAMEWORKS_DIR"

cc "$ROOT_DIR/tools/hid-send-macos.c" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$RESOURCES_DIR/bin/hid-send"
cp "$M1DDC_REAL" "$RESOURCES_DIR/bin/m1ddc"
cp "$ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/scripts/switch-to-windows-now.sh" "$RESOURCES_DIR/scripts/switch-to-windows-now.sh"
cp "$ROOT_DIR/scripts/switch-logitech-to-windows-macos.sh" "$RESOURCES_DIR/scripts/switch-logitech-to-windows-macos.sh"
cp "$ROOT_DIR/tools/hid-send-macos.c" "$RESOURCES_DIR/bin/hid-send-macos.c"

chmod 755 "$RESOURCES_DIR/bin/hid-send" "$RESOURCES_DIR/bin/m1ddc"
chmod 755 "$RESOURCES_DIR/scripts/switch-to-windows-now.sh" "$RESOURCES_DIR/scripts/switch-logitech-to-windows-macos.sh"

cat > "$MACOS_DIR/launcher" <<'EOF'
#!/bin/zsh

set -u

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$APP_DIR/Resources"
LOG_DIR="$HOME/Library/Logs/win-mac-desk-switcher"

mkdir -p "$LOG_DIR"

export PATH="$ROOT_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LOG_PATH="$LOG_DIR/switch-to-windows-now.log"

cd "$ROOT_DIR" || exit 1
exec "$ROOT_DIR/scripts/switch-to-windows-now.sh"
EOF

chmod 755 "$MACOS_DIR/launcher"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSInputMonitoringUsageDescription</key>
  <string>需要发送 Logitech HID++ 命令来切换键盘和鼠标的 Easy-Switch 信道。</string>
</dict>
</plist>
EOF

if [[ "$SETUP_SETUID" == "1" ]]; then
  if [[ -t 0 ]]; then
    printf 'Setting root setuid on bundled hid-send. sudo may ask for your password.\n'
    sudo chown root:wheel "$RESOURCES_DIR/bin/hid-send"
    sudo chmod 4755 "$RESOURCES_DIR/bin/hid-send"
  else
    printf 'Skipping root setuid setup because stdin is not a terminal.\n' >&2
    printf 'Run these commands in Terminal before using the app:\n' >&2
    printf '  sudo chown root:wheel %q\n' "$RESOURCES_DIR/bin/hid-send" >&2
    printf '  sudo chmod 4755 %q\n' "$RESOURCES_DIR/bin/hid-send" >&2
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH"
fi

printf 'Verifying bundled dependencies:\n'
otool -L "$RESOURCES_DIR/bin/hid-send"
printf '\nCreated: %s\n' "$APP_PATH"
printf 'Log file when launched: ~/Library/Logs/win-mac-desk-switcher/switch-to-windows-now.log\n'
