import Foundation
import AVFoundation

/// Gerador Nativo em Swift de Metrônomos e Click Tracks.
/// Produz faixas estéreo de ~10 minutos:
/// - Canal L (In-Ear): Click rítmico cristalino de estúdio com acentuação no tempo 1 e subdivisões
/// - Canal R (PA / VS): Silêncio absoluto
final class NativeMetronomeGenerator {
    static let shared = NativeMetronomeGenerator()
    
    private let sectionColors = [
        "#38bdf8", "#3b82f6", "#8b5cf6", "#ec4899",
        "#10b981", "#f59e0b", "#06b6d4", "#a855f7"
    ]
    
    private var clickCache: [Double: ([Float], [Float])] = [:]
    
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
    
    private func getClickSamples(sampleRate: Double = 44100.0) -> ([Float], [Float]) {
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
            clickCache[sampleRate] = (m1, m2)
            return (m1, m2)
        }
        
        // Fallback sintetizado caso os arquivos não existam
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
        clickCache[sampleRate] = (c1, c2)
        return (c1, c2)
    }
    
    func generateMetronome(
        name: String = "Click",
        bpm: Double = 120.0,
        timeSignature: String = "4/4",
        subdivision: String = "1/4",
        subdivide: Bool = false,
        durationSec: Double = 600.0
    ) throws -> SongItem {
        let cleanBpm = max(30.0, min(300.0, bpm))
        let parts = timeSignature.split(separator: "/")
        let num = parts.count > 0 ? (Int(parts[0]) ?? 4) : 4
        _ = parts.count > 1 ? (Int(parts[1]) ?? 4) : 4
        
        // 1. Título e nome de arquivo seguro para disco
        var baseName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseName.isEmpty {
            baseName = "Click \(timeSignature) (\(Int(cleanBpm)) BPM)"
        } else if !baseName.lowercased().contains("bpm") {
            baseName = "\(baseName) (\(Int(cleanBpm)) BPM)"
        }
        let displayTitle = resolveSongDisplayName(name: baseName, timeSignature: timeSignature, isMetronome: true)
        let safeTs = timeSignature.replacingOccurrences(of: "/", with: "_")
        let filenameBase = displayTitle.replacingOccurrences(of: timeSignature, with: safeTs)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(filenameBase).wav"
        
        let dir = NativeSongLibrary.shared.getTracksDirectory()
        let fileUrl = dir.appendingPathComponent(filename)
        
        // 2. Parâmetros temporais
        let sr: Double = 44100.0
        let beatSec = 60.0 / cleanBpm
        let barSec = Double(num) * beatSec
        let nBars = max(4, Int(durationSec / barSec))
        let totalSamples = Int(Double(nBars) * barSec * sr)
        
        // 3. Carrega os samples originais do projeto (Click Track-1.wav e Click Track-2.wav)
        let (clickTrack1, clickTrack2) = getClickSamples(sampleRate: sr)
        
        // 4. Monta buffer do Canal L (Click com alternância profissional de samples)
        var leftChannel = [Float](repeating: 0, count: totalSamples)
        
        // Fator de subdivisão
        var subPerBeat = 1
        if subdivide {
            if subdivision == "1/8" { subPerBeat = 2 }
            else if subdivision == "1/16" { subPerBeat = 4 }
            else if subdivision == "1/8T" || subdivision == "1/12" { subPerBeat = 3 }
        }
        let subIntervalSec = beatSec / Double(subPerBeat)
        
        var totalSteps = 0
        for bar in 0..<nBars {
            let barStartSec = Double(bar) * barSec
            for beat in 0..<num {
                let beatStartSec = barStartSec + Double(beat) * beatSec
                for sub in 0..<subPerBeat {
                    let clickTime = beatStartSec + Double(sub) * subIntervalSec
                    let sampleIdx = Int(clickTime * sr)
                    
                    // Alternância contínua entre Click Track-1 e Click Track-2 idêntica ao app original
                    let sample = (totalSteps % 2 == 0) ? clickTrack1 : clickTrack2
                    let avail = min(sample.count, totalSamples - sampleIdx)
                    if avail > 0 && sampleIdx >= 0 {
                        for k in 0..<avail {
                            leftChannel[sampleIdx + k] = sample[k]
                        }
                    }
                    totalSteps += 1
                }
            }
        }
        
        // 5. Canal R = Silêncio
        let rightChannel = [Float](repeating: 0, count: totalSamples)
        
        // 6. Grava arquivo WAV estéreo usando AVAudioFile
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let audioFile = try AVAudioFile(
            forWriting: fileUrl,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let pcmBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalSamples)) else {
            throw NSError(domain: "Metronome", code: -1)
        }
        pcmBuf.frameLength = AVAudioFrameCount(totalSamples)
        if let chData = pcmBuf.floatChannelData {
            leftChannel.withUnsafeBufferPointer { src in
                _ = memcpy(chData[0], src.baseAddress!, totalSamples * MemoryLayout<Float>.size)
            }
            rightChannel.withUnsafeBufferPointer { src in
                _ = memcpy(chData[1], src.baseAddress!, totalSamples * MemoryLayout<Float>.size)
            }
        }
        try audioFile.write(from: pcmBuf)
        
        // 7. Estruturação dos Cues (Contagem + Blocos de 8 compassos)
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
        
        // 8. Waveform contínuo
        let wf = [Double](repeating: 0.35, count: 1200)
        
        // 9. Persiste .cues.json
        NativeSongLibrary.shared.saveCues(
            songId: filename,
            cues: cuesList,
            bpm: cleanBpm,
            timeSignature: timeSignature,
            fullWaveform: wf
        )
        
        // Atualiza nome de exibição no json
        let cuesPath = fileUrl.path + ".cues.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cuesPath)),
           var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json["name"] = displayTitle
            json["is_metronome"] = true
            json["subdivide"] = subdivide
            json["subdivision"] = subdivision
            json["total_duration"] = Double(totalSamples) / sr
            if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                try? updatedData.write(to: URL(fileURLWithPath: cuesPath))
            }
        }
        
        let item = SongItem(
            id: filename,
            name: displayTitle,
            filename: filename,
            path: fileUrl.path,
            bpm: cleanBpm,
            time_signature: timeSignature,
            default_key: "D",
            full_waveform: wf,
            has_cover: false,
            search_query: displayTitle,
            total_duration: Double(totalSamples) / sr,
            cues: cuesList,
            is_metronome: true,
            subdivide: subdivide,
            subdivision: subdivision
        )
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
            name: name,
            bpm: bpm,
            timeSignature: timeSignature,
            subdivision: subdivision,
            subdivide: subdivide
        )
        return song
    }
}
