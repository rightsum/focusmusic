# .pi — Pi Coding Agent Context

## Project

**FocusMusic** — A macOS menu-bar utility that automatically plays focus music when headphones are connected, and pauses during calls.

## Current State

Single-file Swift app (`main.swift`) using AppKit + CoreAudio + AVFoundation + MediaPlayer.

### Architecture

- **Protocol-based backends** (`MusicBackend`):
  - `LocalBackend` — `AVAudioPlayer` + shuffled playlist from `~/Music/Focus`
  - `SpotifyBackend` — `NSAppleScript` controlling Spotify desktop app
  - `YouTubeMusicBackend` — AppleScript `activate` + `System Events` key simulation
- **Config system** — JSON at `~/.focusmusic.json` with `source`, `musicFolder`, `shuffle`
- **Menu bar** — `NSStatusBar` with Source submenu (radio buttons), play/pause/skip, open folder, quit
- **Headphone detection** — CoreAudio listener + 2s polling fallback
- **Call detection** — Mic usage polling (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
- **Media keys** — `MPRemoteCommandCenter` handlers forward to active backend (works for all 3 sources)
- **LaunchAgent** — `com.rightsum.focusmusic` with `LimitLoadToSessionType: Aqua`
- **Logs** — `~/.focusmusic.log`

### Key Files

| File | Purpose |
|------|---------|
| `main.swift` | Complete source (~700 lines) |
| `build/FocusMusic` | Compiled binary |
| `install.sh` | Build + install + LaunchAgent + default config |
| `uninstall.sh` | Remove binary + config + LaunchAgent |
| `assets/` | Screenshots |

### Known Issues / TODO

- [ ] `NSUserNotification` is deprecated (macOS 11+); migrate to `UserNotifications.framework`
- [ ] Could be wrapped as a proper `.app` bundle for better GUI session handling
- [ ] Media key conflicts with Spotify/Apple Music when they were last "Now Playing" app
- [ ] YouTube Music backend is best-effort (no state query, requires Accessibility)
- [ ] No volume control from the app
- [ ] No playlist persistence in local mode (reshuffles on launch)
- [ ] No support for other streaming apps (Apple Music, Tidal, etc.)

### Architecture Decisions

- **Why protocol-based backends?** User wanted configurable support for Spotify and YouTube Music without rewriting the core headphone/call detection logic.
- **Why AppleScript for Spotify?** Spotify has a rich, reliable AppleScript dictionary. Direct and stable.
- **Why System Events key simulation for YouTube Music?** Official YouTube Music Mac app has no AppleScript playback commands. Keyboard shortcuts (Space, Shift+N, Shift+P) are the only reliable programmatic interface.
- **Why not CGEventTap for media keys?** Requires Accessibility permissions and is fragile across macOS versions. `MPRemoteCommandCenter` is the blessed API. By registering handlers once and forwarding to the active backend, we get universal media key support.
- **Why raw binary + LaunchAgent instead of .app?** Faster iteration, no Xcode project. Trade-off: occasional menu bar visibility quirks.
