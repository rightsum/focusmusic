# .claude — Claude Development Context

## What the User Wanted

The user (@rightsum) described a daily friction point:

> "Whenever I connect my headphones on my Mac, I want music to automatically start playing from my focus folder (`~/Music/Focus`). I want a status bar notification I can pause. And it should be smart — if I'm in a call, it shouldn't start. It should just automatically go for my focus music."

Later, he asked:
> "can you make it configurable that works with youtube music and spotify apps on the laptop?"

Then after experiencing flakiness:
> "let's completely remove youtube music, it's buffy and fucked up"

## Problem Breakdown

1. **Manual step**: Every time he puts on headphones, he has to manually open a music app and hit play.
2. **Context unaware**: If he's joining a Zoom/Teams/FaceTime call, music might start and be embarrassing.
3. **No quick control**: He wants pause/play accessible from the menu bar without opening a full app.
4. **Wants Spotify integration**: Not just local files — wants to control Spotify directly, search for playlists.
5. **Wants zero permissions**: Rejected YouTube Music because it required Accessibility permissions.

## Solution Approach

A lightweight macOS menu-bar agent with **2 backends**:
- Monitors default audio output device (CoreAudio) for headphone connection
- Starts playback immediately on connect via the user's chosen source
- Polls the default input mic; if active, defers or pauses playback
- Registers `MPRemoteCommandCenter` so F7/F8/F9 media keys work
- Runs as a LaunchAgent for always-on behavior
- **Zero permissions required** (no Accessibility, no special entitlements)

## Iteration History

1. **Initial build**: Basic CoreAudio listener + `AVAudioPlayer` + menu bar.
2. **Fix 1**: WH-1000XM5 wasn't detected (name `WH-1000XM5` didn't match keywords). Added `wh-`, `xm5`, etc. + 2s polling fallback.
3. **Fix 2**: Added `LimitLoadToSessionType: Aqua` to LaunchAgent for menu bar visibility.
4. **Fix 3**: Added `MediaPlayer` framework + `MPRemoteCommandCenter` for F7/F8/F9.
5. **v2.0 — Configurable backends**: Refactored into `MusicBackend` protocol with 3 implementations (Local, Spotify, YouTube Music).
6. **Fix 4**: YouTube Music `stop()` was reopening closed app. Made it a no-op.
7. **Fix 5**: Spotify `play()` was skipping when app closed. Fixed to launch app on connect.
8. **Fix 6**: Added config reload before `play()` so edits are picked up without restart.
9. **Fix 7**: Added `SpotifyAPIClient` for search auto-play. Fixed null-item handling in JSON.
10. **Fix 8**: Switched from `open location` + `play` to `play track` for explicit playlist switching.
11. **v3.0 — Removed YouTube Music**: User found it flaky. Now only Local Files + Spotify. Zero permissions needed.

## User Preferences

- Wants clean, open-source release
- Uses GitHub username `rightsum`
- Name/email in git: Hoss / hossein@moradgholi.com
- Provided screenshots: `menu-bar.png`, `background-activity.png`
- Has Sony WH-1000XM5 headphones
- Uses Spotify desktop app
- Wants zero-permission, no-Accessibility experience
- Wants search functionality on Spotify
