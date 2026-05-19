#!/bin/bash
# Helper script to guide user through granting Accessibility permissions to FocusMusic

BINARY="$HOME/.local/bin/FocusMusic"

if [ ! -f "$BINARY" ]; then
    echo "❌ FocusMusic binary not found at $BINARY"
    echo "Run ./install.sh first."
    exit 1
fi

echo "🔐 FocusMusic needs Accessibility permissions to control YouTube Music."
echo ""
echo "Here's what to do:"
echo ""
echo "1. System Settings will open now → Privacy & Security → Accessibility"
echo "2. Click the '+' button at the bottom"
echo "3. Press Cmd+Shift+G and paste: ~/.local/bin"
echo "4. Select 'FocusMusic' and click 'Open'"
echo "5. Check the box next to FocusMusic"
echo "6. You may need to quit and restart FocusMusic"
echo ""

# Create a temporary alias/shortcut that appears in normal folders
# so the user doesn't have to navigate hidden paths
TMP_ALIAS="/tmp/FocusMusic (for Accessibility).app"
rm -rf "$TMP_ALIAS" 2>/dev/null
mkdir -p "$TMP_ALIAS"
cat > "$TMP_ALIAS/FocusMusic" <<EOF
#!/bin/bash
exec "$HOME/.local/bin/FocusMusic" "\$@"
EOF
chmod +x "$TMP_ALIAS/FocusMusic"

echo "📂 A temporary folder has been created at:"
echo "   $TMP_ALIAS"
echo "   You can also select 'FocusMusic' from there in the file picker."
echo ""

read -p "Press Enter to open System Settings..."

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
