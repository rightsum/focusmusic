# 🎧 Nik-Music

**Nik** (نیک) is a Persian word meaning **"good," "virtuous,"** and **"benevolent."** In Zoroastrianism — one of the world's oldest continuously practiced religions, born in ancient Persia — it appears in the sacred threefold motto: *Humata, Hukhta, Huvarshta* (Good Thoughts, Good Words, Good Deeds). In modern Persian, you'll hear it in expressions like *Pendar-e Nik* (good thoughts) and *Kerdar-e Nik* (good deeds).

Nik-Music is a tiny macOS menu-bar app that brings that same spirit of **goodness** to your daily workflow: it automatically starts playing your music when you plug in headphones — and pauses itself if you're in a call. No friction, no forgotten steps, just a **nik** (good) moment every time you sit down to work.

![Menu Bar](assets/menu-bar.png)

## The Problem

Every day, when I sit down to work and put on my headphones, I have to:

1. Open a music app
2. Navigate to the right playlist
3. Hit play

And if I join a Zoom call with music still playing, it's embarrassing. I wanted something **smarter** — an app that just *knows* when my headphones are on and whether I'm in a call.

## The Solution

Nik-Music is a lightweight native macOS agent that:

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
| **Spotify** | Controls Spotify via AppleScript + optional Web API for search | Routed through Nik-Music to Spotify |

### Spotify mode

Requires the **Spotify desktop app** to be installed. Nik-Music sends AppleScript commands to control playback, reads the current track name, and detects play/pause state directly from Spotify.

You can configure:
- **`spotifyUri`** — open a specific playlist/album/track on connect
- **`spotifySearchQuery`** — search for a term. Without API credentials, it opens the search page. With credentials, it **auto-plays the first playlist result**.

## Installation

### One-liner

```bash
git clone https://github.com/rightsum/nik-music.git
cd nik-music
./install.sh
```

### What `install.sh` does

1. Compiles the Swift app (`main.swift`)
2. Creates `~/Music/Focus` if it doesn't exist
3. Copies the binary to `~/.local/bin/NikMusic`
4. Creates a default config at `~/.nikmusic.json`
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

Your choice is saved to `~/.nikmusic.json` and persists across restarts.

### Configuration file

`~/.nikmusic.json`:

```json
{
  "source": "local",
  "musicFolder": "/Users/rightsum/Music/Focus",
  "shuffle": true,
  "spotifyUri": null,
  "spotifySearchQuery": null,
  "spotifyClientId": null,
  "spotifyClientSecret": null
}
```

| Field | Description |
|-------|-------------|
| `source` | `"local"` or `"spotify"` |
| `musicFolder` | Path to local music folder (local mode only) |
| `shuffle` | Shuffle tracks on load (local mode only) |
| `spotifyUri` | Spotify URI to open on connect, e.g. `spotify:playlist:37i9dQZF1DX4wta20PHgwo` |
| `spotifySearchQuery` | Search term, e.g. `"focus music"`. With API creds: auto-plays first playlist. Without: opens search page. |
| `spotifyClientId` | Spotify Web API Client ID (optional, free, from developer.spotify.com) |
| `spotifyClientSecret` | Spotify Web API Client Secret (optional) |

Edit this file directly or switch sources from the menu bar.

### 🎵 Spotify: Specific Playlist / Album / Track

Find any playlist on Spotify, click **Share → Copy Spotify URI**, then paste it into your config:

```json
{
  "source": "spotify",
  "spotifyUri": "spotify:playlist:37i9dQZF1DX4wta20PHgwo"
}
```

When you connect your headphones, Nik-Music will open that playlist in Spotify and hit **play**.

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
4. Name it `Nik-Music`, description `Personal music automation`
5. Check the boxes, click **Save**
6. Click **Settings** on your new app
7. Copy **Client ID** and **Client Secret**
8. Paste them into your config:

```json
{
  "source": "spotify",
  "spotifySearchQuery": "focus music",
  "spotifyClientId": "your-client-id-here",
  "spotifyClientSecret": "your-client-secret-here"
}
```

Now when headphones connect, Nik-Music searches Spotify's API for playlists, gets the first result, and **auto-plays** it. Zero clicks.

### Priority Order

**Spotify:**
1. `spotifyUri` — explicit playlist/album/track
2. `spotifySearchQuery` + API credentials — search & auto-play first result
3. `spotifySearchQuery` — open search page
4. Nothing — resume whatever was last playing

## How It Works

### Headphone Detection

The app listens to macOS's default audio output device via CoreAudio. When the device name matches known headphone keywords, it triggers playback. It also polls every 2 seconds as a fallback for Bluetooth reconnects that CoreAudio events sometimes miss.

Keywords include: `headphone`, `airpods`, `earbuds`, `beats`, `bose`, `sony`, `wh-`, `xm5`, `buds`, `bluetooth headset`, and more.

**If your headphones aren't detected**, check `~/.nikmusic.log` for the exact device name and add it to the `headphoneKeywords` array in `main.swift`, then re-run `./install.sh`.

### Call Detection

Every 5 seconds, the app checks if the default input microphone is actively recording (`kAudioDevicePropertyDeviceIsRunningSomewhere`). This covers:

- FaceTime
- Zoom
- Microsoft Teams
- Slack huddles
- Any app using the mic

If a call starts during playback, music pauses immediately with a notification. When the mic goes idle, it resumes (unless you manually paused).

### Media Keys

Nik-Music registers with `MPRemoteCommandCenter`. When you press F8/F9/F7, macOS routes them to Nik-Music, which forwards the command to your active backend:

- **Local mode** → controls `AVAudioPlayer`
- **Spotify mode** → sends AppleScript to Spotify

If another app (Spotify, Apple Music) recently played and is still the system's "Now Playing" app, you may need to click the Nik-Music menu bar icon once to reassert focus.

## Permissions

**No special permissions needed.** Nik-Music works out of the box with zero system permissions:

| Feature | Needs Accessibility? | Needs Notifications? |
|---------|----------------------|----------------------|
| Headphone detection | ❌ No (CoreAudio) | ❌ No |
| Call detection | ❌ No (CoreAudio) | ❌ No |
| Local playback | ❌ No (AVAudioPlayer) | ❌ No |
| Spotify control | ❌ No (AppleScript) | ❌ No |
| Menu bar icon | ❌ No | ❌ No |
| Media keys | ❌ No (MPRemoteCommandCenter) | ❌ No |
| Notification banners | ❌ No | ⚠️ macOS may ask once |

The first time a notification appears, macOS might ask if Nik-Music can show alerts. Just click **Allow**.

## Development

### Project Structure

```
.
├── main.swift          # Complete Swift source (~800 lines)
├── install.sh          # Build + install + LaunchAgent setup
├── uninstall.sh        # Clean removal
├── build/              # Compiled binary
├── assets/             # Screenshots
├── .pi/                # Pi agent development context
└── .claude/            # Claude agent development context
```

### Build manually

```bash
swiftc -framework Cocoa -framework CoreAudio -framework AVFoundation -framework MediaPlayer main.swift -o build/NikMusic
```

### Logs

```bash
# Live debug log
tail -f ~/.nikmusic.log

# LaunchAgent stdout/stderr
tail -f /tmp/nikmusic.out.log
tail -f /tmp/nikmusic.err.log
```

### Managing the service

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.rightsum.nikmusic.plist

# Start
launchctl load ~/Library/LaunchAgents/com.rightsum.nikmusic.plist

# Check if running
ps aux | grep NikMusic
```

## Architecture

- **Language**: Swift (AppKit + CoreAudio + AVFoundation + MediaPlayer)
- **UI**: `NSStatusBar` menu-only app, no dock icon
- **Persistence**: `launchd` LaunchAgent (`com.rightsum.nikmusic`)
- **Session**: `LimitLoadToSessionType: Aqua` ensures menu bar + notifications work in the GUI session
- **Backends**: Protocol-based (`MusicBackend`) with 2 implementations:
  - `LocalBackend` — `AVAudioPlayer` for direct local-file playback
  - `SpotifyBackend` — `NSAppleScript` + optional `SpotifyAPIClient` (URLSession + token management) for search auto-play
- **Config**: JSON file at `~/.nikmusic.json` read on startup, written on source switch
- **Notifications**: Legacy `NSUserNotification` (functional but deprecated; migration to `UserNotifications.framework` is a future TODO)

## Known Limitations

- `NSUserNotification` is deprecated. Works on macOS 15 but should migrate to `UserNotifications.framework`.
- Media keys may conflict with Spotify/Apple Music if those apps were the last system "Now Playing" app. Click the Nik-Music menu bar icon to reassert focus.
- No volume control from the app itself — use system volume.
- Local mode has no playlist persistence; reshuffles on every launch.
- Spotify search auto-play requires free API credentials (one-time setup).

## License

MIT

## Credits

Built by [@rightsum](https://github.com/rightsum) with a little help from Pi and Claude.
