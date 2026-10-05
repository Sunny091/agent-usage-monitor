#!/bin/zsh
# One-click installer for Agent usage monitor.
# Builds the app from source, installs it to ~/Applications and starts it at every login.
#
#   ./install.sh                # asks whether to enable usage limits
#   ./install.sh --with-limits  # enable usage limits (reads local Claude Code / Codex login)
#   ./install.sh --privacy      # status-only mode, never reads any credentials
set -e
cd "$(dirname "$0")"

BUNDLE_ID="io.github.agent-usage-monitor"
APP="$HOME/Applications/AgentUsageMonitor.app"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

bold() { print -P "%B$1%b"; }

# --- Checks -----------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  echo "This app only runs on macOS."; exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  bold "Swift compiler not found. Installing Xcode Command Line Tools…"
  xcode-select --install || true
  echo "Re-run ./install.sh after the Command Line Tools installation finishes."
  exit 1
fi

# --- Mode ---------------------------------------------------------------------
MODE=""
case "$1" in
  --with-limits) MODE=yes ;;
  --privacy)     MODE=no ;;
esac
if [[ -z "$MODE" ]]; then
  echo
  bold "Show usage limits (5-hour / weekly %)?"
  echo "  To show them, the app reads the login that Claude Code / Codex already saved on"
  echo "  this Mac and sends it ONLY to Anthropic / OpenAI's official usage endpoints."
  echo "  Nothing is stored, logged or sent anywhere else. You can change this later in the app."
  echo "  If you answer no, the app only shows the public service status pages."
  read "ans?Enable usage limits? [y/N] "
  [[ "$ans" == [yY]* ]] && MODE=yes || MODE=no
fi
if [[ "$MODE" == yes ]]; then
  defaults write "$BUNDLE_ID" usageLimitsEnabled -bool YES
else
  defaults write "$BUNDLE_ID" usageLimitsEnabled -bool NO
fi

# --- Remove the old "AgentUsageBar" install, if any ---------------------------
for OLD in io.github.agent-usage-bar local.agent-usage-bar; do
  launchctl bootout "gui/$(id -u)/$OLD" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$OLD.plist"
done
rm -rf "$HOME/Applications/AgentUsageBar.app"

# --- Build --------------------------------------------------------------------
bold "Building…"
mkdir -p build
xcrun swiftc -O Sources/main.swift -o build/AgentUsageMonitor -framework AppKit -framework SwiftUI

# --- Install ------------------------------------------------------------------
bold "Installing to $APP"
mkdir -p "$APP/Contents/MacOS"
cp build/AgentUsageMonitor "$APP/Contents/MacOS/AgentUsageMonitor"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>AgentUsageMonitor</string>
  <key>CFBundleDisplayName</key><string>Agent usage monitor</string>
  <key>CFBundleExecutable</key><string>AgentUsageMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# --- Launch at login ------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AgentUsageMonitor</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
bold "✓ Installed. Look at the right side of your menu bar."
echo "  It starts automatically at login. Uninstall with ./uninstall.sh"
