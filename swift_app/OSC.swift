import Foundation
import Darwin

/// Tipos de argumentos suportados pelo protocolo OSC
enum OSCArg {
    case int(Int32)
    case float(Float)
    case string(String)
}

/// Cliente OSC nativo em Swift via socket UDP POSIX (porta 11000)
/// Comunica diretamente com o script remoto AbletonOSC no Ableton Live.
final class NativeOSCClient {
    private var sockfd: Int32 = -1
    private var addr = sockaddr_in()
    private(set) var host: String = "127.0.0.1"
    private(set) var port: UInt16 = 11000
    
    init(host: String = "127.0.0.1", port: UInt16 = 11000) {
        self.host = host
        self.port = port
        sockfd = socket(AF_INET, SOCK_DGRAM, 0)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
    }
    
    func updateEndpoint(host: String, port: UInt16) {
        self.host = host
        self.port = port
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
    }
    
    deinit {
        if sockfd >= 0 {
            close(sockfd)
        }
    }
    
    private func padTo4(_ data: inout [UInt8]) {
        while data.count % 4 != 0 {
            data.append(0)
        }
    }
    
    func sendMessage(_ address: String, args: [OSCArg] = []) {
        guard sockfd >= 0 else { return }
        var packet = [UInt8]()
        
        // 1. Endereço OSC (null-terminated + alinhamento de 4 bytes)
        packet.append(contentsOf: address.utf8)
        packet.append(0)
        padTo4(&packet)
        
        // 2. Type Tag String
        var typeTag = ","
        for arg in args {
            switch arg {
            case .int:
                typeTag.append("i")
            case .float:
                typeTag.append("f")
            case .string:
                typeTag.append("s")
            }
        }
        packet.append(contentsOf: typeTag.utf8)
        packet.append(0)
        padTo4(&packet)
        
        // 3. Argumentos (Big Endian para números, null-terminated + pad 4 para strings)
        for arg in args {
            switch arg {
            case .int(let i):
                var be = i.bigEndian
                withUnsafeBytes(of: &be) { packet.append(contentsOf: $0) }
            case .float(let f):
                var be = f.bitPattern.bigEndian
                withUnsafeBytes(of: &be) { packet.append(contentsOf: $0) }
            case .string(let s):
                packet.append(contentsOf: s.utf8)
                packet.append(0)
                padTo4(&packet)
            }
        }
        
        packet.withUnsafeBytes { ptr in
            _ = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sockfd, ptr.baseAddress, ptr.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    
    func sendMessage(_ address: String, floatVal: Float? = nil, intVal: Int32? = nil) {
        if let f = floatVal {
            sendMessage(address, args: [.float(f)])
        } else if let i = intVal {
            sendMessage(address, args: [.int(i)])
        } else {
            sendMessage(address, args: [])
        }
    }
    
    func sendTempo(_ bpm: Double) {
        guard bpm > 0 else { return }
        sendMessage("/live/song/set/tempo", floatVal: Float(bpm))
    }
    
    func sendTimeSignature(numerator: Int, denominator: Int) {
        guard numerator > 0, denominator > 0 else { return }
        sendMessage("/live/song/set/signature_numerator", intVal: Int32(numerator))
        sendMessage("/live/song/set/signature_denominator", intVal: Int32(denominator))
    }
    
    func sendContinuePlaying() {
        sendMessage("/live/song/continue_playing")
    }
    
    func sendStopPlaying() {
        sendMessage("/live/song/stop_playing")
    }
    
    // MARK: - Ableton Live Scene Sync & Triggering
    
    func fireScene(index: Int) {
        guard index >= 0 else { return }
        sendMessage("/live/scene/fire", args: [.int(Int32(index))])
    }
    
    func createScene(at index: Int = -1) {
        sendMessage("/live/song/create_scene", args: [.int(Int32(index))])
    }
    
    func setSceneName(index: Int, name: String) {
        guard index >= 0 else { return }
        sendMessage("/live/scene/set/name", args: [.int(Int32(index)), .string(name)])
    }
    
    func setSceneTempo(index: Int, bpm: Double) {
        guard index >= 0, bpm > 0 else { return }
        sendMessage("/live/scene/set/tempo", args: [.int(Int32(index)), .float(Float(bpm))])
        sendMessage("/live/scene/set/tempo_enabled", args: [.int(Int32(index)), .int(1)])
    }
    
    func setSceneTimeSignature(index: Int, numerator: Int, denominator: Int) {
        guard index >= 0, numerator > 0, denominator > 0 else { return }
        sendMessage("/live/scene/set/time_signature_numerator", args: [.int(Int32(index)), .int(Int32(numerator))])
        sendMessage("/live/scene/set/time_signature_denominator", args: [.int(Int32(index)), .int(Int32(denominator))])
        sendMessage("/live/scene/set/time_signature_enabled", args: [.int(Int32(index)), .int(1)])
    }
    
    func queryNumScenes(timeoutSeconds: Double = 0.4) -> Int? {
        let recvSock = socket(AF_INET, SOCK_DGRAM, 0)
        guard recvSock >= 0 else { return nil }
        defer { close(recvSock) }
        
        var opt: Int32 = 1
        setsockopt(recvSock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(recvSock, SOL_SOCKET, SO_REUSEPORT, &opt, socklen_t(MemoryLayout<Int32>.size))
        
        var tv = timeval(tv_sec: 0, tv_usec: __darwin_suseconds_t(timeoutSeconds * 1_000_000))
        setsockopt(recvSock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        var recvAddr = sockaddr_in()
        recvAddr.sin_family = sa_family_t(AF_INET)
        recvAddr.sin_port = UInt16(11001).bigEndian
        inet_pton(AF_INET, self.host, &recvAddr.sin_addr)
        
        let bindRes = withUnsafePointer(to: &recvAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(recvSock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { return nil }
        
        // Envia requisição /live/song/get/num_scenes para a porta configurada (padrão 11000)
        sendMessage("/live/song/get/num_scenes")
        
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = recv(recvSock, &buffer, buffer.count, 0)
        guard bytesRead > 0 else { return nil }
        
        var tagIndex: Int? = nil
        for i in 0..<bytesRead {
            if buffer[i] == UInt8(ascii: ",") {
                tagIndex = i
                break
            }
        }
        guard let tIdx = tagIndex else { return nil }
        
        var tagLen = 0
        while (tIdx + tagLen) < bytesRead && buffer[tIdx + tagLen] != 0 {
            tagLen += 1
        }
        let tagPaddedLen = ((tagLen + 1 + 3) / 4) * 4
        let payloadOffset = tIdx + tagPaddedLen
        
        if payloadOffset + 4 <= bytesRead {
            var rawVal: Int32 = 0
            withUnsafeMutableBytes(of: &rawVal) { rawPtr in
                rawPtr.copyBytes(from: buffer[payloadOffset..<payloadOffset+4])
            }
            return Int(Int32(bigEndian: rawVal))
        }
        
        return nil
    }
}
