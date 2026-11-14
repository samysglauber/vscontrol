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
    var fullWaveform: [Double] = []
    var totalDuration: Double {
        return sampleRate > 0 ? Double(totalFrames) / sampleRate : 0.0
    }
    
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
        guard abl.count > 0, let firstBuf = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        
        let isDeinterleaved = (abl.count >= 2)
        let ptrL = firstBuf
        let ptrR = isDeinterleaved ? (abl[1].mData?.assumingMemoryBound(to: Float.self) ?? firstBuf) : firstBuf
        
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        if !isPlaying || totalFrames == 0 {
            // Silêncio ou apenas Pad se ativo
            if padActive && !padBuffer.isEmpty {
                renderPadOnly(ptrL: ptrL, ptrR: ptrR, frames: frameCount, isDeinterleaved: isDeinterleaved)
            } else {
                if isDeinterleaved {
                    ptrL.initialize(repeating: 0, count: frameCount)
                    ptrR.initialize(repeating: 0, count: frameCount)
                } else {
                    ptrL.initialize(repeating: 0, count: frameCount * 2)
                }
            }
            return noErr
        }
        
        let startFrame = posFrame
        let endFrame = posFrame + Int64(frameCount)
        
        // 2. Fim da música atingido
        if endFrame >= totalFrames {
            if isDeinterleaved {
                ptrL.initialize(repeating: 0, count: frameCount)
                ptrR.initialize(repeating: 0, count: frameCount)
            } else {
                ptrL.initialize(repeating: 0, count: frameCount * 2)
            }
            isPlaying = false
            posFrame = 0
            currentCueIdx = 0
            guideLeadIn = nil
            queuedJump = nil
            queuedCueIdx = nil
            midiClock.sendStop()
            osc.sendStopPlaying()
            DispatchQueue.main.async { [weak self] in
                self?.onPlayStateChanged?(false)
                self?.onSongEnded?()
            }
            return noErr
        }
        
        // 3. Renderização precisa de áudio com suporte a Salto Quantizado, Loop e Fade
        var curPos = posFrame
        
        for i in 0..<frameCount {
            var sampleL: Float = 0.0
            var sampleR: Float = 0.0
            
            // A. Lead-In de Voz Guia em andamento no Canal L
            if var guide = guideLeadIn {
                let gFrame = Int(guide.posFrame)
                sampleL = (gFrame < audioLeft.count && gFrame >= 0) ? audioLeft[gFrame] : 0.0
                guide.posFrame += 1
                
                let rFrame = Int(curPos)
                sampleR = (rFrame < audioRight.count && rFrame >= 0) ? audioRight[rFrame] : 0.0
                curPos += 1
                
                if guide.posFrame >= guide.endFrame {
                    // Chegou ao Tempo 1 (Downbeat)! Ambos os canais entram no trecho alvo
                    curPos = guide.targetDownbeatFrame
                    currentCueIdx = guide.cueIdx
                    queuedCueIdx = nil
                    let wasLoop = guide.isLoop
                    guideLeadIn = nil
                    if wasLoop && !loopInfinite {
                        loopActive = false
                        loopCueIdx = nil
                    }
                    let jumpedIdx = guide.cueIdx
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(jumpedIdx)
                    }
                } else {
                    guideLeadIn = guide
                }
            }
            // B. Salto agendado alcançou o ponto de disparo do Lead-In
            else if let jump = queuedJump, curPos >= jump.leadInAtFrame {
                let leadInStart = jump.leadInStartFrame
                let targetDownbeat = jump.targetDownbeatFrame
                let targetCue = jump.cueIdx
                
                if leadInStart < targetDownbeat - 512 && leadInStart >= 0 {
                    // Ativa o Lead-In exclusivo no Canal L (Click + Guia)
                    // enquanto o Canal R continua tocando normalmente o trecho atual
                    guideLeadIn = GuideLeadInInfo(
                        posFrame: leadInStart,
                        endFrame: targetDownbeat,
                        targetDownbeatFrame: targetDownbeat,
                        cueIdx: targetCue,
                        isLoop: false
                    )
                    queuedJump = nil
                    
                    let gFrame = Int(leadInStart)
                    sampleL = (gFrame < audioLeft.count && gFrame >= 0) ? audioLeft[gFrame] : 0.0
                    let rFrame = Int(curPos)
                    sampleR = (rFrame < audioRight.count && rFrame >= 0) ? audioRight[rFrame] : 0.0
                    curPos += 1
                } else {
                    // Salto imediato no tempo 1 sem lead-in
                    curPos = targetDownbeat
                    currentCueIdx = targetCue
                    queuedCueIdx = nil
                    queuedJump = nil
                    let f = Int(curPos)
                    sampleL = (f < audioLeft.count && f >= 0) ? audioLeft[f] : 0.0
                    sampleR = (f < audioRight.count && f >= 0) ? audioRight[f] : 0.0
                    curPos += 1
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(targetCue)
                    }
                }
            }
            // C. Repetição da seção (Loop 1x ou Infinito) se ativo
            else if loopActive {
                let targetLoop = loopCueIdx ?? currentCueIdx
                if targetLoop >= 0 && targetLoop < cues.count {
                    let currStart = Int64(cues[targetLoop].time * sampleRate)
                    let currEnd = (targetLoop + 1 < cues.count) ? Int64(cues[targetLoop + 1].time * sampleRate) : totalFrames
                    if curPos >= currEnd {
                        curPos = currStart
                        currentCueIdx = targetLoop
                        if !loopInfinite {
                            loopActive = false
                            loopCueIdx = nil
                        }
                    }
                }
                let f = Int(curPos)
                sampleL = (f < audioLeft.count && f >= 0) ? audioLeft[f] : 0.0
                sampleR = (f < audioRight.count && f >= 0) ? audioRight[f] : 0.0
                curPos += 1
            }
            // D. Reprodução normal
            else {
                let f = Int(curPos)
                sampleL = (f < audioLeft.count && f >= 0) ? audioLeft[f] : 0.0
                sampleR = (f < audioRight.count && f >= 0) ? audioRight[f] : 0.0
                curPos += 1
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
            
            // Crossfade de saída (Canal R anterior desvanecendo suavemente)
            if let outR = outgoingRight, outgoingPos < outR.count {
                let progress = Float(outgoingPos) / Float(outR.count)
                let gainOut = cos(progress * (Float.pi / 2.0))
                let gainIn = sin(progress * (Float.pi / 2.0))
                sampleR = (outR[outgoingPos] * gainOut) + (sampleR * gainIn)
                outgoingPos += 1
                if outgoingPos >= outR.count {
                    outgoingRight = nil
                }
            }
            
            // Aplica volumes e mutes independentes
            let effL = clickMute ? 0.0 : (sampleL * clickVol)
            let effR = vsMute ? 0.0 : (sampleR * vsVol * tracksFadeGain)
            
            // Mixa Pad contínuo se ativo
            var padSample: Float = 0.0
            if padActive && !padBuffer.isEmpty {
                padSample = padBuffer[padPos % padBuffer.count] * padVol
                padPos += 1
            }
            
            let outL = effL + padSample
            let outR = max(-1.0, min(1.0, effR + padSample))
            if isDeinterleaved {
                ptrL[i] = outL
                ptrR[i] = outR
            } else {
                ptrL[2 * i] = outL
                ptrL[2 * i + 1] = outR
            }
        }
        
        posFrame = curPos
        midiClock.processFrames(startFrame: startFrame, nFrames: frameCount, sampleRate: sampleRate, bpm: bpm)
        updateCurrentCueIdx()
        
        return noErr
    }
    
    private func renderPadOnly(ptrL: UnsafeMutablePointer<Float>, ptrR: UnsafeMutablePointer<Float>, frames: Int, isDeinterleaved: Bool) {
        for i in 0..<frames {
            let sample = padBuffer[padPos % padBuffer.count] * padVol
            padPos += 1
            if isDeinterleaved {
                ptrL[i] = sample
                ptrR[i] = sample
            } else {
                ptrL[2 * i] = sample
                ptrL[2 * i + 1] = sample
            }
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
    
    func loadSong(_ song: SongItem, crossfade: Bool = false, crossfadeDuration: Double = 4.0) {
        let url = URL(fileURLWithPath: song.path)
        try? loadSong(
            url: url,
            bpm: song.bpm ?? 120.0,
            cues: song.cues ?? [],
            timeSignature: song.time_signature ?? "4/4",
            crossfade: crossfade,
            crossfadeDuration: crossfadeDuration
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
        
        let totSec = sr > 0 ? Double(left.count) / sr : 0.0
        var resolvedCues = cues
        if resolvedCues.isEmpty && totSec > 0 {
            resolvedCues = NativeSongLibrary.shared.generateDefaultCues(
                totalDuration: totSec,
                bpm: self.bpm,
                timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)"
            )
        }
        self.cues = resolvedCues
        
        // Computa forma de onda real com Accelerate vDSP
        let peaks = NativeSongLibrary.shared.computeWaveformPeaks(from: right, targetPeaks: 1200)
        self.fullWaveform = peaks
        
        // Salva na biblioteca e no arquivo .cues.json para que a música nova fique permanentemente salva
        let filename = url.lastPathComponent
        let needsAuto = NativeSongLibrary.shared.needsAutoCueAnalysis(songId: filename)
        
        NativeSongLibrary.shared.saveCues(
            songId: filename,
            cues: resolvedCues,
            bpm: self.bpm,
            timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)",
            fullWaveform: peaks,
            autoAnalysis: needsAuto ? "pending" : nil
        )
        
        if needsAuto {
            let num = self.timeSignature.0
            let den = self.timeSignature.1
            NativeSongLibrary.shared.autoAnalyzeCues(
                songId: filename,
                left: left,
                right: right,
                sampleRate: sr,
                bpm: self.bpm,
                timeSignature: "\(num)/\(den)",
                templateCues: resolvedCues
            )
        }
        
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
    
    func applyAutoCues(songId: String, cues: [CueSection]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        guard currentUrl?.lastPathComponent == songId else { return }
        self.cues = cues
        if cues.isEmpty {
            self.currentCueIdx = 0
        } else {
            self.currentCueIdx = min(self.currentCueIdx, cues.count - 1)
        }
    }
    
    func setTimeSignature(_ tsString: String) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let parts = tsString.split(separator: "/")
        if parts.count >= 2, let n = Int(parts[0]), let d = Int(parts[1]) {
            self.timeSignature = (n, d)
        } else if let n = Int(parts[0]) {
            self.timeSignature = (n, 4)
        }
        osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
    }
    
    // MARK: - Salto Quantizado de Cues (Seamless Jump no Tempo 1 com Voz Guia)
    
    func triggerCue(idx: Int, quantize: Bool = true) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard idx >= 0, idx < cues.count else { return }
        
        let targetCue = cues[idx]
        let targetTime = targetCue.time
        let targetFrame = Int64(targetTime * sampleRate)
        
        if !quantize || !isPlaying {
            posFrame = targetFrame
            currentCueIdx = idx
            queuedCueIdx = nil
            queuedJump = nil
            guideLeadIn = nil
            updateCurrentCueIdx()
            return
        }
        
        // Se clicar na seção já agendada, cancela a fila
        if queuedCueIdx == idx {
            queuedCueIdx = nil
            queuedJump = nil
            guideLeadIn = nil
            return
        }
        
        // Localiza a seção ativa em reprodução
        let curSec = sampleRate > 0 ? (Double(posFrame) / sampleRate) : 0.0
        var activeIdx = currentCueIdx
        for (i, c) in cues.enumerated().reversed() {
            if curSec >= c.time - 0.15 {
                activeIdx = i
                break
            }
        }
        
        // Se clicar na seção que já está tocando, cancela qualquer salto pendente
        if idx == activeIdx || idx == currentCueIdx {
            if queuedCueIdx != nil || queuedJump != nil || guideLeadIn != nil {
                queuedCueIdx = nil
                queuedJump = nil
                guideLeadIn = nil
            }
            return
        }
        
        // Fim da seção atual
        let endSec: Double = (activeIdx + 1 < cues.count) ? cues[activeIdx + 1].time : (sampleRate > 0 ? (Double(totalFrames) / sampleRate) : targetTime)
        let secPerBeat = bpm > 0 ? (60.0 / bpm) : 0.5
        let beatsPerBar = Double(max(1, timeSignature.0)) * (4.0 / Double(max(1, timeSignature.1)))
        let secPerBar = secPerBeat * beatsPerBar
        let leadInBars = max(0.5, guideLeadInBars)
        
        let leadInSec: Double
        if idx == activeIdx + 1 {
            leadInSec = 0.0
        } else {
            let maxAvail = max(0.0, targetTime)
            let desired = min(leadInBars * secPerBar, maxAvail)
            let activeStart = cues[activeIdx].time
            let activeDur = max(0.0, endSec - activeStart)
            leadInSec = activeDur > 0 ? min(desired, activeDur * 0.5) : 0.0
        }
        
        let transitionSec = endSec - leadInSec
        let toSec = targetTime - leadInSec
        let timeLeft = endSec - curSec
        
        if timeLeft <= 0.25 {
            // Salto direto no tempo 1
            posFrame = targetFrame
            currentCueIdx = idx
            queuedCueIdx = nil
            queuedJump = nil
            guideLeadIn = nil
            updateCurrentCueIdx()
            return
        } else if curSec >= transitionSec && leadInSec > 0.0 {
            let leadInStart = targetFrame - Int64(timeLeft * sampleRate)
            if leadInStart >= 0 {
                guideLeadIn = GuideLeadInInfo(
                    posFrame: leadInStart,
                    endFrame: targetFrame,
                    targetDownbeatFrame: targetFrame,
                    cueIdx: idx,
                    isLoop: false
                )
                queuedCueIdx = idx
                queuedJump = nil
                return
            }
        }
        
        queuedCueIdx = idx
        guideLeadIn = nil
        queuedJump = QueuedJumpInfo(
            leadInAtFrame: Int64(transitionSec * sampleRate),
            leadInStartFrame: Int64(toSec * sampleRate),
            targetDownbeatFrame: targetFrame,
            cueIdx: idx
        )
    }
    
    func toggleLoop(cueIdx: Int? = nil, infinite: Bool = false) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let targetCue = cueIdx ?? currentCueIdx
        
        if infinite {
            if loopActive && loopInfinite && (cueIdx == nil || loopCueIdx == cueIdx) {
                loopActive = false
                loopInfinite = false
                loopCueIdx = nil
            } else {
                loopActive = true
                loopInfinite = true
                loopCueIdx = targetCue
            }
        } else {
            if loopActive && !loopInfinite && (cueIdx == nil || loopCueIdx == cueIdx) {
                loopActive = false
                loopInfinite = false
                loopCueIdx = nil
            } else {
                loopActive = true
                loopInfinite = false
                loopCueIdx = targetCue
            }
        }
    }
    
    func fadeTracks(direction: String = "toggle", duration: Double = 3.0) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard isPlaying else { return }
        
        let targetOut: Bool
        if direction == "out" {
            targetOut = true
        } else if direction == "in" {
            targetOut = false
        } else {
            targetOut = (tracksFadeGain >= 0.5 && tracksFadeState != "faded_out")
        }
        
        tracksFadeTotalFrames = Int(max(0.5, duration) * sampleRate)
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
    
    func triggerCue(index: Int, quantize: Bool = true) {
        triggerCue(idx: index, quantize: quantize)
    }
    
    func toggleInfiniteLoop() {
        toggleLoop(infinite: true)
    }
    
    func fadeStop(duration: Double = 3.0) {
        fadeTracks(direction: "toggle", duration: duration)
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
        
        let beatSec = bpm > 0 ? (60.0 / bpm) : 0.5
        let beatsPerBar = Double(max(1, timeSignature.0)) * (4.0 / Double(max(1, timeSignature.1)))
        let secPerBar = max(0.01, beatSec * beatsPerBar)
        let curBar = Int(curSec / secPerBar) + 1
        let curBeat = Int((curSec.truncatingRemainder(dividingBy: secPerBar)) / max(0.01, beatSec)) + 1
        
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
            "current_seconds": curSec,
            "current_time": curSec,
            "total_seconds": totSec,
            "total_time": totSec,
            "current_cue": cueDict as Any,
            "current_cue_idx": currentCueIdx,
            "queued_cue_idx": queuedCueIdx as Any,
            "click_vol": Double(clickVol),
            "vs_vol": Double(vsVol),
            "volume_l": Double(clickVol),
            "volume_r": Double(vsVol),
            "click_mute": clickMute,
            "vs_mute": vsMute,
            "tracks_fade_state": tracksFadeState,
            "is_faded_out": (tracksFadeState == "faded_out"),
            "fade_active": (tracksFadeState == "faded_out" || tracksFadeState == "fading_out"),
            "loop_active": loopActive,
            "loop_infinite": loopInfinite,
            "loop_cue_idx": loopCueIdx as Any,
            "bpm": bpm,
            "time_signature": "\(timeSignature.0)/\(timeSignature.1)",
            "bar": curBar,
            "beat": curBeat,
            "pad_active": padActive,
            "pad_playing": padActive,
            "pad_key": padKey,
            "device": currentDeviceName,
            "output_device_name": currentDeviceName,
            "output_device_id": Int(currentDeviceId)
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
