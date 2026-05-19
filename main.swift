import Cocoa
import CoreAudio
import AVFoundation
import MediaPlayer
import CryptoKit

// MARK: - Config

enum MusicSource: String, Codable, CaseIterable {
    case local = "local"
    case spotify = "spotify"

    var displayName: String {
        switch self {
        case .local: return "Local Files"
        case .spotify: return "Spotify"
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
    var mcpPort: UInt16? = nil
    var mcpAutoStart: Bool = false
    var spotifyAccessToken: String? = nil
    var spotifyRefreshToken: String? = nil
    var spotifyTokenExpiry: Double? = nil
}

class ConfigManager {
    static let shared = ConfigManager()
    let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nikmusic.json")

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
    let logURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nikmusic.log")

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

// MARK: - PKCE helpers

func base64URLEncode(_ data: Data) -> String {
    return data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func randomURLSafeString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
    return base64URLEncode(Data(bytes))
}

func sha256Challenge(_ verifier: String) -> String {
    let hash = SHA256.hash(data: verifier.data(using: .ascii)!)
    return base64URLEncode(Data(hash))
}

// MARK: - Spotify Web API (OAuth user-scoped playback control)

class SpotifyWebAPI {
    static let shared = SpotifyWebAPI()

    static let redirectURI = "http://127.0.0.1:8765/callback"
    static let scope = "user-modify-playback-state user-read-playback-state"

    var pendingCodeVerifier: String?
    var pendingState: String?

    func buildAuthorizeURL(clientId: String) -> URL? {
        let verifier = randomURLSafeString(byteCount: 32)
        let challenge = sha256Challenge(verifier)
        let state = randomURLSafeString(byteCount: 16)
        pendingCodeVerifier = verifier
        pendingState = state

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: SpotifyWebAPI.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: SpotifyWebAPI.scope)
        ]
        return components.url
    }

    func handleAuthorizationCode(code: String, state: String, clientId: String, completion: @escaping (Bool, String) -> Void) {
        guard state == pendingState, let verifier = pendingCodeVerifier else {
            completion(false, "OAuth state mismatch — re-click Authorize Spotify.")
            return
        }
        pendingCodeVerifier = nil
        pendingState = nil

        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encodedRedirect = SpotifyWebAPI.redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? SpotifyWebAPI.redirectURI
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(encodedRedirect)&client_id=\(clientId)&code_verifier=\(verifier)"
        request.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                completion(false, "Network error: \(error.localizedDescription)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(false, "Token endpoint returned non-JSON")
                return
            }
            if let err = json["error_description"] as? String {
                completion(false, "Spotify: \(err)")
                return
            }
            guard let access = json["access_token"] as? String,
                  let refresh = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double else {
                completion(false, "Token response missing fields")
                return
            }
            var cfg = ConfigManager.shared.load()
            cfg.spotifyAccessToken = access
            cfg.spotifyRefreshToken = refresh
            cfg.spotifyTokenExpiry = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
            ConfigManager.shared.save(cfg)
            Logger.shared.log("Spotify: authorized, token expires in \(Int(expiresIn))s")
            completion(true, "Authorized")
        }.resume()
    }

    var isAuthorized: Bool {
        ConfigManager.shared.load().spotifyAccessToken != nil
    }

    // Synchronously fetches a valid access token, refreshing if needed.
    func validAccessToken() -> String? {
        var cfg = ConfigManager.shared.load()
        guard let token = cfg.spotifyAccessToken else { return nil }
        let now = Date().timeIntervalSince1970
        let expiry = cfg.spotifyTokenExpiry ?? 0
        if now < expiry - 60 { return token }

        guard let refresh = cfg.spotifyRefreshToken,
              let clientId = cfg.spotifyClientId else {
            Logger.shared.log("Spotify: cannot refresh, missing refresh_token or client_id")
            return nil
        }

        let url = URL(string: "https://accounts.spotify.com/api/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refresh)&client_id=\(clientId)"
        request.httpBody = body.data(using: .utf8)

        var newToken: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double else {
                Logger.shared.log("Spotify: refresh failed")
                return
            }
            cfg.spotifyAccessToken = access
            cfg.spotifyTokenExpiry = Date().addingTimeInterval(expiresIn).timeIntervalSince1970
            if let newRefresh = json["refresh_token"] as? String {
                cfg.spotifyRefreshToken = newRefresh
            }
            ConfigManager.shared.save(cfg)
            Logger.shared.log("Spotify: token refreshed")
            newToken = access
        }.resume()
        sem.wait()
        return newToken
    }

    // MARK: - Playback control

    func play(contextURI: String? = nil, trackURIs: [String]? = nil, deviceId: String? = nil) {
        playInternal(contextURI: contextURI, trackURIs: trackURIs, deviceId: deviceId, alreadyRetried: false)
    }

    private func playInternal(contextURI: String?, trackURIs: [String]?, deviceId: String?, alreadyRetried: Bool) {
        guard let token = validAccessToken() else {
            Logger.shared.log("Spotify play: not authorized")
            return
        }

        var endpoint = "https://api.spotify.com/v1/me/player/play"
        if let dev = deviceId {
            endpoint += "?device_id=\(dev)"
        }
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let c = contextURI { body["context_uri"] = c }
        if let t = trackURIs { body["uris"] = t }
        if !body.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            // Empty body = resume current playback; Spotify requires explicit empty JSON object
            request.httpBody = "{}".data(using: .utf8)
        }

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 204 || status == 202 {
                Logger.shared.log("Spotify play: success")
                return
            }
            if status == 404 && !alreadyRetried {
                Logger.shared.log("Spotify play: no active device, locating one")
                self.findFirstDevice { devId in
                    if let id = devId {
                        Logger.shared.log("Spotify play: retrying on device \(id)")
                        self.playInternal(contextURI: contextURI, trackURIs: trackURIs, deviceId: id, alreadyRetried: true)
                    } else {
                        Logger.shared.log("Spotify play: no devices found, launching desktop app")
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(URL(string: "spotify:")!)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.findFirstDevice { devId2 in
                                if let id2 = devId2 {
                                    self.playInternal(contextURI: contextURI, trackURIs: trackURIs, deviceId: id2, alreadyRetried: true)
                                } else {
                                    Logger.shared.log("Spotify play: still no devices after launch")
                                }
                            }
                        }
                    }
                }
                return
            }
            let bodyStr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
            Logger.shared.log("Spotify play: HTTP \(status) \(bodyStr)")
        }.resume()
    }

    func pause() { simpleCommand(method: "PUT", path: "/v1/me/player/pause") }
    func next() { simpleCommand(method: "POST", path: "/v1/me/player/next") }
    func previous() { simpleCommand(method: "POST", path: "/v1/me/player/previous") }

    private func simpleCommand(method: String, path: String) {
        guard let token = validAccessToken() else { return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Logger.shared.log("Spotify \(method) \(path): HTTP \(status)")
        }.resume()
    }

    func findFirstDevice(completion: @escaping (String?) -> Void) {
        guard let token = validAccessToken() else { completion(nil); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/devices")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["devices"] as? [[String: Any]] else {
                completion(nil); return
            }
            let active = devices.first(where: { ($0["is_active"] as? Bool) == true })
            let chosen = active ?? devices.first
            completion(chosen?["id"] as? String)
        }.resume()
    }

    func fetchCurrentPlayback(completion: @escaping ([String: Any]?) -> Void) {
        guard let token = validAccessToken() else { completion(nil); return }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 204 { completion(nil); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil); return
            }
            completion(json)
        }.resume()
    }
}

// MARK: - Spotify API Client

class SpotifyAPIClient {
    private var cachedToken: String?
    private var tokenExpiry: Date?

    func searchFirstMatch(query: String, clientId: String, clientSecret: String) -> String? {
        let token = fetchToken(clientId: clientId, clientSecret: clientSecret)
        guard let t = token else {
            Logger.shared.log("Spotify API: failed to get token")
            return nil
        }
        return searchAll(query: query, token: t)
    }

    private func fetchToken(clientId: String, clientSecret: String) -> String? {
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
            self.tokenExpiry = Date().addingTimeInterval(expiresIn - 60)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }

    private func searchAll(query: String, token: String) -> String? {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "https://api.spotify.com/v1/search?q=\(encodedQuery)&type=artist,playlist,album,track&limit=3")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        var result: String?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            defer { semaphore.signal() }
            if let error = error {
                Logger.shared.log("Spotify search error: \(error)")
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                Logger.shared.log("Spotify search: bad JSON")
                return
            }
            if let errorObj = json["error"] as? [String: Any] {
                Logger.shared.log("Spotify search API error: \(errorObj)")
                return
            }

            let lowerQuery = query.lowercased()

            func items(_ key: String) -> [[String: Any]] {
                guard let group = json[key] as? [String: Any],
                      let raw = group["items"] as? [Any] else { return [] }
                return raw.compactMap { $0 as? [String: Any] }
            }

            // Priority 1: artist — but only if name resembles query
            for artist in items("artists") {
                if let name = artist["name"] as? String,
                   let uri = artist["uri"] as? String {
                    let lowerName = name.lowercased()
                    if lowerName == lowerQuery
                        || lowerQuery.contains(lowerName)
                        || lowerName.contains(lowerQuery) {
                        Logger.shared.log("Spotify search: matched artist '\(name)' → \(uri)")
                        result = uri
                        return
                    }
                }
            }

            // Priority 2: playlist
            if let p = items("playlists").first,
               let uri = p["uri"] as? String, let name = p["name"] as? String {
                Logger.shared.log("Spotify search: matched playlist '\(name)' → \(uri)")
                result = uri
                return
            }

            // Priority 3: album
            if let a = items("albums").first,
               let uri = a["uri"] as? String, let name = a["name"] as? String {
                Logger.shared.log("Spotify search: matched album '\(name)' → \(uri)")
                result = uri
                return
            }

            // Priority 4: track
            if let t = items("tracks").first,
               let uri = t["uri"] as? String, let name = t["name"] as? String {
                Logger.shared.log("Spotify search: matched track '\(name)' → \(uri)")
                result = uri
                return
            }

            // Priority 5: top artist even without name match (last resort)
            if let a = items("artists").first,
               let uri = a["uri"] as? String, let name = a["name"] as? String {
                Logger.shared.log("Spotify search: fallback to top artist '\(name)' → \(uri)")
                result = uri
                return
            }

            Logger.shared.log("Spotify search: no results for '\(query)'")
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

// MARK: - Local Backend

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
                MPMediaItemPropertyArtist: "Nik Music",
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

// MARK: - Spotify Backend

class SpotifyBackend: NSObject, MusicBackend {
    var config: AppConfig
    let apiClient = SpotifyAPIClient()
    let webAPI = SpotifyWebAPI.shared

    private var cachedIsPlaying = false
    private var cachedTrackName: String?
    private var pollTimer: Timer?

    init(config: AppConfig) {
        self.config = config
        super.init()
        refreshPlaybackState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshPlaybackState()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    private func refreshPlaybackState() {
        guard webAPI.isAuthorized else { return }
        webAPI.fetchCurrentPlayback { [weak self] state in
            guard let self = self else { return }
            let playing = (state?["is_playing"] as? Bool) ?? false
            var trackName: String?
            if let item = state?["item"] as? [String: Any], let name = item["name"] as? String {
                let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                trackName = artists.isEmpty ? name : "\(name) — \(artists.joined(separator: ", "))"
            }
            let changed = (playing != self.cachedIsPlaying) || (trackName != self.cachedTrackName)
            self.cachedIsPlaying = playing
            self.cachedTrackName = trackName
            if changed {
                DispatchQueue.main.async {
                    NikMusicController.shared.updateMenu()
                }
            }
        }
    }

    func play() {
        config = ConfigManager.shared.load()
        guard webAPI.isAuthorized else {
            Logger.shared.log("Spotify: not authorized — click 'Authorize Spotify…' in the menu")
            DispatchQueue.main.async {
                NikMusicController.shared.notify(title: "Nik-Music", body: "Spotify not authorized — open the menubar and click 'Authorize Spotify…'.")
            }
            return
        }

        // Priority 1: explicit URI
        if let uri = config.spotifyUri, !uri.isEmpty {
            Logger.shared.log("Spotify: playing explicit URI \(uri)")
            playURI(uri)
            return
        }

        // Priority 2: search query
        if let query = config.spotifySearchQuery, !query.isEmpty,
           let clientId = config.spotifyClientId, !clientId.isEmpty,
           let clientSecret = config.spotifyClientSecret, !clientSecret.isEmpty {
            Logger.shared.log("Spotify: searching for '\(query)'")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                if let uri = self.apiClient.searchFirstMatch(query: query, clientId: clientId, clientSecret: clientSecret) {
                    Logger.shared.log("Spotify: playing search result \(uri)")
                    self.playURI(uri)
                } else {
                    Logger.shared.log("Spotify: search returned nothing")
                }
            }
            return
        }

        // Priority 3: just resume whatever was last playing
        webAPI.play()
    }

    private func playURI(_ uri: String) {
        if uri.hasPrefix("spotify:track:") {
            webAPI.play(trackURIs: [uri])
        } else {
            webAPI.play(contextURI: uri)
        }
    }

    func pause() {
        webAPI.pause()
        Logger.shared.log("Spotify: pause")
    }

    func stop() {
        Logger.shared.log("Spotify: stop (no-op)")
    }

    func nextTrack() {
        webAPI.next()
        Logger.shared.log("Spotify: next")
    }

    func previousTrack() {
        webAPI.previous()
        Logger.shared.log("Spotify: previous")
    }

    var isPlaying: Bool { cachedIsPlaying }
    var currentTrackName: String? { cachedTrackName }
}

// MARK: - NikMusicController

class NikMusicController: NSObject, NSMenuDelegate {
    static let shared = NikMusicController()

    var statusItem: NSStatusItem?
    var backend: MusicBackend?
    var config = AppConfig()
    var isHeadphonesConnected = false
    var isManuallyPaused = false
    var lastDeviceName = ""
    var mcpServer = MCPHTTPServer()
    var mcpToggleItem: NSMenuItem!
    var mcpPortItem: NSMenuItem!
    var authorizeSpotifyItem: NSMenuItem!

    let headphoneKeywords = [
        "headphone", "external headphones", "airpods", "earbuds",
        "beats", "bose", "sony", "jbl", "sennheiser", "buds",
        "in-ear", "skullcandy", "anker", "pixel buds", "galaxy buds",
        "wh-", "xm5", "xm4", "xm3", "over-ear", "bluetooth headset"
    ]

    func setup() {
        Logger.shared.log("=== Nik-Music starting ===")
        config = ConfigManager.shared.load()
        setupMenuBar()
        setupMediaKeys()
        createBackend()
        startOutputDeviceListener()
        startPolling()
        checkOutputDevice()
        if config.mcpAutoStart {
            Logger.shared.log("MCP autostart enabled, starting server")
            startMCP(announceSuccess: false)
        }
    }

    func createBackend() {
        config = ConfigManager.shared.load()
        switch config.source {
        case .local:
            let folder = config.musicFolder.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Focus")
            backend = LocalBackend(musicDirectory: folder, shuffle: config.shuffle)
        case .spotify:
            backend = SpotifyBackend(config: config)
            clearNowPlayingInfo()
        }
        Logger.shared.log("Backend: \(config.source.displayName)")
    }

    func switchSource(_ source: MusicSource) {
        config = ConfigManager.shared.load()
        config.source = source
        ConfigManager.shared.save(config)
        if let local = backend as? LocalBackend {
            local.stop()
        } else {
            backend?.stop()
        }
        createBackend()
        updateMenu()
        notify(title: "Nik Music", body: "Switched to \(source.displayName)")
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

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

    var nowPlayingItem: NSMenuItem!
    var playPauseItem: NSMenuItem!

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🎵"

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Nik Music", action: nil, keyEquivalent: "")
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

        authorizeSpotifyItem = NSMenuItem(title: "Authorize Spotify…", action: #selector(authorizeSpotify), keyEquivalent: "")
        authorizeSpotifyItem.target = self
        menu.addItem(authorizeSpotifyItem)

        menu.addItem(NSMenuItem.separator())

        // MCP Server submenu
        let mcpMenu = NSMenu(title: "MCP Server")
        mcpToggleItem = NSMenuItem(title: "Start MCP Server", action: #selector(toggleMCP), keyEquivalent: "")
        mcpToggleItem.target = self
        mcpMenu.addItem(mcpToggleItem)

        mcpPortItem = NSMenuItem(title: "Port: —", action: nil, keyEquivalent: "")
        mcpPortItem.isEnabled = false
        mcpMenu.addItem(mcpPortItem)

        let copyConfig = NSMenuItem(title: "Copy MCP Config", action: #selector(copyMCPConfig), keyEquivalent: "")
        copyConfig.target = self
        mcpMenu.addItem(copyConfig)

        let mcpItem = NSMenuItem(title: "MCP Server", action: nil, keyEquivalent: "")
        mcpItem.submenu = mcpMenu
        menu.addItem(mcpItem)

        menu.addItem(NSMenuItem.separator())

        let openFolder = NSMenuItem(title: "Open Music Folder", action: #selector(openFolder), keyEquivalent: "o")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self
        statusItem?.menu = menu
        updateMenu()
    }

    @objc func menuWillOpen(_ menu: NSMenu) {
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
        let baseIcon = (backend?.isPlaying ?? false) ? "🎧" : "🎵"
        statusItem?.button?.title = mcpServer.isRunning ? "\(baseIcon)ᴹ" : baseIcon

        // Update MCP menu
        if mcpServer.isRunning {
            mcpToggleItem.title = "Stop MCP Server"
            mcpPortItem.title = "Port: \(mcpServer.port) (localhost only)"
        } else {
            mcpToggleItem.title = "Start MCP Server"
            mcpPortItem.title = "Port: —"
        }

        if authorizeSpotifyItem != nil {
            authorizeSpotifyItem.title = SpotifyWebAPI.shared.isAuthorized
                ? "Re-authorize Spotify…"
                : "Authorize Spotify…"
        }

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

    @objc func toggleMCP() {
        if mcpServer.isRunning {
            mcpServer.stop()
            config = ConfigManager.shared.load()
            config.mcpAutoStart = false
            ConfigManager.shared.save(config)
            notify(title: "Nik-Music MCP", body: "MCP server stopped.")
            updateMenu()
        } else {
            startMCP(announceSuccess: true)
        }
    }

    func startMCP(announceSuccess: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let preferred = self.config.mcpPort ?? 8765
            let actual = self.mcpServer.start(preferredPort: preferred)
            DispatchQueue.main.async {
                if actual > 0 {
                    self.config = ConfigManager.shared.load()
                    self.config.mcpPort = actual
                    self.config.mcpAutoStart = true
                    ConfigManager.shared.save(self.config)
                    if announceSuccess {
                        self.notify(title: "Nik-Music MCP", body: "Server running on http://127.0.0.1:\(actual)/sse")
                    }
                } else {
                    self.notify(title: "Nik-Music MCP", body: "Failed to start MCP server. No available port.")
                }
                self.updateMenu()
            }
        }
    }

    @objc func authorizeSpotify() {
        let cfg = ConfigManager.shared.load()
        guard let clientId = cfg.spotifyClientId, !clientId.isEmpty else {
            notify(title: "Nik-Music", body: "No Spotify client ID in ~/.nikmusic.json.")
            return
        }

        let openBrowser = { [weak self] in
            guard let self = self, let url = SpotifyWebAPI.shared.buildAuthorizeURL(clientId: clientId) else { return }
            Logger.shared.log("Spotify auth: opening \(url.absoluteString)")
            NSWorkspace.shared.open(url)
            self.notify(title: "Nik-Music", body: "Approve in your browser. The page will say 'Authorized' when done.")
        }

        if mcpServer.isRunning {
            openBrowser()
        } else {
            // The OAuth callback lands on the MCP server, so it must be up first.
            startMCP(announceSuccess: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: openBrowser)
        }
    }

    @objc func copyMCPConfig() {
        let port = mcpServer.isRunning ? mcpServer.port : (config.mcpPort ?? 8765)
        let json = """
        {
          "mcpServers": {
            "nik-music": {
              "url": "http://127.0.0.1:\(port)/sse"
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        notify(title: "Nik-Music MCP", body: "Config copied to clipboard! Paste it into Claude Desktop or Cursor settings.")
    }

    @objc func openFolder() {
        let folder = config.musicFolder.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music/Focus")
        NSWorkspace.shared.open(folder)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func notify(title: String, body: String) {
        Logger.shared.log("Notify: \(title) - \(body)")
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = nil
        NSUserNotificationCenter.default.deliver(notification)
    }

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
                self.notify(title: "Nik Music Paused", body: "Microphone is now in use (call started).")
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
        config = ConfigManager.shared.load()
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
                notify(title: "🎧 Nik Music", body: "Headphones detected. Starting your focus session.")
                backend?.play()
            } else {
                notify(title: "🎧 Nik Music", body: "Headphones detected, but you're in a call. Auto-play will resume when the mic is free.")
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
        NikMusicController.shared.setup()
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
