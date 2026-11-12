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
        
        // 3. Síntese do Click Analógico de Estúdio
        // Downbeat (Tempo 1): 2500 Hz (frequência alta brilhante)
        // Beats normais: 1600 Hz
        // Subdivisão: 1200 Hz
        let clickLen = Int(sr * 0.025) // 25ms
        var clickDownbeat = [Float](repeating: 0, count: clickLen)
        var clickNormal = [Float](repeating: 0, count: clickLen)
        var clickSub = [Float](repeating: 0, count: clickLen)
        
        let twoPi = 2.0 * Double.pi
        for i in 0..<clickLen {
            let t = Double(i) / sr
            let env = Float(exp(-Double(i) / (sr * 0.005))) // Decaimento rápido percussivo
            clickDownbeat[i] = Float(sin(twoPi * 2500.0 * t)) * env * 0.95
            clickNormal[i] = Float(sin(twoPi * 1600.0 * t)) * env * 0.85
            clickSub[i] = Float(sin(twoPi * 1200.0 * t)) * env * 0.55
        }
        
        // 4. Monta buffer do Canal L (Click)
        var leftChannel = [Float](repeating: 0, count: totalSamples)
        
        // Fator de subdivisão
        var subPerBeat = 1
        if subdivide {
            if subdivision == "1/8" { subPerBeat = 2 }
            else if subdivision == "1/16" { subPerBeat = 4 }
            else if subdivision == "1/8T" || subdivision == "1/12" { subPerBeat = 3 }
        }
        let subIntervalSec = beatSec / Double(subPerBeat)
        
        for bar in 0..<nBars {
            let barStartSec = Double(bar) * barSec
            for beat in 0..<num {
                let beatStartSec = barStartSec + Double(beat) * beatSec
                for sub in 0..<subPerBeat {
                    let clickTime = beatStartSec + Double(sub) * subIntervalSec
                    let sampleIdx = Int(clickTime * sr)
                    
                    let sampleToUse: [Float]
                    if beat == 0 && sub == 0 {
                        sampleToUse = clickDownbeat
                    } else if sub == 0 {
                        sampleToUse = clickNormal
                    } else {
                        sampleToUse = clickSub
                    }
                    
                    for k in 0..<clickLen {
                        let target = sampleIdx + k
                        if target < totalSamples {
                            leftChannel[target] = sampleToUse[k]
                        }
                    }
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
