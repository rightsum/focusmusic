# .pi — Pi Coding Agent Context

## Project

**FocusMusic** — A macOS menu-bar utility that automatically plays focus music when headphones are connected, and pauses during calls.

## Current State

Single-file Swift app (`main.swift`) using AppKit + CoreAudio + AVFoundation + MediaPlayer.

### Architecture

- **Protocol-based backends** (`MusicBackend`):
  - `LocalBackend` — `AVAudioPlayer` + shuffled playlist from `~/Music/Focus`
  - `SpotifyBackend` — `NSAppleScript` controlling Spotify desktop app + optional `SpotifyAPIClient` for search auto-play
- **Config system** — JSON at `~/.focusmusic.json` with `source`, `musicFolder`, `shuffle`, `spotifyUri`, `spotifySearchQuery`, `spotifyClientId`, `spotifyClientSecret`
- **Menu bar** — `NSStatusBar` with Source submenu (radio buttons), play/pause/skip, open folder, quit
- **Headphone detection** — CoreAudio listener + 2s polling fallback
- **Call detection** — Mic usage polling (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
- **Media keys** — `MPRemoteCommandCenter` handlers forward to active backend
- **LaunchAgent** — `com.rightsum.focusmusic` with `LimitLoadToSessionType: Aqua`
- **Logs** — `~/.focusmusic.log`
- **Zero permissions** — no Accessibility, no special entitlements needed

### Key Files

| File | Purpose |
|------|---------|
| `main.swift` | Complete source (~800 lines) |
| `build/FocusMusic` | Compiled binary |
| `install.sh` | Build + install + LaunchAgent + default config |
| `uninstall.sh` | Remove binary + config + LaunchAgent |
| `assets/` | Screenshots |

### Known Issues / TODO

- [ ] `NSUserNotification` is deprecated (macOS 11+); migrate to `UserNotifications.framework`
- [ ] Could be wrapped as a proper `.app` bundle for better GUI session handling
- [ ] Media key conflicts with Spotify/Apple Music when they were last "Now Playing" app
- [ ] No volume control from the app
- [ ] No playlist persistence in local mode (reshuffles on launch)
- [ ] No support for other streaming apps (Apple Music, Tidal, etc.)

### Architecture Decisions

- **Why protocol-based backends?** User wanted configurable support for Spotify without rewriting core headphone/call detection logic.
- **Why AppleScript for Spotify?** Spotify has a rich, reliable AppleScript dictionary. Direct and stable.
- **Why not YouTube Music?** Removed because it required Accessibility permissions and keyboard simulation was flaky. User preferred clean, permission-free experience.
- **Why `MPRemoteCommandCenter` for media keys?** It's the official API. No private SPI needed.
- **Why raw binary + LaunchAgent instead of .app?** Faster iteration, no Xcode project. Trade-off: occasional menu bar visibility quirks.
