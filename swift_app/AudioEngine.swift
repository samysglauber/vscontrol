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
/// crossfades instantâneos e MIDI Clock embutido.
typealias NativeAudioEngine = AudioEngine

final class AudioEngine {
    static let shared = AudioEngine()
    
    // CoreAudio HAL Output Unit (AUHAL 100% Nativo de Baixa Latência)
    private var outputAudioUnit: AudioComponentInstance?
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    
    // Sincronizadores
    let osc = OSCClient()
    let midiClock = MIDIClock()
    
    // Dados de Áudio Carregados
    var currentUrl: URL?
    var sampleRate: Double = 44100.0
    var audioLeft: [Float] = []
    var audioRight: [Float] = []
    var isChannelsInverted: Bool = false
    var totalFrames: Int64 = 0
    var posFrame: Int64 = 0
    var bpm: Double = 120.0
    var timeSignature: (Int, Int) = (4, 4)
    var cues: [CueSection] = []
    var fullWaveform: [Double] = []
    var totalDuration: Double {
        return sampleRate > 0 ? Double(totalFrames) / sampleRate : 0.0
    }
    
    // Metrônomo Procedural em Tempo Real (Opção 1 - Playback MultiTracks)
    var isProceduralMetronome: Bool = false
    var proceduralSubPerBeat: Int = 1
    private var clickSample1: [Float] = [] // Click Track-1
    private var clickSample2: [Float] = [] // Click Track-2
    
    // Estado do Transporte
    var isPlaying: Bool = false
    var currentCueIdx: Int = 0
    var queuedCueIdx: Int? = nil
    var queuedJump: QueuedJumpInfo? = nil
    var guideLeadIn: GuideLeadInInfo? = nil
    var guideLeadInBars: Double = 1.0
    var autoPanStereo: Bool = true
    
    // Sincronização de Disparo de Play/Stop no Ableton Live via OSC
    var enableAbletonPlaySync: Bool = true
    var enableAbletonSceneSync: Bool = true
    var currentSetlistIndex: Int = 0
    var abletonTriggerOffsetMs: Double = 0.0
    var syncTempoToDaw: Bool = true
    var triggerAtBeat1: Bool = false
    
    var effectiveDownbeatFrame: Int64 {
        let offsetFrames = Int64(round((abletonTriggerOffsetMs / 1000.0) * sampleRate))
        let base = triggerAtBeat1 ? firstDownbeatFrame : 0
        return max(0, base + offsetFrames)
    }
    var enableMidiClock: Bool {
        get { midiClock.isEnabled }
        set { midiClock.isEnabled = newValue }
    }
    var midiClockOffsetMs: Double {
        get { midiClock.offsetMs }
        set { midiClock.offsetMs = newValue }
    }
    
    func updateOscConfig(host: String, port: UInt16) {
        osc.updateEndpoint(host: host, port: port)
    }
    
    // Alinhamento de Disparo no Tempo 1 (Primeiro clique da contagem / downbeat)
    var firstDownbeatFrame: Int64 = 0
    var abletonPlayTriggered: Bool = false
    
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
    
    // Dispositivo de Saída
    var currentDeviceId: AudioDeviceID = 0
    var currentDeviceName: String = ""
    
    // Callbacks de Eventos
    var onPlayStateChanged: ((Bool) -> Void)?
    var onCueJumped: ((Int) -> Void)?
    var onSongEnded: (() -> Void)?
    var onAbletonSynced: (() -> Void)?
    
    init() {
        lock.initialize(to: os_unfair_lock())
        setupAudioEngine()
        let (c1, c2) = MetronomeGenerator.shared.getClickSamples(sampleRate: 44100.0)
        self.clickSample1 = c1
        self.clickSample2 = c2
    }
    
    deinit {
        stopAndDisposeAudioUnit()
        lock.deallocate()
    }
    
    private func stopAndDisposeAudioUnit() {
        if let au = outputAudioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            outputAudioUnit = nil
        }
    }
    
    // MARK: - Configuração CoreAudio (AUHAL 100% Nativo de Baixa Latência)
    
    func getDefaultOutputDeviceId() -> AudioDeviceID {
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultId: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &sz, &defaultId)
        return defaultId
    }
    
    private func setupAudioEngine(targetDevice: AudioDeviceID? = nil) {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            print("⚠️ [AudioEngine] HALOutput não encontrado")
            return
        }
        var au: AudioComponentInstance?
        let newErr = AudioComponentInstanceNew(comp, &au)
        guard newErr == noErr, let auInstance = au else {
            print("⚠️ [AudioEngine] Falha ao criar AudioComponentInstance: \(newErr)")
            return
        }
        self.outputAudioUnit = auInstance
        
        let devId = (targetDevice != nil && targetDevice != 0) ? targetDevice! : getDefaultOutputDeviceId()
        if devId != 0 {
            var dId = devId
            AudioUnitSetProperty(
                auInstance,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dId,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            self.currentDeviceId = devId
        }
        
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: self.sampleRate > 0 ? self.sampleRate : 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(
            auInstance,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        let renderCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData -> OSStatus in
            guard let ioData = ioData else { return noErr }
            let engine = Unmanaged<AudioEngine>.fromOpaque(inRefCon).takeUnretainedValue()
            return engine.renderAudio(frameCount: Int(inNumberFrames), outputData: ioData)
        }
        
        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(
            auInstance,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        
        let initErr = AudioUnitInitialize(auInstance)
        if initErr != noErr {
            print("⚠️ [AudioEngine] Falha ao inicializar AudioUnit: \(initErr)")
            return
        }
        
        let startErr = AudioOutputUnitStart(auInstance)
        if startErr != noErr {
            print("⚠️ [AudioEngine] Falha ao iniciar AudioOutputUnit: \(startErr)")
        } else {
            print("🔊 [AudioEngine] CoreAudio AUHAL ativo com sucesso no dispositivo [ID: \(devId)]")
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
            // Silêncio
            if isDeinterleaved {
                ptrL.initialize(repeating: 0, count: frameCount)
                ptrR.initialize(repeating: 0, count: frameCount)
            } else {
                ptrL.initialize(repeating: 0, count: frameCount * 2)
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
            midiClock.sendStop(sendTransport: enableAbletonPlaySync && abletonPlayTriggered)
            if abletonPlayTriggered && enableAbletonPlaySync {
                osc.sendStopPlaying()
            }
            abletonPlayTriggered = false
            DispatchQueue.main.async { [weak self] in
                self?.onPlayStateChanged?(false)
                self?.onSongEnded?()
            }
            return noErr
        }
        
        // 3. Renderização precisa de áudio com suporte a Salto Quantizado, Loop e Fade
        var curPos = posFrame
        
        // Parâmetros de Lead-In para Loop calculados uma vez por buffer (alta performance e zero alocação)
        var loopInfo: (start: Int64, end: Int64, leadInAt: Int64, cueIdx: Int)? = nil
        if loopActive && guideLeadIn == nil && queuedJump == nil {
            let targetLoop = loopCueIdx ?? currentCueIdx
            if targetLoop >= 0 && targetLoop < cues.count {
                let currStart = Int64(round(cues[targetLoop].time * sampleRate))
                let currEnd = (targetLoop + 1 < cues.count) ? Int64(round(cues[targetLoop + 1].time * sampleRate)) : totalFrames
                
                // O Lead-In e a repetição de loop só operam quando o cursor estiver estritamente dentro da seção alvo
                if curPos >= currStart && curPos < currEnd {
                    let targetTime = cues[targetLoop].time
                    let endSec = Double(currEnd) / (sampleRate > 0 ? sampleRate : 44100.0)
                    let activeDur = max(0.0, endSec - targetTime)
                    let secPerBeat = bpm > 0 ? (60.0 / bpm) : 0.5
                    let beatsPerBar = Double(max(1, timeSignature.0)) * (4.0 / Double(max(1, timeSignature.1)))
                    let secPerBar = secPerBeat * beatsPerBar
                    let leadInBars = max(0.0, guideLeadInBars)
                    let desiredLeadInSec = min(leadInBars * secPerBar, targetTime)
                    let leadInSec = (activeDur > 0 && leadInBars > 0.0) ? min(desiredLeadInSec, activeDur * 0.5) : 0.0
                    let leadInFrames = Int64(leadInSec * sampleRate)
                    let leadInAt = currEnd - leadInFrames
                    loopInfo = (start: currStart, end: currEnd, leadInAt: leadInAt, cueIdx: targetLoop)
                }
            }
        }
        
        let metroSr = sampleRate > 0 ? sampleRate : 44100.0
        let metroBpm = bpm > 30 ? bpm : 120.0
        let metroSubFactor = max(1, proceduralSubPerBeat)
        let metroStepFrames = (60.0 * metroSr) / (metroBpm * Double(metroSubFactor))
        let metroBeatsPerBar = max(1, timeSignature.0)

        for i in 0..<frameCount {
            var sampleL: Float = 0.0
            var sampleR: Float = 0.0
            
            if isProceduralMetronome {
                sampleR = 0.0
                
                // Salto agendado alcançou o ponto de virada do compasso
                if let jump = queuedJump, curPos >= jump.leadInAtFrame {
                    curPos = jump.targetDownbeatFrame
                    currentCueIdx = jump.cueIdx
                    queuedCueIdx = nil
                    queuedJump = nil
                    let jumpedIdx = jump.cueIdx
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(jumpedIdx)
                    }
                }
                // Repetição de seção em loop
                else if let loop = loopInfo, curPos >= loop.end {
                    curPos = loop.start
                    currentCueIdx = loop.cueIdx
                    if !loopInfinite {
                        loopActive = false
                        loopCueIdx = nil
                    }
                    let loopedIdx = loop.cueIdx
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(loopedIdx)
                    }
                }
                
                // Síntese sample-accurate em tempo real do click no Canal L
                let stepIdx = Int(Double(curPos) / metroStepFrames)
                let stepStartFrame = Int64(round(Double(stepIdx) * metroStepFrames))
                let clickOffset = Int(curPos - stepStartFrame)
                
                // Regra Sonora do Metrônomo:
                // - Em 3/4: clicktrack-1, clicktrack-2, clicktrack-2 (reiniciando no tempo 1 de cada compasso).
                // - Demais compassos: sempre clicktrack-1 e clicktrack-2 em sequência contínua, sem marcação de compasso.
                let isTripleMeter = (metroBeatsPerBar == 3)
                let useClick1: Bool
                if isTripleMeter {
                    let beatInBar = (stepIdx / metroSubFactor) % 3
                    let subInBeat = stepIdx % metroSubFactor
                    useClick1 = (beatInBar == 0 && subInBeat == 0)
                } else {
                    useClick1 = (stepIdx % 2 == 0)
                }
                
                let activeClickBuffer = useClick1 ? clickSample1 : clickSample2
                if clickOffset >= 0 && clickOffset < activeClickBuffer.count {
                    sampleL = activeClickBuffer[clickOffset]
                }
                
                curPos += 1
            }
            // A. Lead-In de Voz Guia em andamento no Canal L
            else if var guide = guideLeadIn {
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
            // C. Repetição da seção (Loop 1x ou Infinito) se ativo com Lead-In de Voz Guia antecipado
            else if let loop = loopInfo {
                let framesLeft = loop.end - curPos
                let leadInPos = loop.start - framesLeft
                let minLeadInFrames = Int64(0.25 * sampleRate)
                
                if guideLeadInBars > 0.0 && curPos >= loop.leadInAt && framesLeft > minLeadInFrames && leadInPos >= 0 && leadInPos < loop.start - 512 {
                    // Ativa o Lead-In exclusivo no Canal L (Click + Guia da seção sendo repetida)
                    // enquanto o Canal R continua tocando normalmente até o downbeat do próximo compasso
                    guideLeadIn = GuideLeadInInfo(
                        posFrame: leadInPos,
                        endFrame: loop.start,
                        targetDownbeatFrame: loop.start,
                        cueIdx: loop.cueIdx,
                        isLoop: true
                    )
                    loopInfo = nil
                    
                    let gFrame = Int(leadInPos)
                    sampleL = (gFrame < audioLeft.count && gFrame >= 0) ? audioLeft[gFrame] : 0.0
                    let rFrame = Int(curPos)
                    sampleR = (rFrame < audioRight.count && rFrame >= 0) ? audioRight[rFrame] : 0.0
                    curPos += 1
                } else if curPos >= loop.end {
                    // Salto direto no tempo 1 caso não haja lead-in anterior (ex: intro no 0:00 ou fim imediato)
                    curPos = loop.start
                    currentCueIdx = loop.cueIdx
                    if !loopInfinite {
                        loopActive = false
                        loopCueIdx = nil
                    }
                    let f = Int(curPos)
                    sampleL = (f < audioLeft.count && f >= 0) ? audioLeft[f] : 0.0
                    sampleR = (f < audioRight.count && f >= 0) ? audioRight[f] : 0.0
                    curPos += 1
                    let loopedIdx = loop.cueIdx
                    DispatchQueue.main.async { [weak self] in
                        self?.onCueJumped?(loopedIdx)
                    }
                } else {
                    let f = Int(curPos)
                    sampleL = (f < audioLeft.count && f >= 0) ? audioLeft[f] : 0.0
                    sampleR = (f < audioRight.count && f >= 0) ? audioRight[f] : 0.0
                    curPos += 1
                }
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
            
            let outL: Float
            let outR: Float
            if autoPanStereo {
                outL = effL
                outR = max(-1.0, min(1.0, effR))
            } else {
                let combined = max(-1.0, min(1.0, effL + effR))
                outL = combined
                outR = combined
            }
            if isDeinterleaved {
                ptrL[i] = outL
                ptrR[i] = outR
            } else {
                ptrL[2 * i] = outL
                ptrL[2 * i + 1] = outR
            }
        }
        
        posFrame = curPos
        
        // Disparo com Alinhamento no Início ou no Tempo 1 (com compensação de offset)
        if !abletonPlayTriggered && isPlaying {
            if curPos >= effectiveDownbeatFrame {
                abletonPlayTriggered = true
                if syncTempoToDaw {
                    osc.sendTempo(self.bpm)
                    osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
                }
                midiClock.sendContinue(sendTransport: enableAbletonPlaySync)
                midiClock.resetTick(currentFrame: triggerAtBeat1 ? firstDownbeatFrame : 0, sampleRate: sampleRate, bpm: bpm)
                if enableAbletonSceneSync {
                    osc.fireScene(index: currentSetlistIndex)
                } else if enableAbletonPlaySync {
                    osc.sendContinuePlaying()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onAbletonSynced?()
                }
            }
        }
        
        if abletonPlayTriggered {
            let clkStart = triggerAtBeat1 ? max(firstDownbeatFrame, startFrame) : startFrame
            midiClock.processFrames(startFrame: clkStart, nFrames: frameCount, sampleRate: sampleRate, bpm: bpm)
        }
        updateCurrentCueIdx()
        
        return noErr
    }
    
    private func updateCurrentCueIdx() {
        guard !cues.isEmpty else { return }
        let currentSec = Double(posFrame) / (sampleRate > 0 ? sampleRate : 44100.0)
        let tolerance = max(0.025, 2.0 / (sampleRate > 0 ? sampleRate : 44100.0))
        var found = false
        for (i, cue) in cues.enumerated().reversed() {
            if currentSec >= (cue.time - tolerance) {
                if currentCueIdx != i {
                    currentCueIdx = i
                }
                found = true
                break
            }
        }
        if !found {
            currentCueIdx = 0
        }
    }
    
    /// Detecta o frame do primeiro clique audível (Tempo 1 / início da contagem) no Canal L
    private func detectFirstClickFrame() -> Int64 {
        guard !audioLeft.isEmpty, sampleRate > 0 else { return 0 }
        let scanLimit = min(audioLeft.count, Int(3.0 * sampleRate))
        guard scanLimit > 0 else { return 0 }
        
        var maxAmp: Float = 0.0
        for i in 0..<scanLimit {
            let val = abs(audioLeft[i])
            if val > maxAmp { maxAmp = val }
        }
        guard maxAmp >= 0.02 else { return 0 }
        
        let threshold = max(0.04, maxAmp * 0.25)
        for i in 0..<scanLimit {
            if abs(audioLeft[i]) > threshold {
                let windowEnd = min(scanLimit, i + 200)
                var peakIdx = i
                var peakVal = abs(audioLeft[i])
                for j in i..<windowEnd {
                    let v = abs(audioLeft[j])
                    if v > peakVal {
                        peakVal = v
                        peakIdx = j
                    }
                }
                return Int64(peakIdx)
            }
        }
        return 0
    }
    
    // MARK: - Controle de Reprodução
    
    func loadSong(_ song: SongItem, crossfade: Bool = false, crossfadeDuration: Double = 4.0) {
        if song.is_metronome == true || song.path.starts(with: "virtual://") || song.isMetronomeTrack {
            loadProceduralMetronome(song, crossfade: crossfade, crossfadeDuration: crossfadeDuration)
            return
        }
        let url = URL(fileURLWithPath: song.path)
        try? loadSong(
            url: url,
            bpm: song.bpm ?? 120.0,
            cues: song.cues ?? [],
            timeSignature: song.time_signature ?? "4/4",
            crossfade: crossfade,
            crossfadeDuration: crossfadeDuration,
            isInverted: song.is_inverted
        )
    }

    func loadProceduralMetronome(_ song: SongItem, crossfade: Bool = false, crossfadeDuration: Double = 4.0) {
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
        
        self.isProceduralMetronome = true
        self.currentUrl = URL(string: song.path)
        self.sampleRate = 44100.0
        self.audioLeft = []
        self.audioRight = []
        
        let duration = (song.total_duration ?? 0) > 0 ? song.total_duration! : 600.0
        self.totalFrames = Int64(duration * self.sampleRate)
        self.posFrame = 0
        self.bpm = (song.bpm ?? 120.0) > 30 ? (song.bpm ?? 120.0) : 120.0
        
        let parts = (song.time_signature ?? "4/4").split(separator: "/")
        if parts.count >= 2, let n = Int(parts[0]), let d = Int(parts[1]) {
            self.timeSignature = (n, d)
        } else {
            self.timeSignature = (4, 4)
        }
        
        var subPerBeat = 1
        if song.subdivide == true {
            let sub = song.subdivision ?? "1/4"
            if sub == "1/8" { subPerBeat = 2 }
            else if sub == "1/16" { subPerBeat = 4 }
            else if sub == "1/8T" || sub == "1/12" { subPerBeat = 3 }
        }
        self.proceduralSubPerBeat = subPerBeat
        
        var resolvedCues = song.cues ?? []
        let hasGenericSlices = resolvedCues.contains(where: { $0.name.hasPrefix("Section ") || $0.name == "Count-In" })
        if resolvedCues.isEmpty || hasGenericSlices {
            resolvedCues = MetronomeGenerator.shared.generateMetronomeCues(
                durationSec: duration,
                bpm: self.bpm,
                timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)"
            )
        }
        self.cues = resolvedCues
        
        let peaks = (song.full_waveform?.isEmpty == false) ? song.full_waveform! : MetronomeGenerator.shared.generateMetronomeWaveform(
            durationSec: duration,
            bpm: self.bpm,
            timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)",
            subdivision: song.subdivision ?? "1/4",
            subdivide: song.subdivide ?? false
        )
        self.fullWaveform = peaks
        
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
        
        self.firstDownbeatFrame = 0
        self.abletonPlayTriggered = false
        
        midiClock.resetTick(currentFrame: 0, sampleRate: self.sampleRate, bpm: self.bpm)
        
        if crossfade {
            self.isPlaying = true
            abletonPlayTriggered = true
            if syncTempoToDaw {
                osc.sendTempo(self.bpm)
                osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
            }
            midiClock.sendContinue(sendTransport: enableAbletonPlaySync)
            if enableAbletonSceneSync {
                osc.fireScene(index: currentSetlistIndex)
            } else if enableAbletonPlaySync {
                osc.sendContinuePlaying()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onAbletonSynced?()
            }
        }
    }
    
    func loadSong(
        url: URL,
        bpm: Double,
        cues: [CueSection],
        timeSignature: String = "4/4",
        crossfade: Bool = false,
        crossfadeDuration: Double = 4.0,
        isInverted: Bool? = nil
    ) throws {
        let (left, right, sr) = try loadAudioFileStereo(url: url)
        let filename = url.lastPathComponent
        
        var effInverted: Bool = false
        if let inv = isInverted {
            effInverted = inv
        } else if let savedSong = SongLibrary.shared.getSong(id: filename), let savedInv = savedSong.is_inverted {
            effInverted = savedInv
        }
        
        let effLeft = effInverted ? right : left
        let effRight = effInverted ? left : right
        
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        self.isProceduralMetronome = false
        
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
        updateSampleRateIfNeeded(sr)
        self.audioLeft = effLeft
        self.audioRight = effRight
        self.isChannelsInverted = effInverted
        self.totalFrames = Int64(effLeft.count)
        self.posFrame = 0
        self.bpm = bpm > 30 ? bpm : 120.0
        
        let parts = timeSignature.split(separator: "/")
        if parts.count >= 2, let n = Int(parts[0]), let d = Int(parts[1]) {
            self.timeSignature = (n, d)
        } else {
            self.timeSignature = (4, 4)
        }
        
        let totSec = sr > 0 ? Double(effLeft.count) / sr : 0.0
        var resolvedCues = cues
        if resolvedCues.isEmpty && totSec > 0 {
            resolvedCues = SongLibrary.shared.generateDefaultCues(
                totalDuration: totSec,
                bpm: self.bpm,
                timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)"
            )
        }
        self.cues = resolvedCues
        
        // Computa forma de onda real com Accelerate vDSP em alta resolução (7200 picos) a partir do canal de música (effRight)
        let peaks = SongLibrary.shared.computeWaveformPeaks(from: effRight, targetPeaks: 7200)
        self.fullWaveform = peaks
        
        // Salva na biblioteca SQLite para que a música nova fique permanentemente salva
        let needsAuto = SongLibrary.shared.needsAutoCueAnalysis(songId: filename)
        
        let existingItem = SongLibrary.shared.getSong(id: filename)
        if existingItem == nil && !resolvedCues.isEmpty {
            SongLibrary.shared.saveCues(
                songId: filename,
                cues: resolvedCues,
                bpm: self.bpm,
                timeSignature: "\(self.timeSignature.0)/\(self.timeSignature.1)",
                fullWaveform: peaks,
                autoAnalysis: needsAuto ? "pending" : nil,
                isInverted: effInverted
            )
        } else if let existing = existingItem, (existing.full_waveform?.count ?? 0) < 7000 {
            SongLibrary.shared.saveCues(
                songId: filename,
                cues: existing.cues ?? resolvedCues,
                bpm: existing.bpm ?? self.bpm,
                timeSignature: existing.time_signature ?? "\(self.timeSignature.0)/\(self.timeSignature.1)",
                fullWaveform: peaks,
                autoAnalysis: existing.auto_analysis,
                guideLeadIn: existing.guide_lead_in,
                isInverted: effInverted
            )
        }
        
        if needsAuto {
            let num = self.timeSignature.0
            let den = self.timeSignature.1
            let explicitBpm = extractBpmFromFilename(filename)
            SongLibrary.shared.autoAnalyzeCues(
                songId: filename,
                left: effLeft,
                right: effRight,
                sampleRate: sr,
                bpm: explicitBpm ?? 0.0,
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
        
        self.firstDownbeatFrame = detectFirstClickFrame()
        self.abletonPlayTriggered = false
        
        // Alinha os ticks internamente sem emitir pacotes até a música de fato tocar o Tempo 1
        midiClock.resetTick(currentFrame: self.firstDownbeatFrame, sampleRate: self.sampleRate, bpm: self.bpm)
        
        if crossfade {
            self.isPlaying = true
            if posFrame >= effectiveDownbeatFrame {
                abletonPlayTriggered = true
                if syncTempoToDaw {
                    osc.sendTempo(self.bpm)
                    osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
                }
                midiClock.sendContinue(sendTransport: enableAbletonPlaySync)
                if enableAbletonSceneSync {
                    osc.fireScene(index: currentSetlistIndex)
                } else if enableAbletonPlaySync {
                    osc.sendContinuePlaying()
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onAbletonSynced?()
                }
            } else {
                abletonPlayTriggered = false
            }
        }
    }
    
    func setInvertedChannels(_ inverted: Bool) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !isProceduralMetronome, !audioLeft.isEmpty, !audioRight.isEmpty else { return }
        if isChannelsInverted != inverted {
            let tmp = audioLeft
            audioLeft = audioRight
            audioRight = tmp
            isChannelsInverted = inverted
            
            let peaks = SongLibrary.shared.computeWaveformPeaks(from: audioRight, targetPeaks: 7200)
            self.fullWaveform = peaks
        }
    }
    
    func play() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard !audioLeft.isEmpty || isProceduralMetronome else { return }
        
        tracksFadeState = "normal"
        tracksFadeGain = 1.0
        tracksFadeFramesLeft = 0
        isPlaying = true
        
        if !abletonPlayTriggered && posFrame >= effectiveDownbeatFrame {
            abletonPlayTriggered = true
            if syncTempoToDaw {
                osc.sendTempo(self.bpm)
                osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
            }
            midiClock.sendContinue(sendTransport: enableAbletonPlaySync)
            if enableAbletonSceneSync {
                osc.fireScene(index: currentSetlistIndex)
            } else if enableAbletonPlaySync {
                osc.sendContinuePlaying()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onAbletonSynced?()
            }
        } else if !abletonPlayTriggered {
            // Aguarda atingir o Tempo 1 (com compensação de offset) no callback do CoreAudio
            abletonPlayTriggered = false
        }
        
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
        
        if abletonPlayTriggered {
            midiClock.sendStop(sendTransport: enableAbletonPlaySync)
            if enableAbletonPlaySync {
                osc.sendStopPlaying()
            }
        }
        if posFrame < effectiveDownbeatFrame {
            abletonPlayTriggered = false
        }
        
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
        
        midiClock.sendStop(sendTransport: enableAbletonPlaySync && abletonPlayTriggered)
        midiClock.resetTick(currentFrame: 0, sampleRate: sampleRate, bpm: bpm)
        if abletonPlayTriggered && enableAbletonPlaySync {
            osc.sendStopPlaying()
        }
        abletonPlayTriggered = false
        
        DispatchQueue.main.async { [weak self] in
            self?.onPlayStateChanged?(false)
        }
    }
    
    func seek(seconds: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard totalFrames > 0 else { return }
        
        let target = Int64(round(seconds * sampleRate))
        posFrame = max(0, min(target, totalFrames - 1))
        queuedCueIdx = nil
        queuedJump = nil
        guideLeadIn = nil
        if posFrame >= effectiveDownbeatFrame {
            abletonPlayTriggered = true
        } else {
            abletonPlayTriggered = false
        }
        midiClock.resetTick(currentFrame: posFrame, sampleRate: sampleRate, bpm: bpm)
        updateCurrentCueIdx()
    }
    
    func updateCues(_ newCues: [CueSection]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        self.cues = newCues
        if newCues.isEmpty {
            self.currentCueIdx = 0
        } else {
            self.currentCueIdx = min(self.currentCueIdx, newCues.count - 1)
        }
        updateCurrentCueIdx()
    }
    
    func setBpm(_ newBpm: Double) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        self.bpm = newBpm
        if syncTempoToDaw && isPlaying && abletonPlayTriggered {
            osc.sendTempo(newBpm)
        }
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
        updateCurrentCueIdx()
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
        if syncTempoToDaw && isPlaying && abletonPlayTriggered {
            osc.sendTimeSignature(numerator: self.timeSignature.0, denominator: self.timeSignature.1)
        }
    }
    
    // MARK: - Salto Quantizado de Cues (Seamless Jump no Tempo 1 com Voz Guia)
    
    func triggerCue(idx: Int, quantize: Bool = true) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard idx >= 0, idx < cues.count else { return }
        
        let targetCue = cues[idx]
        let targetTime = targetCue.time
        let targetFrame = Int64(round(targetTime * sampleRate))
        
        if !quantize || !isPlaying {
            posFrame = targetFrame
            currentCueIdx = idx
            queuedCueIdx = nil
            queuedJump = nil
            guideLeadIn = nil
            if posFrame >= effectiveDownbeatFrame {
                abletonPlayTriggered = true
            }
            midiClock.resetTick(currentFrame: posFrame, sampleRate: sampleRate, bpm: bpm)
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
        let leadInBars = max(0.0, guideLeadInBars)
        
        let leadInSec: Double
        if idx == activeIdx + 1 || leadInBars <= 0.0 {
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
            if posFrame >= effectiveDownbeatFrame {
                abletonPlayTriggered = true
            }
            midiClock.resetTick(currentFrame: posFrame, sampleRate: sampleRate, bpm: bpm)
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
    
    func cancelQueuedJump() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        queuedCueIdx = nil
        queuedJump = nil
        guideLeadIn = nil
    }
    
    func toggleLoop(cueIdx: Int? = nil, infinite: Bool = false) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        
        let targetCue = cueIdx ?? currentCueIdx
        
        if infinite {
            if loopActive && loopInfinite && (cueIdx == nil ? (loopCueIdx == nil || loopCueIdx == targetCue) : loopCueIdx == cueIdx) {
                loopActive = false
                loopInfinite = false
                loopCueIdx = nil
                if guideLeadIn?.isLoop == true {
                    guideLeadIn = nil
                }
            } else {
                loopActive = true
                loopInfinite = true
                loopCueIdx = targetCue
            }
        } else {
            if loopActive && !loopInfinite && (cueIdx == nil ? (loopCueIdx == nil || loopCueIdx == targetCue) : loopCueIdx == cueIdx) {
                loopActive = false
                loopInfinite = false
                loopCueIdx = nil
                if guideLeadIn?.isLoop == true {
                    guideLeadIn = nil
                }
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
        let activeId = (currentDeviceId != 0) ? currentDeviceId : getDefaultOutputDeviceId()
        return getAvailableOutputDevices().map { ($0.id, $0.name, $0.id == activeId) }
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
            "device": currentDeviceName,
            "output_device_name": currentDeviceName,
            "output_device_id": Int(currentDeviceId)
        ]
    }
    
    func updateSampleRateIfNeeded(_ newSr: Double) {
        guard let au = outputAudioUnit, newSr > 0 else { return }
        var curFmt = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &curFmt, &sz) == noErr {
            if abs(curFmt.mSampleRate - newSr) > 1.0 {
                AudioOutputUnitStop(au)
                AudioUnitUninitialize(au)
                var streamFormat = AudioStreamBasicDescription(
                    mSampleRate: newSr,
                    mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                    mBytesPerPacket: 4,
                    mFramesPerPacket: 1,
                    mBytesPerFrame: 4,
                    mChannelsPerFrame: 2,
                    mBitsPerChannel: 32,
                    mReserved: 0
                )
                AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, sz)
                AudioUnitInitialize(au)
                AudioOutputUnitStart(au)
            }
        }
    }
    
    func setOutputDevice(deviceId: AudioDeviceID, deviceName: String = "") {
        guard let au = self.outputAudioUnit else {
            recreateAudioUnit(for: deviceId, name: deviceName)
            return
        }
        
        if self.currentDeviceId == deviceId && deviceId != 0 {
            if !deviceName.isEmpty { self.currentDeviceName = deviceName }
            return
        }
        
        // 1. Para temporariamente o AudioUnit antes da troca de hardware
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        
        var dId = deviceId
        let setErr = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dId,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        
        // 2. Reaplica o formato de entrada Float32 não-intercalado (L/R)
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: self.sampleRate > 0 ? self.sampleRate : 44100.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        
        let initErr = AudioUnitInitialize(au)
        let startErr = AudioOutputUnitStart(au)
        
        if setErr == noErr && initErr == noErr && startErr == noErr {
            self.currentDeviceId = deviceId
            self.currentDeviceName = deviceName
            print("🔊 [AudioEngine] Dispositivo de saída alterado para: \(deviceName) [ID: \(deviceId)]")
        } else {
            print("⚠️ [AudioEngine] Aviso ao alternar no AU existente (err=\(setErr), init=\(initErr), start=\(startErr)). Recriando AUHAL...")
            recreateAudioUnit(for: deviceId, name: deviceName)
        }
    }
    
    private func recreateAudioUnit(for deviceId: AudioDeviceID, name: String) {
        stopAndDisposeAudioUnit()
        setupAudioEngine(targetDevice: deviceId)
        self.currentDeviceId = deviceId
        if !name.isEmpty { self.currentDeviceName = name }
        print("🔊 [AudioEngine] AUHAL recriado e ativo para: \(name) [ID: \(deviceId)]")
    }
}

// MARK: - Leitor de Arquivos de Áudio Estéreo (ExtAudioFile / AVAudioFile)

func loadAudioFileStereo(url: URL) throws -> (left: [Float], right: [Float], sampleRate: Double) {
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw NSError(domain: "AudioEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Falha ao alocar buffer PCM"])
    }
    try file.read(into: buffer)
    
    let sr = format.sampleRate
    let n = Int(buffer.frameLength)
    guard let channelData = buffer.floatChannelData else {
        throw NSError(domain: "AudioEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Canais Float32 não disponíveis"])
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
