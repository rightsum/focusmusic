# .pi — Pi Coding Agent Context

This folder contains development context for the Pi coding agent.

## Project

**FocusMusic** — A macOS menu-bar utility that automatically plays focus music when headphones are connected, and pauses during calls.

## Current State

- Single-file Swift app (`main.swift`) using AppKit + CoreAudio + AVFoundation + MediaPlayer
- Compiled binary runs as a LaunchAgent (`com.rightsum.focusmusic`)
- Detects headphone connection via CoreAudio output device monitoring + 2s polling fallback
- Detects active calls via microphone usage (`kAudioDevicePropertyDeviceIsRunningSomewhere`)
- Supports media keys: F8 (play/pause), F9 (next), F7 (previous)
- Menu bar icon (🎵/🎧) with play/pause/skip/open-folder/quit
- Logs to `~/.focusmusic.log`

## Key Files

| File | Purpose |
|------|---------|
| `main.swift` | Complete source (≈350 lines) |
| `build/FocusMusic` | Compiled binary |
| `install.sh` | Build + install + LaunchAgent setup |
| `uninstall.sh` | Remove binary + LaunchAgent |
| `assets/` | Screenshots for README |

## Known Issues / TODO

- [ ] `NSUserNotification` is deprecated (macOS 11+); migrate to `UserNotifications.framework`
- [ ] Could be wrapped as a proper `.app` bundle for better GUI session handling
- [ ] Media key conflicts with Spotify/Apple Music when they were the last "Now Playing" app
- [ ] No volume control from the app
- [ ] No playlist persistence (reshuffles on every launch)
- [ ] No support for streaming (Spotify/Apple Music APIs)

## Architecture Decisions

- **Why raw binary + LaunchAgent instead of .app?** Faster to iterate, no Xcode project needed, single-file Swift. Trade-off: macOS sometimes doesn't show menu bar icon for background agents.
- **Why `MPRemoteCommandCenter` for media keys?** It's the official API. Alternative is private SPI (`BezelServices` / `CGEvent.tap`) which is fragile and breaks on OS updates.
- **Why AVAudioPlayer instead of system music apps?** We want standalone, local-file playback without fighting Spotify/Apple Music for the audio session.
