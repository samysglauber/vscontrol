import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

struct AudioDeviceInfo: Identifiable {
    let id: AudioDeviceID
    let name: String
}

struct QueuedJumpInfo {
    let leadInAtFrame: Int64
    let leadInStartFrame: Int64
    let targetDownbeatFrame: Int64
    let cueIdx: Int
}

struct GuideLeadInInfo {
    var posFrame: Int64
    let endFrame: Int64
    let targetDownbeatFrame: Int64
    let cueIdx: Int
    let isLoop: Bool
}

/// Motor de Áudio em Tempo Real 100% Nativo em Swift.
/// Executa CoreAudio através de AVAudioEngine e AVAudioSourceNode com baixa latência (< 5ms),
/// roteamento de canais L (Click/Guia) e R (VS/Instrumentos), loops, saltos quantizados,
/// crossfades instantâneos, sintetizador de pad contínuo e MIDI Clock embutido.
final class NativeAudioEngine {
    static let shared = NativeAudioEngine()
    
    // CoreAudio & AVFoundation
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 2)!
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    
    // Sincronizadores
    let osc = NativeOSCClient()
    let midiClock = NativeMIDIClock()
    let padGen = NativePadGenerator.shared
    
    // Dados de Áudio Carregados
    var currentUrl: URL?
    var sampleRate: Double = 44100.0
    var audioLeft: [Float] = []
    var audioRight: [Float] = []
    var totalFrames: Int64 = 0
    var posFrame: Int64 = 0
    var bpm: Double = 120.0
    var timeSignature: (Int, Int) = (4, 4)
    var cues: [CueSection] = []
    
    // Estado do Transporte
    var isPlaying: Bool = false
    var currentCueIdx: Int = 0
    var queuedCueIdx: Int? = nil
    var queuedJump: QueuedJumpInfo? = nil
    var guideLeadIn: GuideLeadInInfo? = nil
    var guideLeadInBars: Double = 1.0
    
    // Loop
    var loopActive: Bool = false
    var loopInfinite: Bool = false
    var loopCueIdx: Int? = nil
    
    // Fade Out / Fade In das Tracks (Canal R)
    var tracksFadeGain: Float = 1.0
    var tracksFadeState: String = "normal" // normal, fading_out, faded_out, fading_in
    var tracksFadeFramesLeft: Int = 0
    var tracksFadeTotalFrames: Int = 0
    var tracksFadeStartGain: Float = 1.0
    var tracksFadeTargetGain: Float = 0.0
    
    // Crossfade entre Músicas
    private var outgoingRight: [Float]? = nil
    private var outgoingPos: Int = 0
    private var incomingXFadeFrames: Int = 0
    private var incomingXFadePos: Int = 0
    
    // Volumes e Mute
    var clickVol: Float = 1.0
    var vsVol: Float = 1.0
    var clickMute: Bool = false
    var vsMute: Bool = false
    
    // Pad de Ambiência
    var padActive: Bool = false
    var padKey: String = "D"
    var padVol: Float = 0.35
    private var padBuffer: [Float] = []
    private var padPos: Int = 0
    
    // Dispositivo de Saída
    var currentDeviceId: AudioDeviceID = 0
    var currentDeviceName: String = ""
    
    // Callbacks de Eventos
    var onPlayStateChanged: ((Bool) -> Void)?
    var onCueJumped: ((Int) -> Void)?
    var onSongEnded: (() -> Void)?
    
    init() {
        lock.initialize(to: os_unfair_lock())
        setupAudioEngine()
        padBuffer = padGen.getPadChunk(key: padKey)
    }
    
    deinit {
        lock.deallocate()
    }
    
    // MARK: - Configuração CoreAudio
    
    private func setupAudioEngine() {
        let node = AVAudioSourceNode(format: outputFormat) { [weak self] _, _, frameCount, outputData -> OSStatus in
            guard let self = self else { return noErr }
            return self.renderAudio(frameCount: Int(frameCount), outputData: outputData)
        }
        self.sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        
        do {
            try engine.start()
        } catch {
            print("⚠️ [NativeAudioEngine] Falha ao iniciar AVAudioEngine: \(error)")
        }
    }
    
    // MARK: - Processamento em Tempo Real (Thread de Áudio CoreAudio)
    
    private func renderAudio(frameCount: Int, outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard abl.count >= 2,
              let ptrL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let ptrR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        if !isPlaying || totalFrames == 0 {
            // Silêncio ou apenas Pad se ativo
            if padActive && !padBuffer.isEmpty {
                renderPadOnly(ptrL: ptrL, ptrR: ptrR, frames: frameCount)
            } else {
                ptrL.initialize(repeating: 0, count: frameCount)
                ptrR.initialize(repeating: 0, count: frameCount)
            }
            return noErr
        }
        
        // 1. Processamento de salto agendado (Lead-In da Voz Guia no Canal L)
        if let jump = queuedJump {
            let leadInAt = jump.leadInAtFrame
            if posFrame + Int64(frameCount) >= leadInAt {
                let leadInStart = jump.leadInStartFrame
                let targetDownbeat = jump.targetDownbeatFrame
                let targetCue = jump.cueIdx
                
                if leadInStart < targetDownbeat - 512 {
                    guideLeadIn = GuideLeadInInfo(
                        posFrame: leadInStart,
                        endFrame: targetDownbeat,
                        targetDownbeatFrame: targetDownbeat,
                        cueIdx: targetCue,
                        isLoop: false
                    )
                    queuedJump = nil
                }
            }
        }
        
        let startFrame = posFrame
        let endFrame = posFrame + Int64(frameCount)
        
        // 2. Fim da música atingido
        if endFrame >= totalFrames {
            ptrL.initialize(repeating: 0, count: frameCount)
            ptrR.initialize(repeating: 0, count: frameCount)
            isPlaying = false
            posFrame = 0
            currentCueIdx = 0
            guideLeadIn = nil
            midiClock.sendStop()
            osc.sendStopPlaying()
            DispatchQueue.main.async { [weak self] in
                self?.onPlayStateChanged?(false)
                self?.onSongEnded?()
            }
            return noErr
        }
        
        // 3. Renderização normal com suporte a Lead-In de Guia
        for i in 0..<frameCount {
            let curFrame = Int(startFrame) + i
            var sampleL: Float = (curFrame < audioLeft.count) ? audioLeft[curFrame] : 0.0
            var sampleR: Float = (curFrame < audioRight.count) ? audioRight[curFrame] : 0.0
            
            // Se houver voz guia em preparação no Canal L:
            if var guide = guideLeadIn {
                let gFrame = Int(guide.posFrame)
                if gFrame < audioLeft.count {
                    sampleL = audioLeft[gFrame]
                }
                guide.posFrame += 1
                if guide.posFrame >= guide.endFrame {
                    // Chegou ao tempo 1!
                    posFrame = guide.targetDownbeatFrame
                    currentCueIdx = guide.cueIdx
                    guideLeadIn = nil
                    let jumpedIdx = guide.cueIdx
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(jumpedIdx)
                    }
                } else {
                    guideLeadIn = guide
                }
            }
            
            // Fade Out / Fade In suave das tracks (Canal R)
            if tracksFadeFramesLeft > 0 {
                let progress = 1.0 - (Float(tracksFadeFramesLeft) / Float(max(1, tracksFadeTotalFrames)))
                tracksFadeGain = tracksFadeStartGain + (tracksFadeTargetGain - tracksFadeStartGain) * progress
                tracksFadeFramesLeft -= 1
                if tracksFadeFramesLeft == 0 {
                    tracksFadeGain = tracksFadeTargetGain
                    if tracksFadeTargetGain == 0.0 {
                        tracksFadeState = "faded_out"
                    } else {
                        tracksFadeState = "normal"
                    }
                }
            }
            
            // Crossfade de saída (Canal R anterior desvanecendo)
            if let outR = outgoingRight, outgoingPos < outR.count {
                let progress = Float(outgoingPos) / Float(outR.count)
                let gainOut = 1.0 - progress
                let gainIn = progress
                sampleR = (outR[outgoingPos] * gainOut) + (sampleR * gainIn)
                outgoingPos += 1
                if outgoingPos >= outR.count {
                    outgoingRight = nil
                }
            }
            
            // Aplica volumes e mutes
            let effL = clickMute ? 0.0 : (sampleL * clickVol)
            let effR = vsMute ? 0.0 : (sampleR * vsVol * tracksFadeGain)
            
            // Mixa Pad contínuo se ativo
            var padSample: Float = 0.0
            if padActive && !padBuffer.isEmpty {
                padSample = padBuffer[padPos % padBuffer.count] * padVol
                padPos += 1
            }
            
            ptrL[i] = effL + padSample
            ptrR[i] = effR + padSample
        }
        
        // 4. Emite MIDI Clock baseado exatamente nos frames de áudio consumidos
        midiClock.processFrames(startFrame: startFrame, nFrames: frameCount, sampleRate: sampleRate, bpm: bpm)
        
        posFrame += Int64(frameCount)
        updateCurrentCueIdx()
        
        return noErr
    }
    
    private func renderPadOnly(ptrL: UnsafeMutablePointer<Float>, ptrR: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let sample = padBuffer[padPos % padBuffer.count] * padVol
            padPos += 1
            ptrL[i] = sample
            ptrR[i] = sample
        }
    }
    
    private func updateCurrentCueIdx() {
        guard !cues.isEmpty else { return }
        let currentSec = Double(posFrame) / sampleRate
        for (i, cue) in cues.enumerated().reversed() {
            if currentSec >= cue.time {
                if currentCueIdx != i {
                    currentCueIdx = i
                }
                break
            }
        }
    }
    
    // MARK: - Controle de Reprodução
    
    func loadSong(_ song: SongItem, crossfade: Bool = false) {
        let url = URL(fileURLWithPath: song.path)
        try? loadSong(
            url: url,
            bpm: song.bpm ?? 120.0,
            cues: song.cues ?? [],
            timeSignature: song.time_signature ?? "4/4",
            crossfade: crossfade
        )
    }
    
    func loadSong(
        url: URL,
        bpm: Double,
        cues: [CueSection],
        timeSignature: String = "4/4",
        crossfade: Bool = false,
        crossfadeDuration: Double = 4.0
    ) throws {
        let (left, right, sr) = try loadAudioFileStereo(url: url)
        
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        // Se crossfade solicitado, captura cauda de saída do Canal R atual
        if crossfade && !audioRight.isEmpty && isPlaying {
            let remFrames = Int(max(0.5, crossfadeDuration) * sampleRate)
            let startF = Int(posFrame)
            let endF = min(audioRight.count, startF + remFrames)
            if endF > startF {
                outgoingRight = Array(audioRight[startF..<endF])
                outgoingPos = 0
            }
        } else {
            outgoingRight = nil
            outgoingPos = 0
        }
        
        self.currentUrl = url
        self.sampleRate = sr
        self.audioLeft = left
        self.audioRight = right
        self.totalFrames = Int64(left.count)
        self.posFrame = 0
        self.bpm = bpm > 30 ? bpm : 120.0
        
        let parts = timeSignature.split(separator: "/")
        if parts.count >= 2, let n = Int(parts[0]), let d = Int(parts[1]) {
            self.timeSignature = (n, d)
        } else {
            self.timeSignature = (4, 4)
        }
        
        self.cues = cues
        self.currentCueIdx = 0
        self.queuedCueIdx = nil
        self.queuedJump = nil
        self.guideLeadIn = nil
        self.loopActive = false
        self.loopInfinite = false
        self.loopCueIdx = nil
        self.tracksFadeGain = 1.0
        self.tracksFadeState = "normal"
        self.tracksFadeFramesLeft = 0
        
        // Sincroniza BPM e fórmula de compasso com o Ableton Live via OSC
        osc.sendTempo(self.bpm)
        osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
        midiClock.resetTick(currentFrame: 0, sampleRate: self.sampleRate, bpm: self.bpm)
        
        if crossfade {
            self.isPlaying = true
            midiClock.sendContinue()
            osc.sendContinuePlaying()
        }
    }
    
    func play() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !audioLeft.isEmpty else { return }
        
        tracksFadeState = "normal"
        tracksFadeGain = 1.0
        tracksFadeFramesLeft = 0
        isPlaying = true
        
        midiClock.sendContinue()
        osc.sendContinuePlaying()
        
        DispatchQueue.main.async { [weak self] in
            self?.onPlayStateChanged?(true)
        }
    }
    
    func pause() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        isPlaying = false
        queuedCueIdx = nil
        queuedJump = nil
        guideLeadIn = nil
        
        midiClock.sendStop()
        osc.sendStopPlaying()
        
        DispatchQueue.main.async { [weak self] in
            self?.onPlayStateChanged?(false)
        }
    }
    
    func stop() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        isPlaying = false
        posFrame = 0
        currentCueIdx = 0
        queuedCueIdx = nil
        queuedJump = nil
        guideLeadIn = nil
        loopActive = false
        loopInfinite = false
        loopCueIdx = nil
        
        midiClock.sendStop()
        midiClock.resetTick(currentFrame: 0, sampleRate: sampleRate, bpm: bpm)
        osc.sendStopPlaying()
        
        DispatchQueue.main.async { [weak self] in
            self?.onPlayStateChanged?(false)
        }
    }
    
    func seek(seconds: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard totalFrames > 0 else { return }
        
        let target = Int64(seconds * sampleRate)
        posFrame = max(0, min(target, totalFrames - 1))
        queuedCueIdx = nil
        queuedJump = nil
        guideLeadIn = nil
        midiClock.resetTick(currentFrame: posFrame, sampleRate: sampleRate, bpm: bpm)
        updateCurrentCueIdx()
    }
    
    // MARK: - Salto Quantizado de Cues (Seamless Jump no Tempo 1 com Voz Guia)
    
    func triggerCue(idx: Int, quantize: Bool = true) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard idx >= 0, idx < cues.count else { return }
        
        let targetCue = cues[idx]
        let targetDownbeat = Int64(targetCue.time * sampleRate)
        
        if !quantize || !isPlaying {
            seek(seconds: targetCue.time)
            currentCueIdx = idx
            return
        }
        
        // Disparo quantizado: aguarda o tempo 1 do próximo compasso
        let secPerBeat = 60.0 / bpm
        let beatsPerBar = Double(timeSignature.0)
        let secPerBar = secPerBeat * beatsPerBar
        let leadInBars = max(0.5, guideLeadInBars)
        let leadInFrames = Int64(leadInBars * secPerBar * sampleRate)
        let leadInStart = max(0, targetDownbeat - leadInFrames)
        
        let currentSec = Double(posFrame) / sampleRate
        let nextBarSec = ceil(currentSec / secPerBar) * secPerBar
        let leadInAtFrame = Int64(nextBarSec * sampleRate)
        
        queuedCueIdx = idx
        queuedJump = QueuedJumpInfo(
            leadInAtFrame: leadInAtFrame,
            leadInStartFrame: leadInStart,
            targetDownbeatFrame: targetDownbeat,
            cueIdx: idx
        )
    }
    
    func toggleLoop(cueIdx: Int? = nil, infinite: Bool = false) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        if infinite {
            loopInfinite.toggle()
            loopActive = loopInfinite
            loopCueIdx = cueIdx ?? currentCueIdx
        } else {
            loopActive.toggle()
            loopInfinite = false
            loopCueIdx = cueIdx ?? currentCueIdx
        }
    }
    
    func fadeTracks(direction: String = "toggle", duration: Double = 3.0) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard isPlaying else { return }
        
        let targetOut = (direction == "out") || (direction == "toggle" && tracksFadeState == "normal")
        tracksFadeTotalFrames = Int(duration * sampleRate)
        tracksFadeFramesLeft = tracksFadeTotalFrames
        tracksFadeStartGain = tracksFadeGain
        tracksFadeTargetGain = targetOut ? 0.0 : 1.0
        tracksFadeState = targetOut ? "fading_out" : "fading_in"
    }
    
    func setVolumes(click: Float, vs: Float, clickMute: Bool, vsMute: Bool) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        self.clickVol = click
        self.vsVol = vs
        self.clickMute = clickMute
        self.vsMute = vsMute
    }
    
    func setPad(active: Bool, key: String, volume: Float) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        self.padActive = active
        self.padVol = volume
        if self.padKey != key {
            self.padKey = key
            self.padBuffer = padGen.getPadChunk(key: key)
            self.padPos = 0
        }
    }
    
    // MARK: - Roteamento de Dispositivos CoreAudio
    
    func getAvailableOutputDevices() -> [AudioDeviceInfo] {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize)
        let devCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devIDs = [AudioDeviceID](repeating: 0, count: devCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &dataSize, &devIDs)
        
        var list: [AudioDeviceInfo] = []
        for dId in devIDs {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dId, &streamAddr, 0, nil, &streamSize)
            if streamSize > 0 {
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var cfName: Unmanaged<CFString>?
                var cfNameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                AudioObjectGetPropertyData(dId, &nameAddr, 0, nil, &cfNameSize, &cfName)
                let name = cfName?.takeRetainedValue() as String? ?? "Audio Output"
                list.append(AudioDeviceInfo(id: dId, name: name))
            }
        }
        return list
    }
    
    func getOutputDevices() -> [(id: AudioDeviceID, name: String, isDefault: Bool)] {
        return getAvailableOutputDevices().map { ($0.id, $0.name, $0.id == currentDeviceId) }
    }
    
    @discardableResult
    func setOutputDevice(deviceId: AudioDeviceID) -> Bool {
        setOutputDevice(deviceId: deviceId, deviceName: "")
        return true
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to seconds: Double) {
        seek(seconds: seconds)
    }
    
    func triggerCue(index: Int) {
        triggerCue(idx: index)
    }
    
    func toggleInfiniteLoop() {
        toggleLoop(infinite: true)
    }
    
    func fadeStop(duration: Double = 2.0) {
        fadeTracks(direction: "out", duration: duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.pause()
        }
    }
    
    func setVolumes(clickVolume: Float, vsVolume: Float) {
        setVolumes(click: clickVolume, vs: vsVolume, clickMute: clickMute, vsMute: vsMute)
    }
    
    func setPadKey(_ key: String, active: Bool) {
        setPad(active: active, key: key, volume: padVol)
    }
    
    func buildStatusDictionary() -> [String: Any] {
        let curSec = sampleRate > 0 ? Double(posFrame) / sampleRate : 0.0
        let totSec = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0.0
        
        var cueDict: [String: Any]? = nil
        if currentCueIdx >= 0 && currentCueIdx < cues.count {
            let c = cues[currentCueIdx]
            cueDict = [
                "id": c.id,
                "name": c.name,
                "time": c.time,
                "bar": c.bar,
                "color": c.color
            ]
        }
        
        return [
            "type": "status",
            "is_playing": isPlaying,
            "current_time": curSec,
            "total_time": totSec,
            "current_cue": cueDict as Any,
            "current_cue_idx": currentCueIdx,
            "volume_l": Double(clickVol),
            "volume_r": Double(vsVol),
            "click_mute": clickMute,
            "vs_mute": vsMute,
            "fade_active": (tracksFadeState == "faded_out" || tracksFadeState == "fading_out"),
            "loop_active": loopActive,
            "infinite_loop": loopInfinite,
            "bpm": bpm,
            "time_signature": "\(timeSignature.0)/\(timeSignature.1)",
            "pad_playing": padActive,
            "pad_key": padKey,
            "device": currentDeviceName
        ]
    }
    
    func setOutputDevice(deviceId: AudioDeviceID, deviceName: String = "") {
        guard let audioUnit = engine.outputNode.audioUnit else { return }
        var dId = deviceId
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dId,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if err == noErr {
            self.currentDeviceId = deviceId
            self.currentDeviceName = deviceName
            print("🔊 [NativeAudioEngine] Dispositivo de saída alterado para: \(deviceName) [ID: \(deviceId)]")
        } else {
            print("⚠️ [NativeAudioEngine] Erro ao alterar dispositivo CoreAudio: \(err)")
        }
    }
}

// MARK: - Leitor de Arquivos de Áudio Estéreo (ExtAudioFile / AVAudioFile)

func loadAudioFileStereo(url: URL) throws -> (left: [Float], right: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "NativeAudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Falha ao alocar buffer PCM"])
    }
    try file.read(into: buffer)
    
    let sr = format.sampleRate
    let n = Int(buffer.frameLength)
    guard let channelData = buffer.floatChannelData else {
        throw NSError(domain: "NativeAudioEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Canais Float32 não disponíveis"])
    }
    
    var left = [Float](repeating: 0, count: n)
    var right = [Float](repeating: 0, count: n)
    
    if format.channelCount >= 2 {
        let ptrL = channelData[0]
        let ptrR = channelData[1]
        left.withUnsafeMutableBufferPointer { dest in
            _ = memcpy(dest.baseAddress!, ptrL, n * MemoryLayout<Float>.size)
        }
        right.withUnsafeMutableBufferPointer { dest in
            _ = memcpy(dest.baseAddress!, ptrR, n * MemoryLayout<Float>.size)
        }
    } else {
        let ptrL = channelData[0]
        left.withUnsafeMutableBufferPointer { dest in
            _ = memcpy(dest.baseAddress!, ptrL, n * MemoryLayout<Float>.size)
        }
        right = left
    }
    return (left, right, sr)
}
