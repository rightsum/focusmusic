# .claude — Claude Development Context

## What the User Wanted

The user (@rightsum) described a daily friction point:

> "Whenever I connect my headphones on my Mac, I want music to automatically start playing... I want a status bar notification I can pause. And it should be smart — if I'm in a call, it shouldn't start."

Later, after building Local + Spotify support:

> "this app should expose a MCP server functionality, so basically openclaw or claude or any other tool can communicate to it... the tool may detect I'm doing something focus driven at office and adjust the music afterward, or maybe sees I had a long meeting and after that adjusts the music to a light jazz toward or if it's night for example to a podcast."

## Problem Breakdown

1. **Manual step**: Every time he puts on headphones, he has to manually open a music app and hit play.
2. **Context unaware**: If he's joining a Zoom/Teams/FaceTime call, music might start and be embarrassing.
3. **No quick control**: He wants pause/play accessible from the menu bar without opening a full app.
4. **Wants Spotify integration**: Search for playlists, auto-play first result.
5. **Wants zero permissions**: Rejected YouTube Music because it required Accessibility permissions.
6. **Wants AI control**: Wants MCP server so Claude/Cursor can intelligently adjust music based on context (meetings, time of day, focus state).
7. **Chose "Nik-Music"**: Persian for good/virtuous (نیک).

## Solution Approach

A macOS menu-bar agent with:
- **2 backends**: Local Files + Spotify
- **Headphone/call detection**: CoreAudio
- **MCP server**: Separate binary implementing Model Context Protocol (JSON-RPC over stdio)
- **10 MCP tools**: get_status, set_source, set_spotify_search, set_spotify_uri, set_spotify_api_credentials, play, pause, next_track, previous_track, set_config
- **Zero permissions** (no Accessibility)

## Iteration History

See `.pi/README.md` for full technical history. Key milestones:
- v1.0: Local file playback
- v2.0: Spotify integration with Web API search auto-play
- v3.0: Removed YouTube Music (flaky, required Accessibility)
- v4.0: Rebranded to Nik-Music
- v5.0: Added MCP server for AI control

## User Preferences

- Wants clean, open-source release
- GitHub: `rightsum/nik-music`
- Name/email: Hoss / hossein@moradgholi.com
- Has Sony WH-1000XM5 headphones
- Uses Spotify desktop app
- Wants zero-permission experience
- Wants AI-driven contextual music control via MCP
