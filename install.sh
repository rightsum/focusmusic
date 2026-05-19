#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
BINARY="$BUILD_DIR/FocusMusic"

echo "🔨 Building FocusMusic..."
mkdir -p "$BUILD_DIR"
swiftc -framework Cocoa -framework CoreAudio -framework AVFoundation -framework MediaPlayer "$PROJECT_DIR/main.swift" -o "$BINARY"

echo "📁 Creating music folder..."
mkdir -p ~/Music/Focus

echo "📝 Creating default config..."
if [ ! -f ~/.focusmusic.json ]; then
    echo '{"source":"local","shuffle":true}' > ~/.focusmusic.json
fi

echo "📦 Installing binary to ~/.local/bin..."
mkdir -p ~/.local/bin
cp "$BINARY" ~/.local/bin/FocusMusic

echo "🚀 Installing LaunchAgent..."
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"

PLIST_PATH="$LAUNCH_AGENTS/com.rightsum.focusmusic.plist"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rightsum.focusmusic</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/FocusMusic</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>/tmp/focusmusic.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/focusmusic.err.log</string>
</dict>
</plist>
EOF

echo "🔁 Loading agent..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH" 2>/dev/null || true

echo ""
echo "✅ FocusMusic installed and running!"
echo ""
echo "🎵 Add music files to: ~/Music/Focus"
echo "🎧 Plug in your headphones to test it"
echo "⏯️  Control playback from the menu bar icon"
echo ""
echo "📱 Switch sources from the menu bar: Local Files / Spotify / YouTube Music"
echo "🛠️  Config file: ~/.focusmusic.json"
echo ""
echo "📋 Logs: tail -f ~/.focusmusic.log"
