#!/bin/zsh
# Removes Agent usage monitor, its login item and its preferences.
BUNDLE_ID="io.github.agent-usage-monitor"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x AgentUsageMonitor 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "$HOME/Applications/AgentUsageMonitor.app"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "Uninstalled."
