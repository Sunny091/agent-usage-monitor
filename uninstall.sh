#!/bin/zsh
# Removes Agent Usage Bar, its login item and its preferences.
BUNDLE_ID="io.github.agent-usage-bar"
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
pkill -x AgentUsageBar 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
rm -rf "$HOME/Applications/AgentUsageBar.app"
defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "Uninstalled."
