import Foundation
import Network
import CommonCrypto

/// Servidor HTTP e WebSocket 100% Nativo em Swift para Controle Remoto Mobile (Android / iOS / Web).
/// Substitui completamente FastAPI, Uvicorn e Starlette do Python sem dependências externas.
public final class NativeRemoteServer {
    public static let shared = NativeRemoteServer()
    
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.vscontrol.remoteserver", qos: .userInitiated)
    private var activeConnections: [ObjectIdentifier: RemoteConnection] = [:]
    private let lock = NSLock()
    
    public var port: UInt16 = 8080
    public private(set) var isRunning = false
    
    private init() {}
    
    public func start(port: UInt16 = 8080) {
        self.port = port
        guard listener == nil else { return }
        
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            
            let nwListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            nwListener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("🚀 [NativeRemoteServer] Servidor nativo ouvindo na porta \(port)")
                    self?.isRunning = true
                    self?.startBroadcastTimer()
                case .failed(let error):
                    print("❌ [NativeRemoteServer] Falha ao iniciar: \(error.localizedDescription)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            nwListener.start(queue: queue)
            self.listener = nwListener
        } catch {
            print("❌ [NativeRemoteServer] Erro ao criar listener: \(error)")
        }
    }
    
    public func stop() {
        stopBroadcastTimer()
        listener?.cancel()
        listener = nil
        lock.lock()
        for conn in activeConnections.values {
            conn.cancel()
        }
        activeConnections.removeAll()
        lock.unlock()
        isRunning = false
    }
    
    private var broadcastTimer: DispatchSourceTimer?
    
    private func startBroadcastTimer() {
        stopBroadcastTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let conns = Array(self.activeConnections.values)
            self.lock.unlock()
            
            let wsConns = conns.filter { $0.isWebSocket }
            guard !wsConns.isEmpty else { return }
            
            let status = NativeAudioEngine.shared.buildStatusDictionary()
            let payload: [String: Any] = [
                "event": "tick",
                "data": status
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: data, encoding: .utf8) {
                for c in wsConns {
                    c.sendWebSocketText(str)
                }
            }
        }
        timer.resume()
        self.broadcastTimer = timer
    }
    
    private func stopBroadcastTimer() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let conn = RemoteConnection(connection: connection, server: self)
        let id = ObjectIdentifier(conn)
        lock.lock()
        activeConnections[id] = conn
        lock.unlock()
        conn.start()
    }
    
    fileprivate func removeConnection(_ conn: RemoteConnection) {
        let id = ObjectIdentifier(conn)
        lock.lock()
        activeConnections.removeValue(forKey: id)
        lock.unlock()
    }
    
    /// Envia o status do player via WebSocket para todos os dispositivos móveis conectados
    public func broadcastStatus(_ jsonString: String) {
        lock.lock()
        let conns = Array(activeConnections.values)
        lock.unlock()
        
        for c in conns where c.isWebSocket {
            c.sendWebSocketText(jsonString)
        }
    }
    
    /// Obtém o IP local da máquina na rede Wi-Fi / Ethernet
    public func getLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                let flags = Int32(ptr!.pointee.ifa_flags)
                let addr = ptr!.pointee.ifa_addr.pointee
                if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                    if addr.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(ptr!.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            let ip = String(cString: hostname)
                            if !ip.starts(with: "127.") && !ip.starts(with: "169.254.") {
                                address = ip
                                break
                            }
                        }
                    }
                }
                ptr = ptr!.pointee.ifa_next
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}

// MARK: - Conexão Individual (HTTP / WebSocket)
fileprivate final class RemoteConnection {
    let connection: NWConnection
    unowned let server: NativeRemoteServer
    var isWebSocket = false
    private var readBuffer = Data()
    
    init(connection: NWConnection, server: NativeRemoteServer) {
        self.connection = connection
        self.server = server
    }
    
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if let self = self {
                    self.server.removeConnection(self)
                }
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveNext()
    }
    
    func cancel() {
        connection.cancel()
    }
    
    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil {
                self.server.removeConnection(self)
                return
            }
            if let data = data, !data.isEmpty {
                self.handleIncomingData(data)
            }
            if isComplete {
                self.server.removeConnection(self)
            } else {
                self.receiveNext()
            }
        }
    }
    
    private func handleIncomingData(_ data: Data) {
        readBuffer.append(data)
        
        if isWebSocket {
            parseWebSocketFrames()
            return
        }
        
        // Verifica se completou os cabeçalhos HTTP (\r\n\r\n)
        guard let headerEndRange = readBuffer.range(of: Data([13, 10, 13, 10])) else { return }
        
        let headerData = readBuffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return }
        
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return }
        let parts = reqLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let urlPath = parts[1]
        
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 {
                headers[kv[0].lowercased()] = kv[1]
            }
        }
        
        let bodyStart = headerEndRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        if readBuffer.count < bodyStart + contentLength {
            // Aguarda mais dados do corpo HTTP POST
            return
        }
        
        let bodyData = readBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        readBuffer.removeSubrange(0..<(bodyStart + contentLength))
        
        // Verifica Upgrade para WebSocket
        if headers["upgrade"]?.lowercased() == "websocket", let wsKey = headers["sec-websocket-key"] {
            handleWebSocketHandshake(key: wsKey)
            return
        }
        
        // Roteamento HTTP
        handleHttpRequest(method: method, path: urlPath, headers: headers, body: bodyData)
    }
    
    // MARK: - Handshake e Frames WebSocket
    private func handleWebSocketHandshake(key: String) {
        let magic = key.trimmingCharacters(in: .whitespacesAndNewlines) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        guard let magicData = magic.data(using: .utf8) else { return }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        magicData.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(magicData.count), &digest) }
        let acceptKey = Data(digest).base64EncodedString()
        
        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
                       "Upgrade: websocket\r\n" +
                       "Connection: Upgrade\r\n" +
                       "Sec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        
        if let respData = response.data(using: .utf8) {
            connection.send(content: respData, completion: .contentProcessed { [weak self] _ in
                self?.isWebSocket = true
                // Envia imediatamente o primeiro status após conectar
                self?.sendCurrentStatus()
            })
        }
    }
    
    private func parseWebSocketFrames() {
        while readBuffer.count >= 2 {
            let b0 = readBuffer[0]
            let b1 = readBuffer[1]
            
            let opcode = b0 & 0x0F
            let isMasked = (b1 & 0x80) != 0
            var payloadLen = UInt64(b1 & 0x7F)
            var offset = 2
            
            if payloadLen == 126 {
                guard readBuffer.count >= 4 else { return }
                payloadLen = UInt64(readBuffer[2]) << 8 | UInt64(readBuffer[3])
                offset = 4
            } else if payloadLen == 127 {
                guard readBuffer.count >= 10 else { return }
                var len: UInt64 = 0
                for i in 0..<8 {
                    len = (len << 8) | UInt64(readBuffer[2 + i])
                }
                payloadLen = len
                offset = 10
            }
            
            var maskKey = [UInt8]()
            if isMasked {
                guard readBuffer.count >= offset + 4 else { return }
                maskKey = [readBuffer[offset], readBuffer[offset+1], readBuffer[offset+2], readBuffer[offset+3]]
                offset += 4
            }
            
            guard readBuffer.count >= offset + Int(payloadLen) else { return }
            
            var payload = readBuffer.subdata(in: offset..<(offset + Int(payloadLen)))
            readBuffer.removeSubrange(0..<(offset + Int(payloadLen)))
            
            if isMasked {
                var bytes = [UInt8](payload)
                for i in 0..<bytes.count {
                    bytes[i] ^= maskKey[i % 4]
                }
                payload = Data(bytes)
            }
            
            if opcode == 0x08 { // Close
                connection.cancel()
                return
            } else if opcode == 0x09 { // Ping -> Pong
                sendWebSocketFrame(opcode: 0x0A, payload: payload)
            } else if opcode == 0x01 { // Text
                if let str = String(data: payload, encoding: .utf8) {
                    handleWebSocketMessage(str)
                }
            }
        }
    }
    
    func sendWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendWebSocketFrame(opcode: 0x01, payload: data)
    }
    
    private func sendWebSocketFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 65535 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .idempotent)
    }
    
    // MARK: - Tratamento de Mensagens WebSocket e Comandos
    private func handleWebSocketMessage(_ message: String) {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else { return }
        
        executeAction(action: action, payload: json)
    }
    
    private func executeAction(action: String, payload: [String: Any]) {
        DispatchQueue.main.async {
            let engine = NativeAudioEngine.shared
            
            switch action {
            case "play":
                engine.play()
            case "pause":
                engine.pause()
            case "play_pause":
                engine.togglePlayPause()
            case "stop":
                engine.stop()
            case "seek":
                if let sec = (payload["seconds"] as? Double) ?? (payload["time"] as? Double) {
                    engine.seek(to: sec)
                }
            case "trigger_cue":
                let idx = (payload["cue_idx"] as? Int) ?? (payload["cue_index"] as? Int) ?? 0
                let q = (payload["quantize"] as? Bool) ?? true
                engine.triggerCue(idx: idx, quantize: q)
            case "toggle_loop":
                let isInf = (payload["mode"] as? String == "infinite") || (payload["infinite"] as? Bool ?? false)
                let cIdx = payload["cue_idx"] as? Int
                engine.toggleLoop(cueIdx: cIdx, infinite: isInf)
            case "toggle_infinite":
                let cIdx = payload["cue_idx"] as? Int
                engine.toggleLoop(cueIdx: cIdx, infinite: true)
            case "fade_stop":
                let dur = (payload["duration"] as? Double) ?? 3.0
                engine.fadeStop(duration: dur)
            case "fade_tracks":
                let dir = (payload["direction"] as? String) ?? "toggle"
                let dur = (payload["duration"] as? Double) ?? 3.0
                engine.fadeTracks(direction: dir, duration: dur)
            case "pad":
                if let key = payload["key"] as? String {
                    let active = (payload["active"] as? Bool) ?? true
                    let vol = (payload["volume"] as? Double) ?? 0.35
                    engine.setPad(active: active, key: key, volume: Float(vol))
                }
            case "volumes":
                let cVol = (payload["click_vol"] as? Double) ?? (payload["volume_l"] as? Double) ?? Double(engine.clickVol)
                let vVol = (payload["vs_vol"] as? Double) ?? (payload["volume_r"] as? Double) ?? Double(engine.vsVol)
                let cMute = (payload["click_mute"] as? Bool) ?? engine.clickMute
                let vMute = (payload["vs_mute"] as? Bool) ?? engine.vsMute
                engine.setVolumes(click: Float(cVol), vs: Float(vVol), clickMute: cMute, vsMute: vMute)
            case "device":
                if let devId = payload["device_id"] as? UInt32 {
                    _ = engine.setOutputDevice(deviceId: devId)
                }
            case "load":
                if let songId = payload["song_id"] as? String {
                    if let song = NativeSongLibrary.shared.findSong(byId: songId) {
                        let cf = (payload["crossfade"] as? Bool) ?? false
                        let cfDur = (payload["crossfade_duration"] as? Double) ?? 4.0
                        engine.loadSong(song, crossfade: cf, crossfadeDuration: cfDur)
                    }
                }
            default:
                break
            }
        }
    }
    
    private func sendCurrentStatus() {
        DispatchQueue.main.async { [weak self] in
            let status = NativeAudioEngine.shared.buildStatusDictionary()
            let payload: [String: Any] = [
                "event": "status",
                "data": status
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let str = String(data: data, encoding: .utf8) {
                self?.sendWebSocketText(str)
            }
        }
    }
    
    // MARK: - Roteador HTTP REST
    private func handleHttpRequest(method: String, path: String, headers: [String: String], body: Data) {
        let cleanPath = path.components(separatedBy: "?").first ?? path
        
        switch (method.uppercased(), cleanPath) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveStaticFile("index.html", mimeType: "text/html; charset=utf-8")
        case ("GET", "/style.css"):
            serveStaticFile("style.css", mimeType: "text/css")
        case ("GET", "/app.js"):
            serveStaticFile("app.js", mimeType: "application/javascript")
            
        case ("GET", "/api/network_info"):
            let ip = server.getLocalIPAddress()
            let resp: [String: Any] = [
                "ip": ip,
                "port": server.port,
                "url": "http://\(ip):\(server.port)"
            ]
            sendJsonResponse(resp)
            
        case ("GET", "/api/status"):
            sendJsonResponse(NativeAudioEngine.shared.buildStatusDictionary())
            
        case ("GET", "/api/tracks/folder"):
            let dir = NativeSongLibrary.shared.getTracksDirectory().path
            sendJsonResponse(["path": dir])
            
        case ("POST", "/api/tracks/folder"):
            var dir = ""
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let p = json["path"] as? String {
                dir = p
            }
            if !dir.isEmpty {
                _ = NativeSongLibrary.shared.setTracksDirectory(dir)
            }
            sendJsonResponse(["status": "ok", "path": NativeSongLibrary.shared.getTracksDirectory().path])
            
        case ("POST", "/api/tracks/refresh"):
            _ = NativeSongLibrary.shared.getAllSongs()
            sendJsonResponse(["status": "refreshed"])
            
        case ("GET", "/api/devices"):
            let devs = NativeAudioEngine.shared.getOutputDevices().map { dev in
                ["id": dev.id, "name": dev.name, "is_default": dev.isDefault]
            }
            sendJsonResponse(devs)
            
        case ("GET", "/api/songs"):
            let songs = NativeSongLibrary.shared.getAllSongs()
            if let data = try? JSONEncoder().encode(songs),
               let json = try? JSONSerialization.jsonObject(with: data) {
                sendJsonResponse(json)
            } else {
                sendJsonResponse([])
            }
            
        case ("GET", let p) where p.starts(with: "/covers/"):
            let songId = p.replacingOccurrences(of: "/covers/", with: "")
            let coverPath = NativeSongLibrary.shared.getCoverPath(for: songId)
            if let fileData = try? Data(contentsOf: URL(fileURLWithPath: coverPath)) {
                serveImageData(fileData)
            } else {
                sendHttpError(404, message: "Cover not found")
            }
            
        case ("GET", let p) where p.starts(with: "/api/covers/search"):
            var query = ""
            if let q = path.components(separatedBy: "?").last, q.starts(with: "q=") {
                query = q.replacingOccurrences(of: "q=", with: "").removingPercentEncoding ?? ""
            }
            NativeSongLibrary.shared.searchCovers(query: query) { [weak self] results in
                if let data = try? JSONEncoder().encode(results),
                   let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    self?.sendJsonResponse(list)
                } else {
                    self?.sendJsonResponse([])
                }
            }
            
        case ("GET", "/api/covers"):
            var songId = ""
            if let q = path.components(separatedBy: "?").last, q.starts(with: "id=") {
                songId = q.replacingOccurrences(of: "id=", with: "").removingPercentEncoding ?? ""
            }
            let coverPath = NativeSongLibrary.shared.getCoverPath(for: songId)
            if let fileData = try? Data(contentsOf: URL(fileURLWithPath: coverPath)) {
                serveImageData(fileData)
            } else {
                sendHttpError(404, message: "Cover not found")
            }
            
        case ("POST", "/api/covers/select"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String,
               let artworkUrl = payload["artwork_url"] as? String {
                NativeSongLibrary.shared.saveCoverFromUrl(songId: songId, artworkUrl: artworkUrl) { [weak self] success in
                    if success {
                        self?.sendJsonResponse(["status": "ok", "song_id": songId])
                    } else {
                        self?.sendHttpError(500, message: "Failed to download and save cover")
                    }
                }
                return
            }
            sendHttpError(400, message: "Missing song_id or artwork_url")
            
        case ("POST", "/api/covers/upload"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String,
               let filePath = payload["file_path"] as? String {
                NativeSongLibrary.shared.saveCoverFromFile(songId: songId, filePath: filePath) { [weak self] success in
                    if success {
                        self?.sendJsonResponse(["status": "ok", "song_id": songId])
                    } else {
                        self?.sendHttpError(500, message: "Failed to save cover from file")
                    }
                }
                return
            }
            sendHttpError(400, message: "Missing song_id or file_path")
            
        case ("POST", "/api/covers/remove"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String {
                NativeSongLibrary.shared.removeCover(songId: songId)
                sendJsonResponse(["status": "ok", "song_id": songId])
                return
            }
            sendHttpError(400, message: "Missing song_id")
            
        case ("POST", "/api/covers/auto"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String,
               let song = NativeSongLibrary.shared.findSong(byId: songId) {
                NativeSongLibrary.shared.autoFetchCover(song: song) { [weak self] success in
                    self?.sendJsonResponse(["status": success ? "ok" : "failed", "song_id": songId])
                }
                return
            }
            sendHttpError(400, message: "Missing song_id")
            
        case ("POST", "/api/metronome/generate"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            let name = (payload["name"] as? String) ?? "Click"
            let bpm = parseBpm(payload["bpm"]) ?? 120.0
            let ts = (payload["time_signature"] as? String) ?? "4/4"
            let sub = (payload["subdivision"] as? String) ?? "1/4"
            let subdivide = (payload["subdivide"] as? Bool) ?? (sub != "1/4")
            let dur = (payload["duration_sec"] as? Double) ?? 600.0
            do {
                let song = try NativeMetronomeGenerator.shared.generateMetronome(
                    name: name,
                    bpm: bpm,
                    timeSignature: ts,
                    subdivision: sub,
                    subdivide: subdivide,
                    durationSec: dur
                )
                if let data = try? JSONEncoder().encode(song),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    sendJsonResponse(["status": "success", "song": dict])
                    return
                }
            } catch {
                sendHttpError(500, message: error.localizedDescription)
                return
            }
            sendJsonResponse(["status": "ok"])
            
        case ("POST", "/api/metronome/update"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            let name = (payload["name"] as? String) ?? "Click"
            let bpm = parseBpm(payload["bpm"]) ?? 120.0
            let ts = (payload["time_signature"] as? String) ?? "4/4"
            let sub = (payload["subdivision"] as? String) ?? "1/4"
            let subdivide = (payload["subdivide"] as? Bool) ?? (sub != "1/4")
            let songId = (payload["song_id"] as? String) ?? ""
            let existing = NativeSongLibrary.shared.findSong(byId: songId)
            do {
                let song: SongItem
                if let ex = existing {
                    song = try NativeMetronomeGenerator.shared.updateMetronome(
                        existingItem: ex,
                        name: name,
                        bpm: bpm,
                        timeSignature: ts,
                        subdivision: sub,
                        subdivide: subdivide
                    )
                } else {
                    song = try NativeMetronomeGenerator.shared.generateMetronome(
                        name: name,
                        bpm: bpm,
                        timeSignature: ts,
                        subdivision: sub,
                        subdivide: subdivide
                    )
                }
                if let data = try? JSONEncoder().encode(song),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    sendJsonResponse(["status": "success", "song": dict])
                    return
                }
            } catch {
                sendHttpError(500, message: error.localizedDescription)
                return
            }
            sendJsonResponse(["status": "ok"])
            
        case ("POST", "/api/load"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String,
               let song = NativeSongLibrary.shared.findSong(byId: songId) {
                let cf = (payload["crossfade"] as? Bool) ?? false
                NativeAudioEngine.shared.loadSong(song, crossfade: cf)
                if let data = try? JSONEncoder().encode(song),
                   let songDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    sendJsonResponse(["status": "loaded", "song": songDict])
                    return
                }
            }
            sendJsonResponse(["status": "ok"])
            
        case ("POST", "/api/save_cues"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String {
                let bpm = parseBpm(payload["bpm"])
                let ts = payload["time_signature"] as? String
                var parsedCues: [CueSection] = []
                if let cuesRaw = payload["cues"] as? [[String: Any]],
                   let data = try? JSONSerialization.data(withJSONObject: cuesRaw),
                   let decoded = try? JSONDecoder().decode([CueSection].self, from: data) {
                    parsedCues = decoded
                }
                NativeSongLibrary.shared.saveCues(songId: songId, cues: parsedCues, bpm: bpm, timeSignature: ts)
                if let song = NativeSongLibrary.shared.findSong(byId: songId),
                   let data = try? JSONEncoder().encode(song),
                   let songDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    sendJsonResponse(["status": "success", "song": songDict])
                    return
                }
            }
            sendJsonResponse(["status": "ok"])
            
        case ("POST", "/api/reprocess"):
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            if let songId = payload["song_id"] as? String {
                let bpm = parseBpm(payload["bpm"])
                let ts = payload["time_signature"] as? String
                NativeSongLibrary.shared.reprocessWithAI(songId: songId, bpm: bpm, timeSignature: ts) { [weak self] updatedSong in
                    if let song = updatedSong,
                       let data = try? JSONEncoder().encode(song),
                       let songDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self?.sendJsonResponse(["status": "success", "song": songDict])
                    } else {
                        self?.sendHttpError(500, message: "AI Reprocess Failed")
                    }
                }
                return
            }
            sendHttpError(400, message: "Missing song_id")
            
        case ("POST", let p) where p.starts(with: "/api/"):
            let actionName = p.replacingOccurrences(of: "/api/", with: "")
            var payload: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                payload = json
            }
            executeAction(action: actionName, payload: payload)
            sendJsonResponse(["status": "ok"])
            
        default:
            sendHttpError(404, message: "Not Found")
        }
    }
    
    private func serveStaticFile(_ filename: String, mimeType: String) {
        let staticDir = "/Users/samysglauber/Documents/AbletonTracks/app/static"
        let filePath = (staticDir as NSString).appendingPathComponent(filename)
        
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
            var header = "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: \(mimeType)\r\n"
            header += "Content-Length: \(fileData.count)\r\n"
            header += "Connection: close\r\n\r\n"
            
            var fullData = header.data(using: .utf8)!
            fullData.append(fileData)
            connection.send(content: fullData, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        } else {
            sendHttpError(404, message: "File not found: \(filename)")
        }
    }
    
    private func serveImageData(_ fileData: Data, mimeType: String = "image/jpeg") {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mimeType)\r\n"
        header += "Content-Length: \(fileData.count)\r\n"
        header += "Cache-Control: public, max-age=86400\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        
        var fullData = header.data(using: .utf8)!
        fullData.append(fileData)
        connection.send(content: fullData, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
    
    private func sendJsonResponse(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            sendHttpError(500, message: "JSON Serialization Error")
            return
        }
        
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: application/json; charset=utf-8\r\n"
        header += "Content-Length: \(data.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"
        
        var fullData = header.data(using: .utf8)!
        fullData.append(data)
        connection.send(content: fullData, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }
    
    private func sendHttpError(_ code: Int, message: String) {
        let body = "{\"error\": \"\(message)\"}"
        let resp = "HTTP/1.1 \(code) \(message)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        if let data = resp.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }
}
