# .pi — Pi Coding Agent Context

## Project

**Nik-Music** — A macOS menu-bar utility that automatically plays music when headphones are connected, and pauses during calls.

## Current State

### Architecture

- **Main app** (`main.swift`): AppKit + CoreAudio + AVFoundation + MediaPlayer
- **MCP server** (`mcp-server.swift`): Separate binary implementing Model Context Protocol for AI control
- **2 backends**: `LocalBackend` (AVAudioPlayer) + `SpotifyBackend` (AppleScript + optional Web API)
- **Config**: `~/.nikmusic.json`
- **Zero permissions**: no Accessibility needed

### Key Files

| File | Purpose |
|------|---------|
| `main.swift` | Main app source (~800 lines) |
| `mcp-server.swift` | MCP server for AI control (~450 lines) |
| `build/NikMusic` | Main binary |
| `build/NikMusicMCP` | MCP server binary |
| `install.sh` | Build + install both binaries + LaunchAgent |
| `uninstall.sh` | Clean removal |

### MCP Server

- Implements MCP JSON-RPC 2.0 over stdio
- Tools: `get_status`, `set_source`, `set_spotify_search`, `set_spotify_uri`, `set_spotify_api_credentials`, `play`, `pause`, `next_track`, `previous_track`, `set_config`
- Direct AppleScript control for immediate Spotify playback
- Config reload on every `play()` call in main app
- No network ports, no external data sharing

### Known Issues / TODO

- [ ] `NSUserNotification` deprecated; migrate to `UserNotifications.framework`
- [ ] Could be wrapped as proper `.app` bundle
- [ ] Media key conflicts with other "Now Playing" apps
- [ ] No volume control from app
- [ ] No playlist persistence in local mode
- [ ] No support for Apple Music / Tidal

### Etymology

**Nik** (نیک) — Persian for "good," "virtuous." From Zoroastrian *Humata, Hukhta, Huvarshta*.
