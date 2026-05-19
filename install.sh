#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
BINARY="$BUILD_DIR/NikMusic"

echo "🔨 Building Nik-Music..."
mkdir -p "$BUILD_DIR"
swiftc -framework Cocoa -framework CoreAudio -framework AVFoundation -framework MediaPlayer "$PROJECT_DIR/main.swift" -o "$BINARY"

echo "📁 Creating music folder..."
mkdir -p ~/Music/Focus

echo "📝 Creating default config..."
if [ ! -f ~/.nikmusic.json ]; then
    echo '{"source":"local","shuffle":true}' > ~/.nikmusic.json
fi

echo "📦 Installing binary to ~/.local/bin..."
mkdir -p ~/.local/bin
cp "$BINARY" ~/.local/bin/NikMusic

echo "🚀 Installing LaunchAgent..."
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENTS"

PLIST_PATH="$LAUNCH_AGENTS/com.rightsum.nikmusic.plist"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.rightsum.nikmusic</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/NikMusic</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>/tmp/nikmusic.out.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/nikmusic.err.log</string>
</dict>
</plist>
EOF

echo "🔁 Loading agent..."
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH" 2>/dev/null || true

echo ""
echo "✅ Nik-Music installed and running!"
echo ""
echo "🎵 Add music files to: ~/Music/Focus"
echo "🎧 Plug in your headphones to test it"
echo "⏯️  Control playback from the menu bar icon"
echo ""
echo "📱 Switch sources from the menu bar: Local Files / Spotify"
echo "🛠️  Config file: ~/.nikmusic.json"
echo ""
echo "📋 Logs: tail -f ~/.nikmusic.log"
