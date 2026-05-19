# .pi — Pi Coding Agent Context

## Project

**Nik-Music** — A macOS menu-bar utility that automatically plays music when headphones are connected, and pauses during calls.

## Current State

Single-file Swift app (`main.swift`) using AppKit + CoreAudio + AVFoundation + MediaPlayer.

### Architecture

- **Protocol-based backends** (`MusicBackend`):
  - `LocalBackend` — `AVAudioPlayer` + shuffled playlist from `~/Music/Focus`
  - `SpotifyBackend` — `NSAppleScript` controlling Spotify desktop app + optional `SpotifyAPIClient` for search auto-play
- **Config system** — JSON at `~/.nikmusic.json`
- **Menu bar** — `NSStatusBar` with Source submenu, play/pause/skip, open folder, quit
- **Headphone detection** — CoreAudio listener + 2s polling fallback
- **Call detection** — Mic usage polling
- **Media keys** — `MPRemoteCommandCenter`
- **LaunchAgent** — `com.rightsum.nikmusic`
- **Logs** — `~/.nikmusic.log`
- **Zero permissions** — no Accessibility needed

### Key Files

| File | Purpose |
|------|---------|
| `main.swift` | Complete source (~800 lines) |
| `build/NikMusic` | Compiled binary |
| `install.sh` | Build + install + LaunchAgent + default config |
| `uninstall.sh` | Remove binary + config + LaunchAgent |
| `assets/` | Screenshots |

### Known Issues / TODO

- [ ] `NSUserNotification` is deprecated; migrate to `UserNotifications.framework`
- [ ] Could be wrapped as a proper `.app` bundle
- [ ] Media key conflicts with Spotify/Apple Music
- [ ] No volume control from the app
- [ ] No playlist persistence in local mode
- [ ] No support for other streaming apps (Apple Music, Tidal, etc.)

### Etymology

**Nik** (نیک) — Persian word meaning "good," "virtuous." From Zoroastrian *Humata, Hukhta, Huvarshta* (Good Thoughts, Good Words, Good Deeds). The app's philosophy: remove friction from your daily music ritual.
