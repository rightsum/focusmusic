#!/bin/bash
set -e

PLIST="$HOME/Library/LaunchAgents/com.rightsum.nikmusic.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/com.rightsum.focusmusic.plist"

echo "🛑 Stopping Nik-Music..."
launchctl unload "$PLIST" 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$OLD_PLIST"
rm -f ~/.local/bin/NikMusic
rm -f ~/.local/bin/NikMusicMCP
rm -f ~/.local/bin/FocusMusic
rm -f ~/.nikmusic.json
rm -f ~/.focusmusic.json

echo "✅ Uninstalled."
