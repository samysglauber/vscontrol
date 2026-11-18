import Foundation
import AVFoundation

/// Gerador Nativo em Swift de Metrônomos Procedurais (Opção 1 - Playback MultiTracks).
/// Zero arquivos gerados no disco (0 MB).
/// Síntese de áudio procedural sample-accurate em tempo real pelo NativeAudioEngine:
/// - Canal L (In-Ear): Click rítmico cristalino de estúdio com acentuação no tempo 1 e subdivisões
/// - Canal R (PA / VS): Silêncio absoluto
final class NativeMetronomeGenerator {
    static let shared = NativeMetronomeGenerator()
    
    private let sectionColors = [
        "#38bdf8", "#3b82f6", "#8b5cf6", "#ec4899",
        "#10b981", "#f59e0b", "#06b6d4", "#a855f7"
    ]
    
    private var clickCache: [Double: (downbeat: [Float], beat: [Float])] = [:]
    
    private func loadWavMono(path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        guard (try? audioFile.read(into: buffer)) != nil else { return nil }
        guard let channelData = buffer.floatChannelData else { return nil }
        let ptr = channelData[0]
        return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
    }
    
    func getClickSamples(sampleRate: Double = 44100.0) -> (downbeat: [Float], beat: [Float]) {
        if let cached = clickCache[sampleRate] {
            return cached
        }
        
        let fm = FileManager.default
        let baseDir = "/Users/samysglauber/Documents/AbletonTracks"
        let curDir = fm.currentDirectoryPath
        let tracksDir = NativeSongLibrary.shared.getTracksDirectory().path
        
        let c1Candidates = [
            "\(baseDir)/Click Track-1.wav",
            "\(baseDir)/resources/clicks/Click Track-1.wav",
            "\(curDir)/Click Track-1.wav",
            "\(tracksDir)/Click Track-1.wav"
        ]
        let c2Candidates = [
            "\(baseDir)/Click Track-2.wav",
            "\(baseDir)/resources/clicks/Click Track-2.wav",
            "\(curDir)/Click Track-2.wav",
            "\(tracksDir)/Click Track-2.wav"
        ]
        
        var s1: [Float]? = nil
        var s2: [Float]? = nil
        
        for p in c1Candidates {
            if fm.fileExists(atPath: p), let b = loadWavMono(path: p) {
                s1 = b
                break
            }
        }
        for p in c2Candidates {
            if fm.fileExists(atPath: p), let b = loadWavMono(path: p) {
                s2 = b
                break
            }
        }
        
        if var m1 = s1, var m2 = s2 {
            var max1: Float = 0
            var max2: Float = 0
            for x in m1 { max1 = max(max1, abs(x)) }
            for x in m2 { max2 = max(max2, abs(x)) }
            if max1 > 0 {
                for i in 0..<m1.count { m1[i] = (m1[i] / max1) * 0.95 }
            }
            if max2 > 0 {
                for i in 0..<m2.count { m2[i] = (m2[i] / max2) * 0.98 }
            }
            // m2 (Click Track-2, 1320 Hz) é o Downbeat (TIC acentuado)
            // m1 (Click Track-1, 820 Hz) é o Beat padrão (toc de corpo)
            let result = (downbeat: m2, beat: m1)
            clickCache[sampleRate] = result
            return result
        }
        
        // Fallback sintetizado cristalino caso os arquivos não existam
        let clickLen = Int(sampleRate * 0.025)
        var c1 = [Float](repeating: 0, count: clickLen)
        var c2 = [Float](repeating: 0, count: clickLen)
        let twoPi = 2.0 * Double.pi
        for i in 0..<clickLen {
            let t = Double(i) / sampleRate
            let env = Float(exp(-Double(i) / (sampleRate * 0.005)))
            c1[i] = Float(sin(twoPi * 2500.0 * t)) * env * 0.95
            c2[i] = Float(sin(twoPi * 1600.0 * t)) * env * 0.85
        }
        let result = (downbeat: c1, beat: c2)
        clickCache[sampleRate] = result
        return result
    }
    
    // MARK: - Geração de Cues Procedurais
    
    func generateMetronomeCues(durationSec: Double = 600.0, bpm: Double = 120.0, timeSignature: String = "4/4") -> [CueSection] {
        let cleanBpm = max(30.0, min(300.0, bpm))
        let parts = timeSignature.split(separator: "/")
        let num = parts.count > 0 ? (Int(parts[0]) ?? 4) : 4
        let den = parts.count > 1 ? (Int(parts[1]) ?? 4) : 4
        let beatsPerBar = Double(num) * (4.0 / Double(den))
        let barSec = (60.0 / cleanBpm) * beatsPerBar
        let nBars = max(4, Int(durationSec / barSec))
        
        var cuesList: [CueSection] = []
        let countInBars = 2
        let countInDuration = Double(countInBars) * barSec
        
        cuesList.append(CueSection(
            id: "cue_0",
            name: "Count-In",
            time: 0.0,
            bar: 1,
            color: "#64748b",
            waveform: [Double](repeating: 0.1, count: 64)
        ))
        
        cuesList.append(CueSection(
            id: "cue_1",
            name: "Intro",
            time: countInDuration,
            bar: Double(countInBars + 1),
            color: sectionColors[0],
            waveform: [Double](repeating: 0.2, count: 64)
        ))
        
        var currentBar = countInBars + 1 + 8
        var sectionNum = 1
        var colorIdx = 1
        
        while currentBar <= nBars {
            let sTime = Double(currentBar - 1) * barSec
            cuesList.append(CueSection(
                id: "cue_\(sectionNum + 1)",
                name: "Section \(sectionNum)",
                time: sTime,
                bar: Double(currentBar),
                color: sectionColors[colorIdx % sectionColors.count],
                waveform: [Double](repeating: 0.2, count: 64)
            ))
            currentBar += 8
            sectionNum += 1
            colorIdx += 1
        }
        return cuesList
    }
    
    // MARK: - Geração de Forma de Onda Rítmica Procedural (7200 picos)
    
    func generateMetronomeWaveform(
        durationSec: Double = 600.0,
        bpm: Double = 120.0,
        timeSignature: String = "4/4",
        subdivision: String = "1/4",
        subdivide: Bool = false
    ) -> [Double] {
        let cleanBpm = max(30.0, min(300.0, bpm))
        let parts = timeSignature.split(separator: "/")
        let num = parts.count > 0 ? (Int(parts[0]) ?? 4) : 4
        let den = parts.count > 1 ? (Int(parts[1]) ?? 4) : 4
        let beatsPerBar = Double(num) * (4.0 / Double(den))
        let beatSec = 60.0 / cleanBpm
        let barSec = beatSec * beatsPerBar
        
        var subPerBeat = 1
        if subdivide {
            if subdivision == "1/8" { subPerBeat = 2 }
            else if subdivision == "1/16" { subPerBeat = 4 }
            else if subdivision == "1/8T" || subdivision == "1/12" { subPerBeat = 3 }
        }
        let subIntervalSec = beatSec / Double(subPerBeat)
        
        let totalPoints = 7200
        var wf = [Double](repeating: 0.04, count: totalPoints)
        let secPerPoint = durationSec / Double(totalPoints)
        guard secPerPoint > 0 && barSec > 0 else { return wf }
        
        for i in 0..<totalPoints {
            let t = Double(i) * secPerPoint
            let timeInBar = t.truncatingRemainder(dividingBy: barSec)
            let beatInBar = Int(timeInBar / beatSec)
            let timeInBeat = timeInBar.truncatingRemainder(dividingBy: beatSec)
            
            if timeInBeat < secPerPoint * 1.5 {
                if beatInBar == 0 {
                    wf[i] = 0.85
                } else {
                    wf[i] = 0.50
                }
            } else if subPerBeat > 1 {
                let subInBeat = Int(timeInBeat / subIntervalSec)
                let timeInSub = timeInBeat.truncatingRemainder(dividingBy: subIntervalSec)
                if subInBeat > 0 && timeInSub < secPerPoint * 1.5 {
                    wf[i] = 0.25
                }
            }
        }
        return wf
    }
    
    // MARK: - Criação Procedural de Metrônomo (Zero Disco)
    
    func generateMetronome(
        id: String? = nil,
        name: String = "Click",
        bpm: Double = 120.0,
        timeSignature: String = "4/4",
        subdivision: String = "1/4",
        subdivide: Bool = false,
        durationSec: Double = 600.0
    ) throws -> SongItem {
        let cleanBpm = max(30.0, min(300.0, bpm))
        
        // 1. Título de exibição padronizado
        var baseName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty {
            baseName = "Click \(timeSignature) (\(Int(cleanBpm)) BPM)"
        } else if !baseName.lowercased().contains("bpm") {
            baseName = "\(baseName) (\(Int(cleanBpm)) BPM)"
        }
        let displayTitle = resolveSongDisplayName(name: baseName, timeSignature: timeSignature, isMetronome: true)
        let safeTs = timeSignature.replacingOccurrences(of: "/", with: "_")
        let idString = id ?? "metro_\(safeTs)_\(Int(cleanBpm))"
        let virtualPath = "virtual://metronome/\(safeTs)/\(cleanBpm)"
        let virtualFilename = "\(displayTitle).virtual"
        
        // 2. Cues estruturados em memória (Count-In + Intro + Seções de 8 compassos)
        let cuesList = generateMetronomeCues(durationSec: durationSec, bpm: cleanBpm, timeSignature: timeSignature)
        
        // 3. Forma de onda rítmica procedural (7200 pontos de alta resolução)
        let wf = generateMetronomeWaveform(
            durationSec: durationSec,
            bpm: cleanBpm,
            timeSignature: timeSignature,
            subdivision: subdivision,
            subdivide: subdivide
        )
        
        let item = SongItem(
            id: idString,
            name: displayTitle,
            filename: virtualFilename,
            path: virtualPath,
            bpm: cleanBpm,
            time_signature: timeSignature,
            default_key: "D",
            full_waveform: wf,
            has_cover: false,
            search_query: displayTitle,
            total_duration: durationSec,
            cues: cuesList,
            is_metronome: true,
            subdivide: subdivide,
            subdivision: subdivision
        )
        
        // 4. Salva no SQLite local para resiliência sem poluir o disco com arquivos de áudio
        NativeDatabase.shared.saveSong(item: item)
        NativeSongLibrary.shared.cacheSong(item)
        
        return item
    }
    
    func updateMetronome(
        existingItem: SongItem,
        name: String,
        bpm: Double,
        timeSignature: String,
        subdivision: String = "1/4",
        subdivide: Bool = false
    ) throws -> SongItem {
        let song = try generateMetronome(
            id: existingItem.id,
            name: name,
            bpm: bpm,
            timeSignature: timeSignature,
            subdivision: subdivision,
            subdivide: subdivide
        )
        NativeDatabase.shared.saveSong(item: song)
        NativeSongLibrary.shared.cacheSong(song)
        return song
    }
}
