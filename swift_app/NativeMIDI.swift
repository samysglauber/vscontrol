import Foundation
import CoreMIDI

/// Gerenciador de MIDI Beat Clock com precisão de áudio (Sample-Accurate) nativo em Swift.
/// Cria a porta virtual 'VS Control Sync' e transmite Clock (0xF8), Continue (0xFB) e Stop (0xFC)
/// para o Ableton Live sem usar SPP (permitindo gravação contínua na timeline).
final class NativeMIDIClock {
    private var client: MIDIClientRef = 0
    private var source: MIDIEndpointRef = 0
    private var outPort: MIDIPortRef = 0
    private var lastTick: Int64 = -1
    var isPlaying: Bool = false
    
    init(portName: String = "VS Control Sync") {
        MIDIClientCreate(portName as CFString, nil, nil, &client)
        MIDISourceCreate(client, portName as CFString, &source)
        MIDIOutputPortCreate(client, portName as CFString, &outPort)
    }
    
    deinit {
        if outPort != 0 { MIDIPortDispose(outPort) }
        if source != 0 { MIDIEndpointDispose(source) }
        if client != 0 { MIDIClientDispose(client) }
    }
    
    private func sendBytes(_ bytes: [UInt8]) {
        var packetList = MIDIPacketList()
        let cur = MIDIPacketListInit(&packetList)
        _ = MIDIPacketListAdd(&packetList, MemoryLayout<MIDIPacketList>.size, cur, 0, bytes.count, bytes)
        
        // 1. Envia para a porta virtual criada (VS Control Sync)
        if source != 0 {
            MIDIReceived(source, &packetList)
        }
        
        // 2. Envia para portas de destino existentes no sistema (IAC Driver, TRIGGER, etc.)
        if outPort != 0 {
            let n = MIDIGetNumberOfDestinations()
            for i in 0..<n {
                let d = MIDIGetDestination(i)
                MIDISend(outPort, d, &packetList)
            }
        }
    }
    
    func sendContinue() {
        lastTick = -1
        isPlaying = true
        sendBytes([0xFB])
        sendBytes([0xF8])
    }
    
    func sendStop() {
        isPlaying = false
        sendBytes([0xFC])
    }
    
    func resetTick(currentFrame: Int64, sampleRate: Double, bpm: Double) {
        guard bpm > 0, sampleRate > 0 else { return }
        let framesPerTick = (2.5 * sampleRate) / bpm
        lastTick = Int64(Double(currentFrame) / framesPerTick)
    }
    
    func processFrames(startFrame: Int64, nFrames: Int, sampleRate: Double, bpm: Double) {
        guard isPlaying, bpm > 0, sampleRate > 0 else { return }
        let framesPerTick = (2.5 * sampleRate) / bpm
        guard framesPerTick > 0 else { return }
        
        let endFrame = startFrame + Int64(nFrames)
        let targetTick = Int64(Double(endFrame) / framesPerTick)
        
        if lastTick < 0 {
            lastTick = Int64(Double(startFrame) / framesPerTick)
        }
        
        if targetTick > lastTick {
            var numTicks = targetTick - lastTick
            if numTicks > 48 {
                numTicks = 1
                lastTick = targetTick - 1
            }
            for _ in 0..<numTicks {
                sendBytes([0xF8])
            }
            lastTick = targetTick
        }
    }
}
