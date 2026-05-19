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
    var spotifyUri: String? = nil
    var spotifySearchQuery: String? = nil
    var spotifyClientId: String? = nil
    var spotifyClientSecret: String? = nil
    var youtubeMusicUrl: String? = nil
    var youtubeMusicSearchQuery: String? = nil
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

// MARK: - Spotify API Client (optional, for auto-play search)

class SpotifyAPIClient {
    private var cachedToken: String?
    private var tokenExpiry: Date?

    func searchFirstPlaylist(query: String, clientId: String, clientSecret: String) -> String? {
        let token = fetchToken(clientId: clientId, clientSecret: clientSecret)
        guard let t = token else {
            Logger.shared.log("Spotify API: failed to get token")
            return nil
        }
        return searchPlaylists(query: query, token: t)
    }

    private func fetchToken(clientId: String, clientSecret: String) -> String? {
        // Use cached token if still valid
        if let token = cachedToken, let expiry = tokenExpiry, Date() < expiry {
            return token
        }

        let credentials = "\(clientId):\(clientSecret)"
        guard let credData = credentials.data(using: .utf8) else { return nil }
        let base64 = credData.base64EncodedString()

        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=client_credentials".data(using: .utf8)

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                Logger.shared.log("Spotify token error: \(error)")
                semaphore.signal()
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                Logger.shared.log("Spotify token: invalid response")
                semaphore.signal()
                return
            }
            result = token
            self.cachedToken = token
            self.tokenExpiry = Date().addingTimeInterval(expiresIn - 60) // 1 min buffer
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private func searchPlaylists(query: String, token: String) -> String? {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.spotify.com/v1/search?q=\(encodedQuery)&type=playlist&limit=1")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                Logger.shared.log("Spotify search error: \(error)")
                semaphore.signal()
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let playlists = json["playlists"] as? [String: Any],
                  let items = playlists["items"] as? [[String: Any]],
                  let first = items.first,
                  let uri = first["uri"] as? String else {
                Logger.shared.log("Spotify search: no results")
                semaphore.signal()
                return
            }
            Logger.shared.log("Spotify search: found \(uri)")
            result = uri
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
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

// MARK: - Spotify Backend (AppleScript + optional Web API)

class SpotifyBackend: NSObject, MusicBackend {
    var config: AppConfig
    let apiClient = SpotifyAPIClient()

    init(config: AppConfig) {
        self.config = config
    }

    private func runScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            Logger.shared.log("AppleScript error: \(error)")
        }
        return result?.stringValue
    }

    private func isAppRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        return apps.contains { $0.localizedName == "Spotify" }
    }

    func play() {
        // On headphone connect, user WANTS music to start.
        // If app is closed, open it. Only skip if we're in a background loop
        // (e.g. mic-poll resume) and user intentionally closed it.
        if !isAppRunning() {
            Logger.shared.log("Spotify: launching app")
            _ = runScript("tell application \"Spotify\" to activate")
            // Wait for app to launch before sending commands
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.executePlay()
            }
            return
        }
        executePlay()
    }

    private func executePlay() {
        // Priority 1: explicit URI
        if let uri = config.spotifyUri, !uri.isEmpty {
            Logger.shared.log("Spotify: opening explicit URI \(uri)")
            _ = runScript("tell application \"Spotify\" to open location \"\(uri)\"")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                _ = self?.runScript("tell application \"Spotify\" to play")
                Logger.shared.log("Spotify: play after URI load")
            }
            return
        }

        // Priority 2: search query with API credentials -> auto-play first result
        if let query = config.spotifySearchQuery, !query.isEmpty,
           let clientId = config.spotifyClientId, !clientId.isEmpty,
           let clientSecret = config.spotifyClientSecret, !clientSecret.isEmpty {
            Logger.shared.log("Spotify: searching for '\(query)'")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let uri = self.apiClient.searchFirstPlaylist(query: query, clientId: clientId, clientSecret: clientSecret) {
                    DispatchQueue.main.async {
                        Logger.shared.log("Spotify: playing search result \(uri)")
                        _ = self.runScript("tell application \"Spotify\" to open location \"\(uri)\"")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            _ = self.runScript("tell application \"Spotify\" to play")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        Logger.shared.log("Spotify: search failed, falling back to resume")
                        _ = self.runScript("tell application \"Spotify\" to play")
                    }
                }
            }
            return
        }

        // Priority 3: search query without API credentials -> open search page
        if let query = config.spotifySearchQuery, !query.isEmpty {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? query
            let searchUri = "spotify:search:\(encoded)"
            Logger.shared.log("Spotify: opening search page \(searchUri)")
            _ = runScript("tell application \"Spotify\" to open location \"\(searchUri)\"")
            return
        }

        // Priority 4: just resume
        _ = runScript("tell application \"Spotify\" to play")
        Logger.shared.log("Spotify: play (resume)")
    }

    func pause() {
        guard isAppRunning() else {
            Logger.shared.log("Spotify: not running, skipping pause")
            return
        }
        _ = runScript("tell application \"Spotify\" to pause")
        Logger.shared.log("Spotify: pause")
    }

    func stop() {
        Logger.shared.log("Spotify: stopped (no-op, app stays closed)")
    }

    func nextTrack() {
        guard isAppRunning() else {
            Logger.shared.log("Spotify: not running, skipping next")
            return
        }
        _ = runScript("tell application \"Spotify\" to next track")
        Logger.shared.log("Spotify: next")
    }

    func previousTrack() {
        guard isAppRunning() else {
            Logger.shared.log("Spotify: not running, skipping previous")
            return
        }
        _ = runScript("tell application \"Spotify\" to previous track")
        Logger.shared.log("Spotify: previous")
    }

    var isPlaying: Bool {
        guard isAppRunning() else { return false }
        let state = runScript("tell application \"Spotify\" to return player state as string")
        return state?.lowercased() == "playing"
    }

    var currentTrackName: String? {
        guard isAppRunning() else { return nil }
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
    var config: AppConfig
    private var _isPlaying = false

    init(config: AppConfig) {
        self.config = config
    }

    private func runScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)
        if let error = errorInfo {
            Logger.shared.log("AppleScript error: \(error)")
            if let num = error["NSAppleScriptErrorNumber"] as? Int, num == -1002 || num == 1002 {
                showAccessibilityAlert()
            }
        }
        return result?.stringValue
    }

    private func showAccessibilityAlert() {
        let notification = NSUserNotification()
        notification.title = "🔐 Accessibility Required"
        notification.informativeText = "FocusMusic needs Accessibility permissions to control YouTube Music. Click to open System Settings."
        notification.hasActionButton = true
        notification.actionButtonTitle = "Open Settings"
        notification.userInfo = ["openAccessibility": true]
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func sendKey(_ keyCode: Int, shift: Bool = false) {
        if shift {
            runScript("""
                tell application "System Events"
                    key code \(keyCode) using shift down
                end tell
            """)
        } else {
            runScript("""
                tell application "System Events"
                    key code \(keyCode)
                end tell
            """)
        }
    }

    private func isAppRunning() -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let byName = apps.contains { $0.localizedName == "YouTube Music" }
        let byBundle = apps.contains { $0.bundleIdentifier?.hasPrefix("com.google.Chrome.app.") ?? false }
        return byName || byBundle
    }

    func play() {
        // On headphone connect, user WANTS music to start.
        // If app is closed, open it. Only skip on background pause/stop.
        if !isAppRunning() {
            // Priority 1: explicit URL
            if let urlString = config.youtubeMusicUrl, !urlString.isEmpty {
                Logger.shared.log("YouTube Music: launching app with URL \(urlString)")
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "YouTube Music", urlString]
                try? task.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.sendKey(49) // Space
                    Logger.shared.log("YouTube Music: sent spacebar after URL open")
                }
                _isPlaying = true
                return
            }
            // Priority 2: search query
            if let query = config.youtubeMusicSearchQuery, !query.isEmpty {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
                let searchUrl = "https://music.youtube.com/search?q=\(encoded)"
                Logger.shared.log("YouTube Music: launching app with search \(searchUrl)")
                let task = Process()
                task.launchPath = "/usr/bin/open"
                task.arguments = ["-a", "YouTube Music", searchUrl]
                try? task.run()
                _isPlaying = true
                return
            }
            // Priority 3: just launch and play
            Logger.shared.log("YouTube Music: launching app")
            runScript("tell application \"YouTube Music\" to activate")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.sendKey(49) // Space
                Logger.shared.log("YouTube Music: sent spacebar to play")
            }
            _isPlaying = true
            return
        }

        // App is already running — bring to front and play
        Logger.shared.log("YouTube Music: bringing to front")
        runScript("tell application \"YouTube Music\" to activate")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendKey(49) // Space
            Logger.shared.log("YouTube Music: sent spacebar to play")
        }
        _isPlaying = true
    }

    func pause() {
        if !isAppRunning() {
            Logger.shared.log("YouTube Music: pause skipped — app not running")
            _isPlaying = false
            return
        }
        sendKey(49) // Space
        _isPlaying = false
        Logger.shared.log("YouTube Music: pause (spacebar)")
    }

    func stop() {
        _isPlaying = false
        Logger.shared.log("YouTube Music: stopped (no-op, app stays closed)")
    }

    func nextTrack() {
        if !isAppRunning() {
            runScript("tell application \"YouTube Music\" to activate")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendKey(45, shift: true) // Shift+N
        }
        Logger.shared.log("YouTube Music: next (Shift+N)")
    }

    func previousTrack() {
        if !isAppRunning() {
            runScript("tell application \"YouTube Music\" to activate")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendKey(35, shift: true) // Shift+P
        }
        Logger.shared.log("YouTube Music: previous (Shift+P)")
    }

    var isPlaying: Bool {
        return _isPlaying
    }

    var currentTrackName: String? {
        return nil
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
            backend = SpotifyBackend(config: config)
            clearNowPlayingInfo()
        case .youtubeMusic:
            backend = YouTubeMusicBackend(config: config)
            clearNowPlayingInfo()
        }
        Logger.shared.log("Backend: \(config.source.displayName)")
    }

    func switchSource(_ source: MusicSource) {
        config.source = source
        ConfigManager.shared.save(config)
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
            let track = backend?.currentTrackName ?? config.source.displayName
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
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkOutputDevice()
        }
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

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if notification.userInfo?["openAccessibility"] != nil {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
