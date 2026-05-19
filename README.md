# 🎧 FocusMusic

A tiny macOS menu-bar app that automatically starts playing your focus music when you plug in headphones — and pauses itself if you're in a call. Now configurable to work with **local files**, **Spotify**, or **YouTube Music**.

![Menu Bar](assets/menu-bar.png)

## The Problem

Every day, when I sit down to work and put on my headphones, I have to:

1. Open a music app
2. Navigate to the right playlist
3. Hit play

And if I join a Zoom call with music still playing, it's embarrassing. I wanted something **smarter** — an app that just *knows* when my headphones are on and whether I'm in a call.

## The Solution

FocusMusic is a lightweight native macOS agent that:

- **Detects your headphones** via CoreAudio the moment they connect (wired, Bluetooth, AirPods, etc.)
- **Auto-plays** your chosen music source when headphones connect
- **Pauses during calls** by monitoring microphone usage — when Zoom, Teams, FaceTime, or any app uses your mic, music stops automatically and resumes when the call ends
- **Menu bar control** — see what's playing, pause, skip, switch sources, or open the folder with one click
- **Media keys work** — F8 (play/pause), F9 (next), F7 (previous) control your active source
- **Always on** — runs as a LaunchAgent, starts on login, lives in your status bar

![Background Activity](assets/background-activity.png)

## Supported Music Sources

| Source | How it works | Media keys |
|--------|-------------|------------|
| **Local Files** | Plays `.mp3`/`.m4a`/`.wav`/`.flac` from `~/Music/Focus` via `AVAudioPlayer` | Via `MPRemoteCommandCenter` |
| **Spotify** | Controls Spotify via AppleScript (`play`, `pause`, `next track`) | Routed through FocusMusic to Spotify |
| **YouTube Music** | Activates the app + simulates keyboard shortcuts via AppleScript/System Events | Routed through FocusMusic to YouTube Music |

### Spotify mode

Requires the **Spotify desktop app** to be installed. FocusMusic sends AppleScript commands to control playback, reads the current track name, and detects play/pause state directly from Spotify.

### YouTube Music mode

Requires the official **YouTube Music Mac app** from the App Store. FocusMusic uses AppleScript to activate the app and simulate keyboard shortcuts:
- **Spacebar** — play/pause
- **Shift+N** — next track
- **Shift+P** — previous track

> ⚠️ **YouTube Music requires Accessibility permissions** for `System Events` key simulation. macOS will prompt you the first time. If it doesn't work, go to **System Settings → Privacy & Security → Accessibility** and add `FocusMusic`.

> ⚠️ YouTube Music state tracking is best-effort (we can't query its playback state via AppleScript). If commands feel out of sync, pause/resume manually once.

## Installation

### One-liner

```bash
git clone https://github.com/rightsum/focusmusic.git
cd focusmusic
./install.sh
```

### What `install.sh` does

1. Compiles the Swift app (`main.swift`)
2. Creates `~/Music/Focus` if it doesn't exist
3. Copies the binary to `~/.local/bin/FocusMusic`
4. Creates a default config at `~/.focusmusic.json`
5. Registers a LaunchAgent so it auto-starts on login

### Add your music (Local mode only)

Drop audio files into:

```
~/Music/Focus
```

Supported formats: `.mp3`, `.m4a`, `.wav`, `.aiff`, `.aac`, `.caf`, `.mp4`, `.flac`

Then plug in your headphones. It should detect them, show a notification, and start shuffling.

### Switching music sources

Click the 🎵/🎧 icon in your menu bar, hover over **Source**, and pick:
- **Local Files**
- **Spotify**
- **YouTube Music**

Your choice is saved to `~/.focusmusic.json` and persists across restarts.

### Configuration file

`~/.focusmusic.json`:

```json
{
  "source": "local",
  "musicFolder": "/Users/rightsum/Music/Focus",
  "shuffle": true
}
```

| Field | Description |
|-------|-------------|
| `source` | `"local"`, `"spotify"`, or `"youtubeMusic"` |
| `musicFolder` | Path to local music folder (local mode only) |
| `shuffle` | Shuffle tracks on load (local mode only) |

Edit this file directly or switch sources from the menu bar.

### Uninstall

```bash
./uninstall.sh
```

This removes the binary, config, and LaunchAgent.

## How It Works

### Headphone Detection

The app listens to macOS's default audio output device via CoreAudio. When the device name matches known headphone keywords, it triggers playback. It also polls every 2 seconds as a fallback for Bluetooth reconnects that CoreAudio events sometimes miss.

Keywords include: `headphone`, `airpods`, `earbuds`, `beats`, `bose`, `sony`, `wh-`, `xm5`, `buds`, `bluetooth headset`, and more.

**If your headphones aren't detected**, check `~/.focusmusic.log` for the exact device name and add it to the `headphoneKeywords` array in `main.swift`, then re-run `./install.sh`.

### Call Detection

Every 5 seconds, the app checks if the default input microphone is actively recording (`kAudioDevicePropertyDeviceIsRunningSomewhere`). This covers:

- FaceTime
- Zoom
- Microsoft Teams
- Slack huddles
- Any app using the mic

If a call starts during playback, music pauses immediately with a notification. When the mic goes idle, it resumes (unless you manually paused).

### Media Keys

FocusMusic registers with `MPRemoteCommandCenter`. When you press F8/F9/F7, macOS routes them to FocusMusic, which forwards the command to your active backend:

- **Local mode** → controls `AVAudioPlayer`
- **Spotify mode** → sends AppleScript to Spotify
- **YouTube Music mode** → sends AppleScript keyboard shortcuts to YouTube Music

If another app (Spotify, Apple Music) recently played and is still the system's "Now Playing" app, you may need to click the FocusMusic menu bar icon once to reassert focus.

## Development

### Project Structure

```
.
├── main.swift          # Complete Swift source (~700 lines)
├── install.sh          # Build + install + LaunchAgent setup
├── uninstall.sh        # Clean removal
├── build/              # Compiled binary
├── assets/             # Screenshots
├── .pi/                # Pi agent development context
└── .claude/            # Claude agent development context
```

### Build manually

```bash
swiftc -framework Cocoa -framework CoreAudio -framework AVFoundation -framework MediaPlayer main.swift -o build/FocusMusic
```

### Logs

```bash
# Live debug log
tail -f ~/.focusmusic.log

# LaunchAgent stdout/stderr
tail -f /tmp/focusmusic.out.log
tail -f /tmp/focusmusic.err.log
```

### Managing the service

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.rightsum.focusmusic.plist

# Start
launchctl load ~/Library/LaunchAgents/com.rightsum.focusmusic.plist

# Check if running
ps aux | grep FocusMusic
```

## Architecture

- **Language**: Swift (AppKit + CoreAudio + AVFoundation + MediaPlayer)
- **UI**: `NSStatusBar` menu-only app, no dock icon
- **Persistence**: `launchd` LaunchAgent (`com.rightsum.focusmusic`)
- **Session**: `LimitLoadToSessionType: Aqua` ensures menu bar + notifications work in the GUI session
- **Backends**: Protocol-based (`MusicBackend`) with 3 implementations:
  - `LocalBackend` — `AVAudioPlayer` for direct local-file playback
  - `SpotifyBackend` — `NSAppleScript` to control Spotify
  - `YouTubeMusicBackend` — AppleScript + `System Events` key simulation
- **Config**: JSON file at `~/.focusmusic.json` read on startup, written on source switch
- **Notifications**: Legacy `NSUserNotification` (functional but deprecated; migration to `UserNotifications.framework` is a future TODO)

## Known Limitations

- `NSUserNotification` is deprecated. Works on macOS 15 but should migrate to `UserNotifications.framework`.
- YouTube Music support requires Accessibility permissions and is best-effort (no programmatic state query).
- Media keys may conflict with Spotify/Apple Music if those apps were the last system "Now Playing" app. Click the FocusMusic menu bar icon to reassert focus.
- No volume control from the app itself — use system volume.
- Local mode has no playlist persistence; reshuffles on every launch.

## License

MIT

## Credits

Built by [@rightsum](https://github.com/rightsum) with a little help from Pi and Claude.
