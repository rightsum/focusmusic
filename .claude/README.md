# .claude — Claude Development Context

## What the User Wanted

The user (@rightsum) described a daily friction point:

> "Whenever I connect my headphones on my Mac, I want music to automatically start playing from my focus folder (`~/Music/Focus`). I want a status bar notification I can pause. And it should be smart — if I'm in a call, it shouldn't start. It should just automatically go for my focus music."

## Problem Breakdown

1. **Manual step**: Every time he puts on headphones, he has to manually open a music app and hit play.
2. **Context unaware**: If he's joining a Zoom/Teams/FaceTime call, music might start and be embarrassing.
3. **No quick control**: He wants pause/play accessible from the menu bar without opening a full app.
4. **Local files**: He already has curated focus music in `~/Music/Focus`.

## Solution Approach

A lightweight macOS menu-bar agent that:
- Monitors the default audio output device (CoreAudio)
- Detects headphone-like devices by name (AirPods, WH-1000XM5, etc.)
- Starts shuffling local audio files immediately on connect
- Polls the default input mic; if it's active, defers or pauses playback
- Registers with `MPRemoteCommandCenter` so F7/F8/F9 media keys work
- Runs as a LaunchAgent for always-on behavior

## Iteration History

1. **Initial build**: Basic CoreAudio listener + AVAudioPlayer + menu bar. User's WH-1000XM5 wasn't detected because `WH-1000XM5` didn't match any keyword.
2. **Fix 1**: Added `wh-`, `xm5`, `xm4`, `xm3`, `over-ear`, `bluetooth headset` keywords + 2s polling fallback.
3. **Fix 2**: Added `LimitLoadToSessionType: Aqua` to LaunchAgent to fix menu bar visibility.
4. **Fix 3**: Added `MediaPlayer` framework + `MPRemoteCommandCenter` for F7/F8/F9 support.
5. **Current**: User asked to generalize for open-source release with proper README, `.pi`/`.claude` folders, and GitHub repo.

## User Preferences

- Wants clean, open-source release
- Uses GitHub username `rightsum`
- Name/email in git: Hoss / hossein@moradgholi.com
- Provided screenshots: `menu-bar.png`, `background-activity.png`
