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
    
    var onAutoCuesReady: ((String, [CueSection], String?, Double?) -> Void)?
    var onAutoAnalysisStarted: ((String) -> Void)?
    var onAutoAnalysisFailed: ((String) -> Void)?
    private var analyzingSongIds: Set<String> = []
    
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
        let hasCover = hasCover(for: entry)
        let isMetronome = false
        let subdivide = false
        let subdivision = "1/4"
        
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
            subdivision: subdivision,
            auto_analysis: "pending"
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
        let den = parts.count > 1 ? (Double(parts[1]) ?? 4.0) : 4.0
        let secPerBeat = (bpm > 30 ? 60.0 / bpm : 0.5)
        let secPerBar = secPerBeat * (num * (4.0 / den))
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
        fullWaveform: [Double]? = nil,
        autoAnalysis: String? = nil
    ) {
        NativeDatabase.shared.saveCues(
            songId: songId,
            cues: cues,
            bpm: bpm,
            timeSignature: timeSignature,
            fullWaveform: fullWaveform,
            autoAnalysis: autoAnalysis
        )
        
        // Atualiza ou cria o arquivo .cues.json para persistência e compatibilidade
        let dir = getTracksDirectory()
        let cuesPath = dir.appendingPathComponent(songId).path + ".cues.json"
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cuesPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = existing
        }
        
        payload["cues"] = cues.map { cue in
            [
                "id": cue.id,
                "name": cue.name,
                "time": cue.time,
                "bar": cue.bar,
                "color": cue.color,
                "waveform": cue.waveform ?? []
            ]
        }
        if let b = bpm { payload["bpm"] = b }
        if let ts = timeSignature { payload["time_signature"] = ts }
        if let wf = fullWaveform { payload["full_waveform"] = wf }
        if let aa = autoAnalysis { payload["auto_analysis"] = aa }
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) {
            try? jsonData.write(to: URL(fileURLWithPath: cuesPath))
        }
        
        // Atualiza cache em memória
        lock.lock()
        if var cached = songsCache[songId] {
            cached.cues = cues
            if let b = bpm { cached.bpm = b }
            if let ts = timeSignature { cached.time_signature = ts }
            if let wf = fullWaveform { cached.full_waveform = wf }
            if let aa = autoAnalysis { cached.auto_analysis = aa }
            songsCache[songId] = cached
        }
        lock.unlock()
    }
    
    // MARK: - Verificação e Análise Automática de Cues
    
    func needsAutoCueAnalysis(songId: String) -> Bool {
        if let song = getSong(id: songId) {
            if song.is_metronome == true { return false }
        }
        if songId.hasPrefix("metronome_") { return false }
        
        let dir = getTracksDirectory()
        let cuesPath = dir.appendingPathComponent(songId).path + ".cues.json"
        
        if FileManager.default.fileExists(atPath: cuesPath) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: cuesPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return true
            }
            if let auto = json["auto_analysis"] as? String {
                if auto == "pending" { return true }
                if auto == "done" { return false }
                if auto == "failed" { return false }
            }
            guard let cues = json["cues"] as? [[String: Any]], !cues.isEmpty else {
                return true
            }
            // Se as seções tiverem nomes genéricos como "Section 1, Section 2...", PRECISA de análise nativa!
            let hasGenericNames = cues.contains { cueDict in
                guard let name = cueDict["name"] as? String else { return false }
                return name.hasPrefix("Section ") || name == "Section"
            }
            if hasGenericNames {
                return true
            }
            return false
        }
        
        if let dbSong = NativeDatabase.shared.getSong(id: songId) {
            if dbSong.is_metronome == true { return false }
            if dbSong.auto_analysis == "pending" { return true }
            if dbSong.auto_analysis == "done" { return false }
            if let cues = dbSong.cues, !cues.isEmpty {
                if cues.contains(where: { $0.name.hasPrefix("Section ") || $0.name == "Section" }) {
                    return true
                }
            }
        }
        
        return true
    }
    
    func autoAnalyzeCues(
        songId: String,
        left: [Float],
        right: [Float] = [],
        sampleRate: Double,
        bpm: Double,
        timeSignature: String,
        templateCues: [CueSection]
    ) {
        lock.lock()
        if analyzingSongIds.contains(songId) {
            lock.unlock()
            return
        }
        analyzingSongIds.insert(songId)
        lock.unlock()
        
        DispatchQueue.main.async {
            self.onAutoAnalysisStarted?(songId)
        }
        
        NativeCueDetector.shared.analyze(
            left: left,
            right: right,
            sampleRate: sampleRate,
            bpmHint: bpm,
            timeSignature: timeSignature
        ) { [weak self] result in
            guard let self = self else { return }
            
            self.lock.lock()
            self.analyzingSongIds.remove(songId)
            self.lock.unlock()
            
            guard let res = result else {
                self.saveCues(
                    songId: songId,
                    cues: templateCues,
                    bpm: bpm,
                    timeSignature: timeSignature,
                    autoAnalysis: "failed"
                )
                DispatchQueue.main.async {
                    self.onAutoAnalysisFailed?(songId)
                }
                return
            }
            
            let detectedTs = res.timeSignature
            let fileBpm = extractBpmFromFilename(songId)
            let finalBpm = fileBpm ?? (bpm > 30 && bpm != 120.0 ? bpm : (res.gridBpm > 30 ? round(res.gridBpm * 10) / 10.0 : bpm))
            let currentSavedCues = self.getSong(id: songId)?.cues ?? []
            let isGeneric = currentSavedCues.isEmpty || currentSavedCues.contains(where: { $0.name.hasPrefix("Section ") || $0.name == "Section" }) || self.areCuesEqual(currentSavedCues, templateCues)
            if isGeneric {
                self.saveCues(
                    songId: songId,
                    cues: res.cues,
                    bpm: finalBpm,
                    timeSignature: detectedTs,
                    autoAnalysis: "done"
                )
                DispatchQueue.main.async {
                    self.onAutoCuesReady?(songId, res.cues, detectedTs, finalBpm)
                }
            } else {
                self.saveCues(
                    songId: songId,
                    cues: currentSavedCues,
                    bpm: finalBpm,
                    timeSignature: detectedTs,
                    autoAnalysis: "done"
                )
            }
        }
    }
    
    private func areCuesEqual(_ a: [CueSection], _ b: [CueSection]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count {
            if a[i].name != b[i].name { return false }
            if abs(a[i].time - b[i].time) > 0.001 { return false }
        }
        return true
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
    
    // MARK: - Processamento com IA (Detecção Nativa de Seções 100% Swift)
    
    func reprocessWithAI(
        songId: String,
        bpm: Double? = nil,
        timeSignature: String? = nil,
        completion: @escaping (SongItem?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let song = self.getSong(id: songId) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            let audioUrl = URL(fileURLWithPath: song.path)
            guard FileManager.default.fileExists(atPath: song.path) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            let resolvedBpm = bpm ?? song.bpm ?? 120.0
            let resolvedTs = timeSignature ?? song.time_signature ?? "4/4"
            
            do {
                let (left, right, sr) = try loadAudioFileStereo(url: audioUrl)
                NativeCueDetector.shared.analyze(
                    left: left,
                    right: right,
                    sampleRate: sr,
                    bpmHint: resolvedBpm,
                    timeSignature: resolvedTs
                ) { result in
                    guard let result = result else {
                        DispatchQueue.main.async { completion(nil) }
                        return
                    }
                    
                    let finalTs = result.timeSignature
                    self.saveCues(
                        songId: songId,
                        cues: result.cues,
                        bpm: resolvedBpm,
                        timeSignature: finalTs,
                        autoAnalysis: "done"
                    )
                    
                    self.lock.lock()
                    self.songsCache.removeValue(forKey: songId)
                    self.lock.unlock()
                    
                    let reindexed = self.getSong(id: songId)
                    DispatchQueue.main.async {
                        completion(reindexed)
                    }
                }
            } catch {
                print("[NativeSongLibrary] Error decoding audio for cue detection: \(error)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}

// MARK: - Utilitários de Regex e Parsing de BPM

func parseBpm(_ val: Any?) -> Double? {
    if let d = val as? Double { return d }
    if let i = val as? Int { return Double(i) }
    if let s = val as? String {
        let cleaned = s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }
    return nil
}

func extractBpmFromFilename(_ name: String) -> Double? {
    let patterns = [
        #"(?i)[\(\[]\s*(\d+(?:[\.,]\d+)?)\s*bpm\s*[\)\]]"#,
        #"(?i)\b(\d+(?:[\.,]\d+)?)\s*bpm\b"#
    ]
    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: name.utf16.count)
            if let match = regex.firstMatch(in: name, options: [], range: range),
               match.numberOfRanges > 1,
               let numRange = Range(match.range(at: 1), in: name) {
                let numStr = String(name[numRange]).replacingOccurrences(of: ",", with: ".")
                if let val = Double(numStr), val >= 20.0 && val <= 400.0 {
                    return val
                }
            }
        }
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
