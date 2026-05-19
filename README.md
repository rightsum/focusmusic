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
| **Spotify** | Controls Spotify via AppleScript + optional Web API for search | Routed through FocusMusic to Spotify |
| **YouTube Music** | Activates the app + simulates keyboard shortcuts via AppleScript/System Events | Routed through FocusMusic to YouTube Music |

### Spotify mode

Requires the **Spotify desktop app** to be installed. FocusMusic sends AppleScript commands to control playback, reads the current track name, and detects play/pause state directly from Spotify.

You can configure:
- **`spotifyUri`** — open a specific playlist/album/track on connect
- **`spotifySearchQuery`** — search for a term. Without API credentials, it opens the search page. With credentials, it **auto-plays the first playlist result**.

### YouTube Music mode

Requires the official **YouTube Music Mac app** from the App Store (or Chrome PWA). FocusMusic uses AppleScript to activate the app and simulate keyboard shortcuts:
- **Spacebar** — play/pause
- **Shift+N** — next track
- **Shift+P** — previous track

You can configure:
- **`youtubeMusicUrl`** — open a specific playlist/album URL on connect
- **`youtubeMusicSearchQuery`** — open the YouTube Music search page for a term

> ⚠️ **YouTube Music requires Accessibility permissions** for `System Events` key simulation. macOS will prompt you the first time. If it doesn't work, go to **System Settings → Privacy & Security → Accessibility** and add `FocusMusic`.

> ⚠️ YouTube Music state tracking is best-effort. If commands feel out of sync, pause/resume manually once.

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
  "shuffle": true,
  "spotifyUri": null,
  "spotifySearchQuery": null,
  "spotifyClientId": null,
  "spotifyClientSecret": null,
  "youtubeMusicUrl": null,
  "youtubeMusicSearchQuery": null
}
```

| Field | Description |
|-------|-------------|
| `source` | `"local"`, `"spotify"`, or `"youtubeMusic"` |
| `musicFolder` | Path to local music folder (local mode only) |
| `shuffle` | Shuffle tracks on load (local mode only) |
| `spotifyUri` | Spotify URI to open on connect, e.g. `spotify:playlist:37i9dQZF1DX4wta20PHgwo` |
| `spotifySearchQuery` | Search term, e.g. `"focus music"`. With API creds: auto-plays first playlist. Without: opens search page. |
| `spotifyClientId` | Spotify Web API Client ID (optional, free, from developer.spotify.com) |
| `spotifyClientSecret` | Spotify Web API Client Secret (optional) |
| `youtubeMusicUrl` | YouTube Music URL to open on connect, e.g. `https://music.youtube.com/playlist?list=PL...` |
| `youtubeMusicSearchQuery` | Search term, e.g. `"lofi hip hop"`. Opens search page on connect. |

Edit this file directly or switch sources from the menu bar.

### 🎵 Spotify: Specific Playlist / Album / Track

Find any playlist on Spotify, click **Share → Copy Spotify URI**, then paste it into your config:

```json
{
  "source": "spotify",
  "spotifyUri": "spotify:playlist:37i9dQZF1DX4wta20PHgwo"
}
```

When you connect your headphones, FocusMusic will:
1. Open that playlist in Spotify
2. Wait ~1 second for it to load
3. Hit **play**

You can also use album URIs (`spotify:album:...`) or track URIs (`spotify:track:...`).

### 🔍 Spotify: Search (Open Search Page — no API)

Just set a search query:

```json
{
  "source": "spotify",
  "spotifySearchQuery": "focus music"
}
```

When headphones connect, Spotify opens to search results for `"focus music"`. You click the first playlist and it starts playing. No API setup needed.

### 🤖 Spotify: Search (Auto-Play First Result — with API)

For true "search and auto-play the first playlist", you need Spotify API credentials (free, no credit card):

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Log in with your Spotify account
3. Click **Create App**
4. Name it `FocusMusic`, description `Personal music automation`
5. Check the boxes, click **Save**
6. Copy **Client ID** and **Client Secret**
7. Paste them into your config:

```json
{
  "source": "spotify",
  "spotifySearchQuery": "focus music",
  "spotifyClientId": "your-client-id-here",
  "spotifyClientSecret": "your-client-secret-here"
}
```

Now when headphones connect:
1. FocusMusic fetches a token from Spotify
2. Searches for `"focus music"` playlists
3. Gets the first result's URI
4. Opens it in Spotify and hits **play**

All automatically — no clicking required.

### 🎵 YouTube Music: Specific Playlist

Find a playlist on YouTube Music, copy its URL, then paste it into your config:

```json
{
  "source": "youtubeMusic",
  "youtubeMusicUrl": "https://music.youtube.com/playlist?list=PL..."
}
```

When you connect your headphones, FocusMusic opens that URL directly in the YouTube Music app. You'll need to hit play manually the first time (the app doesn't support auto-play on URL open), but after that, media keys and call detection work normally.

### 🔍 YouTube Music: Search

Set a search query:

```json
{
  "source": "youtubeMusic",
  "youtubeMusicSearchQuery": "lofi hip hop"
}
```

When headphones connect, YouTube Music opens to search results for `"lofi hip hop"`. You click the first playlist and start playing.

> ⚠️ YouTube Music has no public API for auto-playing search results. The search page approach is the best we can do without third-party tools.

### Priority Order

Each backend checks in this order:

**Spotify:**
1. `spotifyUri` — explicit playlist/album/track
2. `spotifySearchQuery` + API credentials — search & auto-play first result
3. `spotifySearchQuery` — open search page
4. Nothing — resume whatever was last playing

**YouTube Music:**
1. `youtubeMusicUrl` — explicit playlist/album
2. `youtubeMusicSearchQuery` — open search page
3. Nothing — resume with spacebar

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
├── main.swift          # Complete Swift source (~900 lines)
├── install.sh          # Build + install + LaunchAgent setup
├── uninstall.sh        # Clean removal
├── grant-accessibility.sh  # Helper for Accessibility permissions
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
  - `SpotifyBackend` — `NSAppleScript` + optional `SpotifyAPIClient` (URLSession + token management) for search auto-play
  - `YouTubeMusicBackend` — AppleScript `activate` + `System Events` key simulation
- **Config**: JSON file at `~/.focusmusic.json` read on startup, written on source switch
- **Notifications**: Legacy `NSUserNotification` (functional but deprecated; migration to `UserNotifications.framework` is a future TODO)

## Known Limitations

- `NSUserNotification` is deprecated. Works on macOS 15 but should migrate to `UserNotifications.framework`.
- YouTube Music support requires Accessibility permissions and is best-effort (no programmatic state query).
- Media keys may conflict with Spotify/Apple Music if those apps were the last system "Now Playing" app. Click the FocusMusic menu bar icon to reassert focus.
- No volume control from the app itself — use system volume.
- Local mode has no playlist persistence; reshuffles on every launch.
- YouTube Music URL open does not auto-play; you need to hit play once after the URL loads.
- Spotify search auto-play requires free API credentials (one-time setup).

## License

MIT

## Credits

Built by [@rightsum](https://github.com/rightsum) with a little help from Pi and Claude.
