import Foundation
import Accelerate
import AVFoundation
import AppKit

/// Biblioteca de Canções 100% Nativa em Swift.
/// Varre o diretório de VS, lê e persiste os metadados (.cues.json), calcula formas de onda contínuas
/// ultra-rápidas usando Accelerate (vDSP) e gerencia capas de álbuns.
final class NativeSongLibrary {
    static let shared = NativeSongLibrary()
    
    private let defaultDir = "/Users/samysglauber/Documents/Vs"
    private var songsCache: [String: SongItem] = [:]
    private let lock = NSLock()
    
    // MARK: - Diretório de Músicas
    
    func getTracksDirectory() -> URL {
        if let saved = UserDefaults.standard.string(forKey: "saved_tracks_dir"),
           FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        return URL(fileURLWithPath: defaultDir)
    }
    
    func setTracksDirectory(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        UserDefaults.standard.set(path, forKey: "saved_tracks_dir")
        lock.lock()
        songsCache.removeAll()
        lock.unlock()
        return true
    }
    
    // MARK: - Varredura e Indexação
    
    func getAllSongs() -> [SongItem] {
        let dir = getTracksDirectory()
        // Executa migração única automática dos arquivos .cues.json para o banco SQLite e limpa os arquivos soltos
        _ = NativeDatabase.shared.migrateLegacyFilesIfNeeded(tracksDirectory: dir, deleteLegacy: true)
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        
        let supportedExts = [".wav", ".mp3", ".m4a", ".aif", ".aiff"]
        var result: [SongItem] = []
        
        for file in files where !file.hasPrefix(".") {
            let lower = file.lowercased()
            if supportedExts.contains(where: { lower.hasSuffix($0) }) {
                if let song = getSong(id: file) {
                    result.append(song)
                }
            }
        }
        
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }
    
    func getSong(id: String) -> SongItem? {
        lock.lock()
        if let cached = songsCache[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let dir = getTracksDirectory()
        return indexFile(id, directory: dir)
    }
    
    func findSong(byId id: String) -> SongItem? {
        return getSong(id: id)
    }
    
    func loadSetlistSongs(ids: [String]) -> [SongItem] {
        var result: [SongItem] = []
        for sid in ids {
            if let s = getSong(id: sid) {
                result.append(s)
            }
        }
        return result
    }
    
    private func indexFile(_ entry: String, directory: URL) -> SongItem? {
        lock.lock()
        if let cached = songsCache[entry] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        
        // 1. Tenta carregar diretamente do banco de dados SQLite nativo
        if let fromDb = NativeDatabase.shared.getSong(id: entry) {
            lock.lock()
            songsCache[entry] = fromDb
            lock.unlock()
            return fromDb
        }
        
        let filePath = directory.appendingPathComponent(entry).path
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }
        
        var cleanName = (entry as NSString).deletingPathExtension
        var bpm: Double = 120.0
        var timeSignature = "4/4"
        var defaultKey = "D"
        var totalDuration: Double? = nil
        var cues: [CueSection]? = nil
        var fullWaveform: [Double]? = nil
        var hasCover = hasCover(for: entry)
        var isMetronome = false
        var subdivide = false
        var subdivision = "1/4"
        
        // 1. Extração de BPM e Tonalidade do nome do arquivo
        if let bpmMatch = extractBpmFromFilename(entry) {
            bpm = bpmMatch
        }
        if let keyMatch = extractKeyFromFilename(entry) {
            defaultKey = keyMatch
        }
        if let tsMatch = extractTimeSignatureFromFilename(entry) {
            timeSignature = tsMatch
        }
        
        // 2. Lê a duração diretamente do cabeçalho do arquivo de áudio
        if let af = try? AVAudioFile(forReading: URL(fileURLWithPath: filePath)) {
            let sr = af.processingFormat.sampleRate
            if sr > 0 {
                totalDuration = Double(af.length) / sr
            }
        }
        
        // 3. Seções padrão imediatas
        if let dur = totalDuration, dur > 0 {
            cues = generateDefaultCues(totalDuration: dur, bpm: bpm, timeSignature: timeSignature)
        }
        
        fullWaveform = [Double](repeating: 0.15, count: 400)
        cleanName = resolveSongDisplayName(name: cleanName, timeSignature: timeSignature, isMetronome: isMetronome)
        
        let item = SongItem(
            id: entry,
            name: cleanName,
            filename: entry,
            path: filePath,
            bpm: bpm,
            time_signature: timeSignature,
            default_key: defaultKey,
            full_waveform: fullWaveform,
            has_cover: hasCover,
            cover_url: hasCover ? "/covers/\(entry)" : nil,
            search_query: cleanSongTitleForSearch(cleanName),
            total_duration: totalDuration,
            cues: cues,
            is_metronome: isMetronome,
            subdivide: subdivide,
            subdivision: subdivision
        )
        
        // Salva no SQLite
        NativeDatabase.shared.saveSong(item: item)
        
        lock.lock()
        songsCache[entry] = item
        lock.unlock()
        return item
    }
    
    // MARK: - Geração de Cues Padrão
    
    func generateDefaultCues(totalDuration: Double, bpm: Double, timeSignature: String) -> [CueSection] {
        let parts = timeSignature.split(separator: "/")
        let num = Double(parts.first ?? "4") ?? 4.0
        let secPerBeat = (bpm > 30 ? 60.0 / bpm : 0.5)
        let secPerBar = secPerBeat * num
        let bars = Int(totalDuration / max(0.5, secPerBar))
        
        let template: [(name: String, bar: Int, color: String)] = [
            ("Count-In", 1, "#64748b"),
            ("Intro", 3, "#38bdf8"),
            ("Verse 1", max(7, Int(Double(bars) * 0.12)), "#a855f7"),
            ("Verse 2", max(13, Int(Double(bars) * 0.25)), "#a855f7"),
            ("Chorus", max(21, Int(Double(bars) * 0.40)), "#ef4444"),
            ("Instrumental", max(29, Int(Double(bars) * 0.55)), "#10b981"),
            ("Bridge", max(37, Int(Double(bars) * 0.70)), "#f97316"),
            ("Chorus", max(45, Int(Double(bars) * 0.82)), "#ef4444"),
            ("Ending", max(51, Int(Double(bars) * 0.92)), "#64748b")
        ]
        
        var result: [CueSection] = []
        for (i, sec) in template.enumerated() {
            let t = round(Double(sec.bar - 1) * secPerBar * 100.0) / 100.0
            if t < totalDuration - 5.0 {
                result.append(CueSection(
                    id: "cue_\(i)",
                    name: sec.name,
                    time: t,
                    bar: Double(sec.bar),
                    color: sec.color,
                    waveform: nil
                ))
            }
        }
        if result.isEmpty {
            result.append(CueSection(id: "cue_0", name: "Intro", time: 0.0, bar: 1.0, color: "#38bdf8", waveform: nil))
        }
        return result
    }
    
    // MARK: - Salvar Cues e Formas de Onda no Banco de Dados SQLite
    
    func saveCues(
        songId: String,
        cues: [CueSection],
        bpm: Double? = nil,
        timeSignature: String? = nil,
        fullWaveform: [Double]? = nil
    ) {
        NativeDatabase.shared.saveCues(
            songId: songId,
            cues: cues,
            bpm: bpm,
            timeSignature: timeSignature,
            fullWaveform: fullWaveform
        )
        
        // Atualiza cache em memória
        lock.lock()
        if var cached = songsCache[songId] {
            cached.cues = cues
            if let b = bpm { cached.bpm = b }
            if let ts = timeSignature { cached.time_signature = ts }
            if let wf = fullWaveform { cached.full_waveform = wf }
            songsCache[songId] = cached
        }
        lock.unlock()
    }
    
    // MARK: - Cálculo de Waveform Rápido com Accelerate (vDSP)
    
    func computeWaveformPeaks(from audioRight: [Float], targetPeaks: Int = 1200) -> [Double] {
        guard !audioRight.isEmpty else {
            return [Double](repeating: 0.04, count: targetPeaks)
        }
        
        let total = audioRight.count
        let step = max(1, total / targetPeaks)
        var rawPeaks = [Float](repeating: 0.04, count: targetPeaks)
        
        // 1. Encontra o pico global com vDSP
        var globalMax: Float = 0.0
        audioRight.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &globalMax, vDSP_Length(total))
        }
        if globalMax < 0.01 { globalMax = 1.0 }
        
        // 2. Extrai picos locais por segmento com vDSP
        for i in 0..<targetPeaks {
            let start = i * step
            let end = min(total, start + step)
            let count = end - start
            if count > 0 {
                var maxVal: Float = 0.0
                audioRight.withUnsafeBufferPointer { ptr in
                    vDSP_maxmgv(ptr.baseAddress! + start, 1, &maxVal, vDSP_Length(count))
                }
                rawPeaks[i] = maxVal
            }
        }
        
        // 3. Normalização perceptual (estilo DAW / MultiTracks) com curva suave tanh para dar corpo visual
        var peaks = [Double](repeating: 0.04, count: targetPeaks)
        let invGlobal = 1.0 / (Double(globalMax) * 1.05)
        let tanhDenom = tanh(1.5)
        
        for i in 0..<targetPeaks {
            let ratio = Double(rawPeaks[i]) * invGlobal
            let scaled = (tanh(ratio * 1.5) / tanhDenom) * 0.95
            peaks[i] = max(0.04, min(0.96, scaled))
        }
        
        return peaks
    }
    
    // MARK: - Busca de Capas de Álbuns (Apple iTunes Search API)
    
    func searchCovers(query: String, completion: @escaping ([CoverSearchResult]) -> Void) {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=15") else {
            completion([])
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            var items: [CoverSearchResult] = []
            for r in results {
                let trackName = r["trackName"] as? String ?? ""
                let artistName = r["artistName"] as? String ?? ""
                let collectionName = r["collectionName"] as? String ?? ""
                let artUrl = r["artworkUrl100"] as? String ?? ""
                let year = (r["releaseDate"] as? String ?? "").prefix(4)
                
                // Transforma resolução da capa para alta definição 600x600
                let art600 = artUrl.replacingOccurrences(of: "100x100bb.jpg", with: "600x600bb.jpg")
                let res = CoverSearchResult(
                    id: UUID().uuidString,
                    track_name: trackName,
                    artist_name: artistName,
                    collection_name: collectionName,
                    artwork_url: art600,
                    artwork_url_small: artUrl,
                    year: String(year)
                )
                items.append(res)
            }
            DispatchQueue.main.async { completion(items) }
        }.resume()
    }
    
    // MARK: - Gerenciamento e Armazenamento de Capas (Application Support/VSControl/covers)
    
    func getCoverPath(for songId: String) -> String {
        return NativeDatabase.shared.getCoverFilePath(for: songId)
    }
    
    func hasCover(for songId: String) -> Bool {
        let p = getCoverPath(for: songId)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
           let size = attrs[.size] as? UInt64, size > 0 {
            return true
        }
        return false
    }
    
    func saveAndOptimizeCover(data: Data, destinationPath: String) -> Bool {
        guard let image = NSImage(data: data) else { return false }
        let targetSize = NSSize(width: 300, height: 300)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 300,
            pixelsHigh: 300,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }
        
        rep.size = targetSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        
        if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            let url = URL(fileURLWithPath: destinationPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try jpegData.write(to: url)
                return true
            } catch {
                print("[NativeSongLibrary] Error writing cover: \(error)")
                return false
            }
        }
        return false
    }
    
    func updateCuesJsonCover(songId: String, hasCover: Bool) {
        NativeDatabase.shared.setCoverStatus(songId: songId, hasCover: hasCover, noCover: !hasCover)
    }
    
    func saveCoverFromUrl(songId: String, artworkUrl: String, completion: @escaping (Bool) -> Void) {
        let highresUrl = artworkUrl
            .replacingOccurrences(of: "/100x100bb.jpg", with: "/600x600bb.jpg")
            .replacingOccurrences(of: "/60x60bb.jpg", with: "/600x600bb.jpg")
        
        guard let url = URL(string: highresUrl) else {
            completion(false)
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self, let data = data, error == nil else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            let dstPath = self.getCoverPath(for: songId)
            let success = self.saveAndOptimizeCover(data: data, destinationPath: dstPath)
            if success {
                self.updateCuesJsonCover(songId: songId, hasCover: true)
                self.lock.lock()
                if var cached = self.songsCache[songId] {
                    cached.has_cover = true
                    cached.cover_url = "/covers/\(songId)"
                    self.songsCache[songId] = cached
                }
                self.lock.unlock()
            }
            DispatchQueue.main.async { completion(success) }
        }.resume()
    }
    
    func saveCoverFromFile(songId: String, filePath: String, completion: @escaping (Bool) -> Void) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            completion(false)
            return
        }
        let dstPath = getCoverPath(for: songId)
        let success = saveAndOptimizeCover(data: data, destinationPath: dstPath)
        if success {
            updateCuesJsonCover(songId: songId, hasCover: true)
            lock.lock()
            if var cached = songsCache[songId] {
                cached.has_cover = true
                cached.cover_url = "/covers/\(songId)"
                songsCache[songId] = cached
            }
            lock.unlock()
        }
        DispatchQueue.main.async { completion(success) }
    }
    
    func removeCover(songId: String) {
        let dstPath = getCoverPath(for: songId)
        try? FileManager.default.removeItem(atPath: dstPath)
        updateCuesJsonCover(songId: songId, hasCover: false)
        lock.lock()
        if var cached = songsCache[songId] {
            cached.has_cover = false
            cached.cover_url = nil
            songsCache[songId] = cached
        }
        lock.unlock()
    }
    
    func autoFetchCover(song: SongItem, completion: @escaping (Bool) -> Void) {
        if hasCover(for: song.id) {
            completion(true)
            return
        }
        
        if NativeDatabase.shared.isNoCoverRequested(songId: song.id) {
            completion(false)
            return
        }
        
        let query = cleanSongTitleForSearch(song.search_query ?? song.name)
        guard !query.isEmpty else {
            completion(false)
            return
        }
        
        searchCovers(query: query) { [weak self] results in
            guard let self = self, let first = results.first else {
                completion(false)
                return
            }
            self.saveCoverFromUrl(songId: song.id, artworkUrl: first.artwork_url, completion: completion)
        }
    }
    
    // MARK: - Processamento com IA (Vosk Speech Recognition & Downbeat Detection)
    
    func reprocessWithAI(
        songId: String,
        bpm: Double? = nil,
        timeSignature: String? = nil,
        completion: @escaping (SongItem?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let tracksDir = self.getTracksDirectory().path
            
            let possibleScriptPaths = [
                "/Users/samysglauber/Documents/AbletonTracks/scripts/detect_cues.py",
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts/detect_cues.py").path,
                Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("scripts/detect_cues.py").path
            ]
            let scriptPath = possibleScriptPaths.first { FileManager.default.fileExists(atPath: $0) } ?? possibleScriptPaths[0]
            
            let possiblePythons = [
                "/Library/Frameworks/Python.framework/Versions/3.15/bin/python3",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3"
            ]
            let pythonBin = possiblePythons.first { FileManager.default.fileExists(atPath: $0) } ?? "/usr/bin/python3"
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonBin)
            
            var args = [scriptPath, songId]
            if let b = bpm {
                args.append(String(b))
            } else {
                args.append("null")
            }
            if let ts = timeSignature {
                args.append(ts)
            } else {
                args.append("null")
            }
            args.append(tracksDir)
            
            process.arguments = args
            
            var env = ProcessInfo.processInfo.environment
            let customPath = "/Library/Frameworks/Python.framework/Versions/3.15/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = customPath + ":" + (env["PATH"] ?? "")
            env["PYTHONPATH"] = URL(fileURLWithPath: scriptPath).deletingLastPathComponent().deletingLastPathComponent().path
            process.environment = env
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                   let status = json["status"] as? String, status == "success" {
                    self.lock.lock()
                    self.songsCache.removeValue(forKey: songId)
                    self.lock.unlock()
                    
                    let reindexed = self.getSong(id: songId)
                    DispatchQueue.main.async {
                        completion(reindexed)
                    }
                    return
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    print("[NativeSongLibrary] AI reprocess output: \(outStr), err: \(errStr)")
                }
            } catch {
                print("[NativeSongLibrary] Error executing AI reprocess: \(error)")
            }
            
            DispatchQueue.main.async {
                completion(nil)
            }
        }
    }
}

// MARK: - Utilitários de Regex

func extractBpmFromFilename(_ name: String) -> Double? {
    if let match = name.range(of: #"(?i)\((\d+(?:\.\d+)?)\s*bpm\)"#, options: .regularExpression) {
        let sub = String(name[match])
        let digits = sub.filter { "0123456789.".contains($0) }
        return Double(digits)
    }
    return nil
}

func extractKeyFromFilename(_ name: String) -> String? {
    if let match = name.range(of: #"\(([A-Ga-g][#b]?m?)\)"#, options: .regularExpression) {
        let sub = String(name[match])
        return sub.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "").uppercased()
    }
    return nil
}

func extractTimeSignatureFromFilename(_ name: String) -> String? {
    if let match = name.range(of: #"\b([1-9]|1[0-6])_(2|4|8|16)\b"#, options: .regularExpression) {
        let sub = String(name[match])
        return sub.replacingOccurrences(of: "_", with: "/")
    }
    return nil
}
