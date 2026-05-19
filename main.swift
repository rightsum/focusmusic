import Cocoa
import CoreAudio
import AVFoundation
import MediaPlayer

class Logger {
    static let shared = Logger()
    let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".focusmusic.log")

    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    _ = try? handle.seekToEnd()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

class FocusMusicController: NSObject, AVAudioPlayerDelegate {
    static let shared = FocusMusicController()

    var statusItem: NSStatusItem?
    var player: AVAudioPlayer?
    var musicFiles: [URL] = []
    var currentIndex = 0
    var isHeadphonesConnected = false
    var isManuallyPaused = false
    var lastDeviceName = ""

    let musicDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Focus")
    let headphoneKeywords = [
        "headphone", "external headphones", "airpods", "earbuds",
        "beats", "bose", "sony", "jbl", "sennheiser", "buds",
        "in-ear", "skullcandy", "anker", "pixel buds", "galaxy buds",
        "wh-", "xm5", "xm4", "xm3", "over-ear", "bluetooth headset"
    ]

    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    // MARK: - Setup

    func setup() {
        Logger.shared.log("=== FocusMusic starting ===")
        setupMediaKeys()
        setupMenuBar()
        loadMusic()
        startOutputDeviceListener()
        startPolling()
        checkOutputDevice()
    }

    // MARK: - Media Keys (F7/F8/F9)

    func setupMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.isManuallyPaused = false
            self?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            self?.isManuallyPaused = true
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        Logger.shared.log("Media keys registered")
    }

    func updateNowPlayingInfo() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        if isPlaying, let url = player?.url {
            infoCenter.nowPlayingInfo = [
                MPMediaItemPropertyTitle: url.deletingPathExtension().lastPathComponent,
                MPMediaItemPropertyArtist: "Focus Music",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0
            ]
        } else {
            infoCenter.nowPlayingInfo = [
                MPNowPlayingInfoPropertyPlaybackRate: 0.0
            ]
        }
    }

    // MARK: - Menu Bar

    var nowPlayingItem: NSMenuItem!
    var playPauseItem: NSMenuItem!

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🎵"

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Focus Music", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        nowPlayingItem = NSMenuItem(title: "Checking...", action: nil, keyEquivalent: "")
        nowPlayingItem.isEnabled = false
        menu.addItem(nowPlayingItem)

        menu.addItem(NSMenuItem.separator())

        playPauseItem = NSMenuItem(title: "Play", action: #selector(togglePlayPause), keyEquivalent: "")
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let nextTrack = NSMenuItem(title: "Next Track", action: #selector(playNext), keyEquivalent: "n")
        nextTrack.target = self
        menu.addItem(nextTrack)

        let prevTrack = NSMenuItem(title: "Previous Track", action: #selector(playPrevious), keyEquivalent: "p")
        prevTrack.target = self
        menu.addItem(prevTrack)

        menu.addItem(NSMenuItem.separator())

        let openFolder = NSMenuItem(title: "Open Music Folder", action: #selector(openFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        updateMenu()
    }

    func updateMenu() {
        var statusText = "No headphones"
        if isHeadphonesConnected {
            if isPlaying, let url = player?.url {
                statusText = "▶️ \(url.deletingPathExtension().lastPathComponent)"
            } else if isMicInUse() {
                statusText = "⏸ Mic in use (call?)"
            } else if isManuallyPaused {
                statusText = "⏸ Paused (manual)"
            } else {
                statusText = "⏯ Ready"
            }
        }
        nowPlayingItem.title = statusText
        playPauseItem.title = isPlaying ? "Pause" : "Play"
        statusItem?.button?.title = isPlaying ? "🎧" : "🎵"
    }

    @objc func togglePlayPause() {
        if isPlaying {
            player?.pause()
            isManuallyPaused = true
            Logger.shared.log("Manual pause")
        } else {
            isManuallyPaused = false
            play()
        }
        updateNowPlayingInfo()
        updateMenu()
    }

    @objc func playNext() {
        guard !musicFiles.isEmpty else { return }
        currentIndex = (currentIndex + 1) % musicFiles.count
        Logger.shared.log("Skipping to next track")
        playCurrent()
    }

    @objc func playPrevious() {
        guard !musicFiles.isEmpty else { return }
        currentIndex = (currentIndex - 1 + musicFiles.count) % musicFiles.count
        Logger.shared.log("Skipping to previous track")
        playCurrent()
    }

    @objc func openFolder() {
        NSWorkspace.shared.open(musicDirectory)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Music Loading & Playback

    func loadMusic() {
        let fm = FileManager.default
        let ext = ["mp3", "m4a", "wav", "aiff", "aac", "caf", "mp4", "flac"]
        do {
            let files = try fm.contentsOfDirectory(at: musicDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            musicFiles = files.filter { ext.contains($0.pathExtension.lowercased()) }.shuffled()
            Logger.shared.log("Loaded \(musicFiles.count) tracks from \(musicDirectory.path)")
        } catch {
            Logger.shared.log("Could not load music: \(error)")
        }
    }

    func playCurrent() {
        guard currentIndex < musicFiles.count else { return }
        let url = musicFiles[currentIndex]
        Logger.shared.log("Playing: \(url.lastPathComponent)")
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
        } catch {
            Logger.shared.log("Playback error: \(error)")
        }
        updateNowPlayingInfo()
        updateMenu()
    }

    func play() {
        guard isHeadphonesConnected else {
            Logger.shared.log("Play called but no headphones")
            return
        }
        guard !musicFiles.isEmpty else {
            notify(title: "Focus Music", body: "No music found in ~/Music/Focus")
            return
        }
        if isMicInUse() {
            Logger.shared.log("Mic in use, deferring playback")
            return
        }
        if player == nil || player?.url != musicFiles[currentIndex] {
            playCurrent()
        } else {
            player?.play()
            Logger.shared.log("Resumed playback")
        }
        updateNowPlayingInfo()
        updateMenu()
    }

    func pause() {
        player?.pause()
        Logger.shared.log("Paused")
        updateNowPlayingInfo()
        updateMenu()
    }

    func stop() {
        player?.stop()
        player = nil
        Logger.shared.log("Stopped (headphones disconnected)")
        updateNowPlayingInfo()
        updateMenu()
    }

    // MARK: - Notifications

    func notify(title: String, body: String) {
        Logger.shared.log("Notify: \(title) - \(body)")
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Mic / Call Detection

    func startPolling() {
        // Poll device every 2 seconds as a fallback to CoreAudio listener
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkOutputDevice()
        }
        // Poll mic every 5 seconds
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let micActive = self.isMicInUse()
            if self.isHeadphonesConnected && self.isPlaying && micActive {
                Logger.shared.log("Mic became active during playback -> pause")
                self.pause()
                self.notify(title: "Focus Music Paused", body: "Microphone is now in use (call started).")
            } else if self.isHeadphonesConnected && !self.isPlaying && !micActive && !self.isManuallyPaused {
                Logger.shared.log("Mic free, resuming playback")
                self.play()
            }
        }
    }

    func isMicInUse() -> Bool {
        var inputDeviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &inputDeviceID)
        guard result == noErr else { return false }

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let result2 = AudioObjectGetPropertyData(inputDeviceID, &address, 0, nil, &size, &isRunning)
        return result2 == noErr && isRunning != 0
    }

    // MARK: - Audio Device Listening

    func startOutputDeviceListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            Logger.shared.log("CoreAudio listener fired")
            self?.checkOutputDevice()
        }

        if err != noErr {
            Logger.shared.log("Error adding audio listener: \(err)")
        } else {
            Logger.shared.log("CoreAudio listener registered")
        }
    }

    func checkOutputDevice() {
        let deviceID = getDefaultOutputDeviceID()
        let name = getDeviceName(deviceID: deviceID)
        if name == lastDeviceName { return }
        lastDeviceName = name
        Logger.shared.log("Output device changed to: \(name)")

        let wasConnected = isHeadphonesConnected
        isHeadphonesConnected = isHeadphoneDevice(name: name)

        if isHeadphonesConnected && !wasConnected {
            Logger.shared.log("Headphones connected!")
            if !isMicInUse() {
                notify(title: "🎧 Focus Music", body: "Headphones detected. Starting your focus session.")
                play()
            } else {
                notify(title: "🎧 Focus Music", body: "Headphones detected, but you're in a call. Auto-play will resume when the mic is free.")
            }
        } else if !isHeadphonesConnected && wasConnected {
            Logger.shared.log("Headphones disconnected!")
            stop()
        }
        updateMenu()
    }

    func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    func getDeviceName(deviceID: AudioDeviceID) -> String {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        if err == noErr {
            return name?.takeUnretainedValue() as String? ?? "Unknown"
        }
        return "Unknown"
    }

    func isHeadphoneDevice(name: String) -> Bool {
        let lower = name.lowercased()
        let matched = headphoneKeywords.contains { lower.contains($0) }
        return matched
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Logger.shared.log("Track finished, playing next")
        playNext()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSUserNotificationCenter.default.delegate = self
        FocusMusicController.shared.setup()
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
