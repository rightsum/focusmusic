#!/bin/bash
set -e

PLIST="$HOME/Library/LaunchAgents/com.rightsum.focusmusic.plist"

echo "🛑 Stopping FocusMusic..."
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f ~/.local/bin/FocusMusic

echo "✅ Uninstalled."
