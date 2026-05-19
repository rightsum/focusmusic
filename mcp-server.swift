import Foundation
import Network
import Cocoa
import CoreAudio

// MARK: - Minimal Helpers (shared with main.swift)

func getDefaultOutputDeviceName() -> String {
    var deviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address = AudioObjectPropertyAddress(
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
    let keywords = [
        "headphone", "external headphones", "airpods", "earbuds",
        "beats", "bose", "sony", "jbl", "sennheiser", "buds",
        "in-ear", "skullcandy", "anker", "pixel buds", "galaxy buds",
        "wh-", "xm5", "xm4", "xm3", "over-ear", "bluetooth headset"
    ]
    let lower = name.lowercased()
    return keywords.contains { lower.contains($0) }
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

func spotifyRunScript(_ source: String) -> String? {
    let script = NSAppleScript(source: source)
    var errorInfo: NSDictionary?
    let result = script?.executeAndReturnError(&errorInfo)
    if let error = errorInfo {
        return "error: \(error)"
    }
    return result?.stringValue
}

func spotifyIsRunning() -> Bool {
    let apps = NSWorkspace.shared.runningApplications
    return apps.contains { $0.localizedName == "Spotify" }
}

func spotifyPlay(uri: String? = nil) -> String {
    if let u = uri, !u.isEmpty {
        let result = spotifyRunScript("tell application \"Spotify\" to play track \"\(u)\"")
        return result ?? "ok"
    }
    if !spotifyIsRunning() {
        _ = spotifyRunScript("tell application \"Spotify\" to activate")
        Thread.sleep(forTimeInterval: 2.0)
    }
    let result = spotifyRunScript("tell application \"Spotify\" to play")
    return result ?? "ok"
}

func spotifyPause() -> String {
    guard spotifyIsRunning() else { return "not running" }
    let result = spotifyRunScript("tell application \"Spotify\" to pause")
    return result ?? "ok"
}

func spotifyNext() -> String {
    guard spotifyIsRunning() else { return "not running" }
    let result = spotifyRunScript("tell application \"Spotify\" to next track")
    return result ?? "ok"
}

func spotifyPrevious() -> String {
    guard spotifyIsRunning() else { return "not running" }
    let result = spotifyRunScript("tell application \"Spotify\" to previous track")
    return result ?? "ok"
}

func spotifyGetState() -> [String: Any] {
    guard spotifyIsRunning() else {
        return ["running": false, "playing": false]
    }
    let state = spotifyRunScript("tell application \"Spotify\" to return player state as string")
    let name = spotifyRunScript("tell application \"Spotify\" to return name of current track")
    let artist = spotifyRunScript("tell application \"Spotify\" to return artist of current track")
    let uri = spotifyRunScript("tell application \"Spotify\" to return spotify url of current track")
    return [
        "running": true,
        "playing": state?.lowercased() == "playing",
        "track": name ?? "unknown",
        "artist": artist ?? "unknown",
        "uri": uri ?? "unknown"
    ]
}

// MARK: - MCP HTTP Server (Network.framework)

class MCPHTTPServer: NSObject {
    var listener: NWListener?
    var isRunning = false
    var port: UInt16 = 0
    var sseConnections: [String: NWConnection] = [:]
    var nextSessionId = 1

    func start(preferredPort: UInt16 = 8765) -> UInt16 {
        guard !isRunning else { return port }

        let actualPort = findAvailablePort(preferred: preferredPort)
        guard actualPort > 0 else {
            Logger.shared.log("MCP: could not find available port")
            return 0
        }

        guard let portObj = NWEndpoint.Port(rawValue: actualPort) else {
            Logger.shared.log("MCP: invalid port \(actualPort)")
            return 0
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: portObj)
        } catch {
            Logger.shared.log("MCP: listener creation failed: \(error)")
            return 0
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Logger.shared.log("MCP: listener ready on port \(actualPort)")
            case .failed(let err):
                Logger.shared.log("MCP: listener failed: \(err)")
                self?.stop()
            case .cancelled:
                Logger.shared.log("MCP: listener cancelled")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global())
        port = actualPort
        isRunning = true
        Logger.shared.log("MCP: server started on http://127.0.0.1:\(port)/sse")
        return actualPort
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (_, conn) in sseConnections {
            conn.cancel()
        }
        sseConnections.removeAll()
        listener?.cancel()
        listener = nil
        Logger.shared.log("MCP: server stopped")
    }

    private func findAvailablePort(preferred: UInt16) -> UInt16 {
        if isPortAvailable(preferred) { return preferred }
        for _ in 0..<50 {
            let p = UInt16.random(in: 8000..<9000)
            if isPortAvailable(p) { return p }
        }
        return 0
    }

    private func isPortAvailable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian),
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        receiveHTTPRequest(connection: connection, buffer: Data())
    }

    private func receiveHTTPRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                Logger.shared.log("MCP: receive error: \(error)")
                connection.cancel()
                return
            }

            var newBuffer = buffer
            if let data = data {
                newBuffer.append(data)
            }

            // Check if we have a complete HTTP request header
            guard let requestStr = String(data: newBuffer, encoding: .utf8),
                  let headerEnd = requestStr.range(of: "\r\n\r\n") else {
                // Need more data
                if isComplete {
                    connection.cancel()
                    return
                }
                self.receiveHTTPRequest(connection: connection, buffer: newBuffer)
                return
            }

            let headers = String(requestStr[..<headerEnd.upperBound])
            let bodyStart = requestStr.index(headerEnd.upperBound, offsetBy: 0)
            let remaining = String(requestStr[bodyStart...])
            let remainingData = remaining.data(using: .utf8) ?? Data()

            self.processRequest(connection: connection, headers: headers, initialBody: remainingData)
        }
    }

    private func processRequest(connection: NWConnection, headers: String, initialBody: Data) {
        let lines = headers.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            connection.cancel()
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        if method == "GET" && path == "/sse" {
            handleSSE(connection: connection)
        } else if method == "POST" && path.hasPrefix("/message") {
            handleMessage(connection: connection, headers: headers, initialBody: initialBody)
        } else if method == "GET" && path.hasPrefix("/callback") {
            handleOAuthCallback(connection: connection, path: path)
        } else {
            sendHTTP(connection: connection, status: "404 Not Found", body: "")
        }
    }

    private func handleOAuthCallback(connection: NWConnection, path: String) {
        var code: String?
        var state: String?
        var oauthError: String?
        if let qStart = path.firstIndex(of: "?") {
            let query = path[path.index(after: qStart)...]
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = String(kv[0])
                let raw = String(kv[1])
                let value = raw.removingPercentEncoding ?? raw
                switch key {
                case "code": code = value
                case "state": state = value
                case "error": oauthError = value
                default: break
                }
            }
        }

        if let err = oauthError {
            sendHTML(connection: connection, status: "200 OK",
                     html: "<h1>Authorization failed</h1><p>\(err)</p>")
            Logger.shared.log("Spotify auth: error \(err)")
            return
        }
        guard let code = code, let state = state else {
            sendHTML(connection: connection, status: "400 Bad Request",
                     html: "<h1>Missing parameters</h1>")
            return
        }
        let cfg = ConfigManager.shared.load()
        guard let clientId = cfg.spotifyClientId else {
            sendHTML(connection: connection, status: "500 Internal Server Error",
                     html: "<h1>No Spotify client ID configured</h1>")
            return
        }

        SpotifyWebAPI.shared.handleAuthorizationCode(code: code, state: state, clientId: clientId) { [weak self] success, msg in
            if success {
                self?.sendHTML(connection: connection, status: "200 OK", html: """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding: 80px;">
                <h1>✅ Authorized</h1>
                <p>You can close this tab and return to Nik-Music.</p>
                </body></html>
                """)
                DispatchQueue.main.async {
                    NikMusicController.shared.notify(title: "Nik-Music", body: "Spotify authorized.")
                    NikMusicController.shared.updateMenu()
                }
            } else {
                self?.sendHTML(connection: connection, status: "200 OK", html: """
                <html><body style="font-family: -apple-system, sans-serif; text-align: center; padding: 80px;">
                <h1>❌ Authorization failed</h1>
                <p>\(msg)</p>
                </body></html>
                """)
            }
        }
    }

    private func sendHTML(connection: NWConnection, status: String, html: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleSSE(connection: NWConnection) {
        let sessionId = "session-\(nextSessionId)"
        nextSessionId += 1
        sseConnections[sessionId] = connection

        let response = """
        HTTP/1.1 200 OK\r\n\
        Content-Type: text/event-stream\r\n\
        Cache-Control: no-cache\r\n\
        Connection: keep-alive\r\n\r\n
        """
        let endpointEvent = "event: endpoint\ndata: /message?session_id=\(sessionId)\n\n"

        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            if let error = error {
                Logger.shared.log("MCP: SSE send error: \(error)")
                self?.sseConnections.removeValue(forKey: sessionId)
                connection.cancel()
                return
            }
            connection.send(content: Data(endpointEvent.utf8), completion: .contentProcessed { error in
                if let error = error {
                    Logger.shared.log("MCP: SSE endpoint event error: \(error)")
                    self?.sseConnections.removeValue(forKey: sessionId)
                    connection.cancel()
                }
            })
        })
    }

    private func handleMessage(connection: NWConnection, headers: String, initialBody: Data) {
        let contentLength = parseContentLength(headers: headers)

        readFullBody(connection: connection, expected: contentLength, soFar: initialBody) { [weak self] bodyData in
            guard let self = self else { return }
            self.processMessageBody(connection: connection, headers: headers, body: bodyData)
        }
    }

    private func parseContentLength(headers: String) -> Int {
        for line in headers.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "content-length" {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func readFullBody(connection: NWConnection, expected: Int, soFar: Data, completion: @escaping (Data) -> Void) {
        if soFar.count >= expected {
            completion(soFar.prefix(expected))
            return
        }
        let needed = expected - soFar.count
        connection.receive(minimumIncompleteLength: 1, maximumLength: needed) { [weak self] data, _, isComplete, error in
            if let error = error {
                Logger.shared.log("MCP: body receive error: \(error)")
                completion(soFar)
                return
            }
            var buffer = soFar
            if let data = data { buffer.append(data) }
            if buffer.count >= expected || isComplete {
                completion(buffer.prefix(expected))
            } else {
                self?.readFullBody(connection: connection, expected: expected, soFar: buffer, completion: completion)
            }
        }
    }

    private func processMessageBody(connection: NWConnection, headers: String, body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let preview = String(data: body.prefix(120), encoding: .utf8) ?? "<non-utf8>"
            Logger.shared.log("MCP: 400 bad body (len=\(body.count)): \(preview)")
            sendHTTP(connection: connection, status: "400 Bad Request", body: "")
            return
        }

        let responseJson = processJSONRPC(json)
        guard let responseData = try? JSONSerialization.data(withJSONObject: responseJson),
              let responseStr = String(data: responseData, encoding: .utf8) else {
            sendHTTP(connection: connection, status: "500 Internal Server Error", body: "")
            return
        }

        sendHTTP(connection: connection, status: "202 Accepted", body: "")

        if let sessionId = extractSessionId(from: headers),
           let sseConn = sseConnections[sessionId] {
            let sseEvent = "event: message\ndata: \(responseStr)\n\n"
            sseConn.send(content: Data(sseEvent.utf8), completion: .contentProcessed { _ in })
        }
    }

    private func extractSessionId(from headers: String) -> String? {
        // Look for session_id in the request line or headers
        if let match = headers.range(of: "session_id=") {
            let start = match.upperBound
            let remainder = String(headers[start...])
            if let end = remainder.range(of: " ") ?? remainder.range(of: "\r\n") {
                return String(remainder[..<end.lowerBound])
            }
            return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func sendHTTP(connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func processJSONRPC(_ json: [String: Any]) -> [String: Any] {
        guard let method = json["method"] as? String else {
            return makeErrorResponse(id: json["id"] as? Int, code: -32600, message: "Invalid Request")
        }

        let id = json["id"] as? Int

        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "nik-music-mcp", "version": "1.0.0"]
                ]
            ]

        case "tools/list":
            let tools: [[String: Any]] = [
                [
                    "name": "get_status",
                    "description": "Get current Nik-Music status including source, config, headphone connection, and mic state.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "set_source",
                    "description": "Change music source between local files and Spotify.",
                    "inputSchema": [
                        "type": "object",
                        "required": ["source"],
                        "properties": ["source": ["type": "string", "enum": ["local", "spotify"]]]
                    ]
                ],
                [
                    "name": "set_spotify_search",
                    "description": "Set a Spotify search query and start playing it immediately (switches source to Spotify if needed). With API credentials, plays the first matching playlist; without credentials, opens the search page in Spotify. Set play_now=false to only stage the query without playing.",
                    "inputSchema": [
                        "type": "object",
                        "required": ["query"],
                        "properties": [
                            "query": ["type": "string"],
                            "play_now": ["type": "boolean", "default": true]
                        ]
                    ]
                ],
                [
                    "name": "set_spotify_uri",
                    "description": "Set an explicit Spotify URI (playlist, album, or track) and play it immediately (switches source to Spotify if needed). Set play_now=false to only stage the URI without playing.",
                    "inputSchema": [
                        "type": "object",
                        "required": ["uri"],
                        "properties": [
                            "uri": ["type": "string"],
                            "play_now": ["type": "boolean", "default": true]
                        ]
                    ]
                ],
                [
                    "name": "play",
                    "description": "Start or resume playback on Spotify.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "pause",
                    "description": "Pause playback on Spotify.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "next_track",
                    "description": "Skip to the next track on Spotify.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ],
                [
                    "name": "previous_track",
                    "description": "Go to the previous track on Spotify.",
                    "inputSchema": ["type": "object", "properties": [:]]
                ]
            ]
            return ["jsonrpc": "2.0", "id": id as Any, "result": ["tools": tools]]

        case "tools/call":
            guard let params = json["params"] as? [String: Any],
                  let name = params["name"] as? String,
                  let arguments = params["arguments"] as? [String: Any] else {
                return makeErrorResponse(id: id, code: -32602, message: "Invalid params")
            }
            let result = handleToolCall(name: name, arguments: arguments)
            return ["jsonrpc": "2.0", "id": id as Any, "result": result]

        default:
            return makeErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func makeErrorResponse(id: Int?, code: Int, message: String) -> [String: Any] {
        var result: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        if let id = id { result["id"] = id }
        return result
    }

    private func handleToolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        switch name {
        case "get_status":
            let config = ConfigManager.shared.load()
            let deviceName = getDefaultOutputDeviceName()
            var status: [String: Any] = [
                "source": config.source.rawValue,
                "headphones_connected": isHeadphoneDevice(name: deviceName),
                "output_device": deviceName,
                "mic_in_use": isMicInUse(),
                "config": [
                    "spotifyUri": config.spotifyUri as Any,
                    "spotifySearchQuery": config.spotifySearchQuery as Any,
                    "musicFolder": config.musicFolder as Any,
                    "shuffle": config.shuffle
                ]
            ]
            if config.source == .spotify, spotifyIsRunning() {
                status["spotify_state"] = spotifyGetState()
            }
            return toolResult(text: jsonString(status) ?? "{}")

        case "set_source":
            if let sourceStr = arguments["source"] as? String,
               let source = MusicSource(rawValue: sourceStr) {
                DispatchQueue.main.async {
                    NikMusicController.shared.switchSource(source)
                }
                return toolResult(text: "Switched to \(source.displayName)")
            }
            return toolResult(text: "Invalid source. Use 'local' or 'spotify'.", isError: true)

        case "set_spotify_search":
            if let query = arguments["query"] as? String {
                var config = ConfigManager.shared.load()
                config.spotifySearchQuery = query
                config.spotifyUri = nil
                ConfigManager.shared.save(config)
                let playNow = arguments["play_now"] as? Bool ?? true
                if playNow {
                    DispatchQueue.main.async {
                        if NikMusicController.shared.config.source != .spotify {
                            NikMusicController.shared.switchSource(.spotify)
                        }
                        NikMusicController.shared.backend?.play()
                    }
                    return toolResult(text: "Search set to '\(query)' and now playing on Spotify.")
                }
                return toolResult(text: "Search set to '\(query)'. Will take effect on next headphone connect.")
            }
            return toolResult(text: "Missing 'query' argument.", isError: true)

        case "set_spotify_uri":
            if let uri = arguments["uri"] as? String {
                var config = ConfigManager.shared.load()
                config.spotifyUri = uri
                config.spotifySearchQuery = nil
                ConfigManager.shared.save(config)
                let playNow = arguments["play_now"] as? Bool ?? true
                if playNow {
                    DispatchQueue.main.async {
                        if NikMusicController.shared.config.source != .spotify {
                            NikMusicController.shared.switchSource(.spotify)
                        }
                        NikMusicController.shared.backend?.play()
                    }
                    return toolResult(text: "URI set to \(uri) and now playing on Spotify.")
                }
                return toolResult(text: "URI set to \(uri). Will take effect on next headphone connect.")
            }
            return toolResult(text: "Missing 'uri' argument.", isError: true)

        case "play":
            DispatchQueue.main.async { NikMusicController.shared.backend?.play() }
            return toolResult(text: "Play requested.")

        case "pause":
            DispatchQueue.main.async { NikMusicController.shared.backend?.pause() }
            return toolResult(text: "Pause requested.")

        case "next_track":
            DispatchQueue.main.async { NikMusicController.shared.backend?.nextTrack() }
            return toolResult(text: "Next track requested.")

        case "previous_track":
            DispatchQueue.main.async { NikMusicController.shared.backend?.previousTrack() }
            return toolResult(text: "Previous track requested.")

        default:
            return toolResult(text: "Unknown tool: \(name)", isError: true)
        }
    }

    private func toolResult(text: String, isError: Bool = false) -> [String: Any] {
        return [
            "content": [
                [
                    "type": "text",
                    "text": text,
                    "isError": isError
                ]
            ],
            "isError": isError
        ]
    }

    private func jsonString(_ obj: [String: Any]) -> String? {
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }
}
