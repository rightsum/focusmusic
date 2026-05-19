# .claude — Claude Development Context

## What the User Wanted

The user (@rightsum) described a daily friction point:

> "Whenever I connect my headphones on my Mac, I want music to automatically start playing from my focus folder (`~/Music/Focus`). I want a status bar notification I can pause. And it should be smart — if I'm in a call, it shouldn't start. It should just automatically go for my focus music."

Later, he asked for Spotify and YouTube Music integration, then removed YouTube Music due to flakiness, and finally rebranded to **Nik-Music** (نیک — Persian for "good," from Zoroastrian *Humata, Hukhta, Huvarshta*).

## Problem Breakdown

1. **Manual step**: Every time he puts on headphones, he has to manually open a music app and hit play.
2. **Context unaware**: If he's joining a Zoom/Teams/FaceTime call, music might start and be embarrassing.
3. **No quick control**: He wants pause/play accessible from the menu bar without opening a full app.
4. **Wants Spotify integration**: Search for playlists, auto-play first result.
5. **Wants zero permissions**: Rejected YouTube Music because it required Accessibility permissions.
6. **Wants a meaningful name**: Chose "Nik" — Persian for good/virtuous.

## Solution Approach

A lightweight macOS menu-bar agent with **2 backends**:
- Monitors default audio output device (CoreAudio) for headphone connection
- Starts playback immediately on connect via the user's chosen source
- Polls the default input mic; if active, defers or pauses playback
- Registers `MPRemoteCommandCenter` for media keys
- Runs as a LaunchAgent for always-on behavior
- **Zero permissions required**

## Iteration History

See `.pi/README.md` for full technical iteration history.

## User Preferences

- Wants clean, open-source release
- Uses GitHub username `rightsum`
- Name/email in git: Hoss / hossein@moradgholi.com
- Provided screenshots: `menu-bar.png`, `background-activity.png`
- Has Sony WH-1000XM5 headphones
- Uses Spotify desktop app
- Wants zero-permission, no-Accessibility experience
- Wants search functionality on Spotify
- Chose "Nik-Music" (نیک) as the brand — Persian for "good"
