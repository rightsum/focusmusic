#!/bin/bash
set -e

REPO="rightsum/nik-music"
BIN_DIR="$HOME/.local/bin"

# Detect install mode: if main.swift sits next to this script, we're in a clone.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/main.swift" ]; then
    MODE="source"
else
    MODE="release"
fi

mkdir -p "$BIN_DIR"

if [ "$MODE" = "source" ]; then
    echo "🔨 Building Nik-Music from source..."
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "❌ swiftc not found. Install Xcode CLT: xcode-select --install"
        exit 1
    fi
    mkdir -p "$SCRIPT_DIR/build"
    swiftc -O \
        -framework Cocoa -framework CoreAudio -framework AVFoundation \
        -framework MediaPlayer -framework Network \
        "$SCRIPT_DIR/main.swift" "$SCRIPT_DIR/mcp-server.swift" \
        -o "$SCRIPT_DIR/build/NikMusic"
    cp "$SCRIPT_DIR/build/NikMusic" "$BIN_DIR/NikMusic"
else
    echo "⬇️  Downloading latest release..."
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -E '"browser_download_url".*"NikMusic"' \
        | head -1 | cut -d '"' -f 4)
    if [ -z "$URL" ]; then
        echo "❌ No release binary found for $REPO."
        echo "   Either no release exists yet, or there's no asset named 'NikMusic'."
        echo "   Clone the repo and re-run this script to build from source."
        exit 1
    fi
    curl -fsSL --progress-bar -o "$TMP/NikMusic" "$URL"
    chmod +x "$TMP/NikMusic"
    cp "$TMP/NikMusic" "$BIN_DIR/NikMusic"
fi

# Strip Gatekeeper quarantine so the LaunchAgent can run the unsigned binary.
xattr -dr com.apple.quarantine "$BIN_DIR/NikMusic" 2>/dev/null || true

echo "📁 Creating music folder..."
mkdir -p ~/Music/Focus

echo "📝 Creating default config..."
if [ ! -f ~/.nikmusic.json ]; then
    echo '{"source":"local","shuffle":true}' > ~/.nikmusic.json
fi

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
echo "🤖 MCP Server: click the menu bar icon → MCP Server → Start MCP Server"
echo "   Then Copy MCP Config to paste into Claude Desktop, Cursor, or LM Studio"
echo ""
echo "📱 Switch sources from the menu bar: Local Files / Spotify"
echo "🛠️  Config file: ~/.nikmusic.json"
echo "📋 Logs: tail -f ~/.nikmusic.log"
