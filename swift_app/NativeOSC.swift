import Foundation
import Darwin

/// Cliente OSC nativo em Swift via socket UDP POSIX (porta 11000)
/// Comunica diretamente com o script remoto AbletonOSC no Ableton Live.
final class NativeOSCClient {
    private var sockfd: Int32 = -1
    private var addr = sockaddr_in()
    
    init(host: String = "127.0.0.1", port: UInt16 = 11000) {
        sockfd = socket(AF_INET, SOCK_DGRAM, 0)
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
    
    func sendMessage(_ address: String, floatVal: Float? = nil, intVal: Int32? = nil) {
        guard sockfd >= 0 else { return }
        var packet = [UInt8]()
        
        // 1. Endereço OSC (null-terminated + alinhamento de 4 bytes)
        packet.append(contentsOf: address.utf8)
        packet.append(0)
        padTo4(&packet)
        
        // 2. Type Tag String
        var typeTag = ","
        if floatVal != nil {
            typeTag += "f"
        } else if intVal != nil {
            typeTag += "i"
        }
        packet.append(contentsOf: typeTag.utf8)
        packet.append(0)
        padTo4(&packet)
        
        // 3. Argumentos (Big Endian)
        if let f = floatVal {
            var be = f.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { packet.append(contentsOf: $0) }
        } else if let i = intVal {
            var be = i.bigEndian
            withUnsafeBytes(of: &be) { packet.append(contentsOf: $0) }
        }
        
        packet.withUnsafeBytes { ptr in
            _ = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sockfd, ptr.baseAddress, ptr.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
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
}
