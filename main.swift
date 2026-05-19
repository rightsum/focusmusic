import Cocoa
import CoreAudio
import AVFoundation
import MediaPlayer

// MARK: - Config

enum MusicSource: String, Codable, CaseIterable {
    case local = "local"
    case spotify = "spotify"
    case youtubeMusic = "youtubeMusic"

    var displayName: String {
        switch self {
        case .local: return "Local Files"
        case .spotify: return "Spotify"
        case .youtubeMusic: return "YouTube Music"
        }
    }
}

struct AppConfig: Codable {
    var source: MusicSource = .local
    var musicFolder: String? = nil
    var shuffle: Bool = true
}

class ConfigManager {
    static let shared = ConfigManager()
    let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".focusmusic.json")

    func load() -> AppConfig {
        if let data = try? Data(contentsOf: configURL),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            Logger.shared.log("Loaded config: source=\(config.source.rawValue)")
            return config
        }
        Logger.shared.log("No config found, using defaults")
        return AppConfig()
    }

    func save(_ config: AppConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL)
            Logger.shared.log("Saved config: source=\(config.source.rawValue)")
        }
    }
}

// MARK: - Logger

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

// MARK: - Music Backend Protocol

protocol MusicBackend: AnyObject {
    func play()
    func pause()
    func stop()
    func nextTrack()
    func previousTrack()
    var isPlaying: Bool { get }
    var currentTrackName: String? { get }
}

// MARK: - Local Backend (AVAudioPlayer)

class LocalBackend: NSObject, MusicBackend, AVAudioPlayerDelegate {
    var player: AVAudioPlayer?
    var musicFiles: [URL] = []
    var currentIndex = 0
    var onTrackFinished: (() -> Void)?

    let musicDirectory: URL
    let shuffle: Bool

    init(musicDirectory: URL, shuffle: Bool) {
        self.musicDirectory = musicDirectory
        self.shuffle = shuffle
        super.init()
        loadMusic()
    }

    func loadMusic() {
        let fm = FileManager.default
        let ext = ["mp3", "m4a", "wav", "aiff", "aac", "caf", "mp4", "flac"]
        do {
            let files = try fm.contentsOfDirectory(at: musicDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            musicFiles = files.filter { ext.contains($0.pathExtension.lowercased()) }
            if shuffle { musicFiles.shuffle() }
            Logger.shared.log("Loaded \(musicFiles.count) tracks from \(musicDirectory.path)")
        } catch {
            Logger.shared.log("Could not load music: \(error)")
        }
    }

    func play() {
        guard currentIndex < musicFiles.count else { return }
        if player == nil || player?.url != musicFiles[currentIndex] {
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
        } else {
            player?.play()
            Logger.shared.log("Resumed playback")
        }
        updateNowPlayingInfo()
    }

    func pause() {
        player?.pause()
        Logger.shared.log("Paused")
        updateNowPlayingInfo()
    }

    func stop() {
        player?.stop()
        player = nil
        Logger.shared.log("Stopped")
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !musicFiles.isEmpty else { return }
        currentIndex = (currentIndex + 1) % musicFiles.count
        Logger.shared.log("Next track")
        play()
    }

    func previousTrack() {
        guard !musicFiles.isEmpty else { return }
        currentIndex = (currentIndex - 1 + musicFiles.count) % musicFiles.count
        Logger.shared.log("Previous track")
        play()
    }

    var isPlaying: Bool {
        return player?.isPlaying ?? false
    }

    var currentTrackName: String? {
        return player?.url?.deletingPathExtension().lastPathComponent
    }

    func updateNowPlayingInfo() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        if isPlaying, let name = currentTrackName {
            infoCenter.nowPlayingInfo = [
                MPMediaItemPropertyTitle: name,
                MPMediaItemPropertyArtist: "Focus Music",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0
            ]
        } else {
            infoCenter.nowPlayingInfo = [MPNowPlayingInfoPropertyPlaybackRate: 0.0]
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Logger.shared.log("Track finished, playing next")
        nextTrack()
    }
}

// MARK: - Spotify Backend (AppleScript)

class SpotifyBackend: NSObject, MusicBackend {
    private func runScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            Logger.shared.log("AppleScript error: \(error)")
        }
        return result?.stringValue
    }

    func play() {
        _ = runScript("tell application \"Spotify\" to play")
        Logger.shared.log("Spotify: play")
    }

    func pause() {
        _ = runScript("tell application \"Spotify\" to pause")
        Logger.shared.log("Spotify: pause")
    }

    func stop() {
        pause()
    }

    func nextTrack() {
        _ = runScript("tell application \"Spotify\" to next track")
        Logger.shared.log("Spotify: next")
    }

    func previousTrack() {
        _ = runScript("tell application \"Spotify\" to previous track")
        Logger.shared.log("Spotify: previous")
    }

    var isPlaying: Bool {
        let state = runScript("tell application \"Spotify\" to return player state as string")
        return state?.lowercased() == "playing"
    }

    var currentTrackName: String? {
        let name = runScript("tell application \"Spotify\" to return name of current track")
        let artist = runScript("tell application \"Spotify\" to return artist of current track")
        if let n = name, let a = artist {
            return "\(n) - \(a)"
        }
        return name
    }
}

// MARK: - YouTube Music Backend (AppleScript + System Events)

class YouTubeMusicBackend: NSObject, MusicBackend {
    private var _isPlaying = false

    private func runScript(_ source: String) {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            Logger.shared.log("AppleScript error: \(error)")
        }
    }

    private func activate() {
        runScript("tell application \"YouTube Music\" to activate")
    }

    func play() {
        activate()
        // Spacebar toggles play/pause in YouTube Music
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runScript("""
                tell application "System Events"
                    key code 49
                end tell
            """)
        }
        _isPlaying = true
        Logger.shared.log("YouTube Music: play (spacebar)")
    }

    func pause() {
        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runScript("""
                tell application "System Events"
                    key code 49
                end tell
            """)
        }
        _isPlaying = false
        Logger.shared.log("YouTube Music: pause (spacebar)")
    }

    func stop() {
        pause()
    }

    func nextTrack() {
        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runScript("""
                tell application "System Events"
                    key code 45 using shift down
                end tell
            """)
        }
        Logger.shared.log("YouTube Music: next (Shift+N)")
    }

    func previousTrack() {
        activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runScript("""
                tell application "System Events"
                    key code 35 using shift down
                end tell
            """)
        }
        Logger.shared.log("YouTube Music: previous (Shift+P)")
    }

    var isPlaying: Bool {
        return _isPlaying
    }

    var currentTrackName: String? {
        return "YouTube Music"
    }
}

// MARK: - FocusMusicController

class FocusMusicController: NSObject {
    static let shared = FocusMusicController()

    var statusItem: NSStatusItem?
    var backend: MusicBackend?
    var config = AppConfig()
    var isHeadphonesConnected = false
    var isManuallyPaused = false
    var lastDeviceName = ""

    let headphoneKeywords = [
        "headphone", "external headphones", "airpods", "earbuds",
        "beats", "bose", "sony", "jbl", "sennheiser", "buds",
        "in-ear", "skullcandy", "anker", "pixel buds", "galaxy buds",
        "wh-", "xm5", "xm4", "xm3", "over-ear", "bluetooth headset"
    ]

    // MARK: - Setup

    func setup() {
        Logger.shared.log("=== FocusMusic starting ===")
        config = ConfigManager.shared.load()
        setupMenuBar()
        setupMediaKeys()
        createBackend()
        startOutputDeviceListener()
        startPolling()
        checkOutputDevice()
    }

    func createBackend() {
        switch config.source {
        case .local:
            let folder = config.musicFolder.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Focus")
            backend = LocalBackend(musicDirectory: folder, shuffle: config.shuffle)
        case .spotify:
            backend = SpotifyBackend()
            clearNowPlayingInfo()
        case .youtubeMusic:
            backend = YouTubeMusicBackend()
            clearNowPlayingInfo()
        }
        Logger.shared.log("Backend: \(config.source.displayName)")
    }

    func switchSource(_ source: MusicSource) {
        config.source = source
        ConfigManager.shared.save(config)
        // Clean up old backend
        if let local = backend as? LocalBackend {
            local.stop()
        } else {
            backend?.stop()
        }
        createBackend()
        updateMenu()
        notify(title: "Focus Music", body: "Switched to \(source.displayName)")
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Media Keys

    func setupMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.isManuallyPaused = false
            self?.backend?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.backend?.pause()
            self?.isManuallyPaused = true
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.backend?.nextTrack()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.backend?.previousTrack()
            return .success
        }
        Logger.shared.log("Media keys registered")
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

        let nextTrack = NSMenuItem(title: "Next Track", action: #selector(menuNext), keyEquivalent: "n")
        nextTrack.target = self
        menu.addItem(nextTrack)

        let prevTrack = NSMenuItem(title: "Previous Track", action: #selector(menuPrevious), keyEquivalent: "p")
        prevTrack.target = self
        menu.addItem(prevTrack)

        menu.addItem(NSMenuItem.separator())

        // Source submenu
        let sourceMenu = NSMenu(title: "Source")
        for source in MusicSource.allCases {
            let item = NSMenuItem(title: source.displayName, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source
            item.state = config.source == source ? .on : .off
            sourceMenu.addItem(item)
        }
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)

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
            let track = backend?.currentTrackName ?? "Ready"
            if backend?.isPlaying ?? false {
                statusText = "▶️ \(track)"
            } else if isMicInUse() {
                statusText = "⏸ Mic in use (call?)"
            } else if isManuallyPaused {
                statusText = "⏸ Paused (manual)"
            } else {
                statusText = "⏯ \(track)"
            }
        }
        nowPlayingItem.title = statusText
        playPauseItem.title = (backend?.isPlaying ?? false) ? "Pause" : "Play"
        statusItem?.button?.title = (backend?.isPlaying ?? false) ? "🎧" : "🎵"

        // Update source checkmarks
        if let menu = statusItem?.menu {
            for item in menu.items {
                if let sub = item.submenu, sub.title == "Source" {
                    for subItem in sub.items {
                        if let src = subItem.representedObject as? MusicSource {
                            subItem.state = config.source == src ? .on : .off
                        }
                    }
                }
            }
        }
    }

    @objc func togglePlayPause() {
        guard let backend = backend else { return }
        if backend.isPlaying {
            backend.pause()
            isManuallyPaused = true
            Logger.shared.log("Manual pause")
        } else {
            isManuallyPaused = false
            backend.play()
        }
        updateMenu()
    }

    @objc func menuNext() {
        backend?.nextTrack()
        updateMenu()
    }

    @objc func menuPrevious() {
        backend?.previousTrack()
        updateMenu()
    }

    @objc func selectSource(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? MusicSource else { return }
        switchSource(source)
    }

    @objc func openFolder() {
        let folder = config.musicFolder.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Focus")
        NSWorkspace.shared.open(folder)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
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
            guard let self = self, let backend = self.backend else { return }
            let micActive = self.isMicInUse()
            if self.isHeadphonesConnected && backend.isPlaying && micActive {
                Logger.shared.log("Mic became active during playback -> pause")
                backend.pause()
                self.notify(title: "Focus Music Paused", body: "Microphone is now in use (call started).")
                self.updateMenu()
            } else if self.isHeadphonesConnected && !backend.isPlaying && !micActive && !self.isManuallyPaused {
                Logger.shared.log("Mic free, resuming playback")
                backend.play()
                self.updateMenu()
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
                backend?.play()
            } else {
                notify(title: "🎧 Focus Music", body: "Headphones detected, but you're in a call. Auto-play will resume when the mic is free.")
            }
        } else if !isHeadphonesConnected && wasConnected {
            Logger.shared.log("Headphones disconnected!")
            backend?.stop()
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
        return headphoneKeywords.contains { lower.contains($0) }
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
