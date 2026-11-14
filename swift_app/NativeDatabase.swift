import Foundation
import SQLite3

/// Gerenciador de Banco de Dados Local 100% Nativo em Swift usando Apple SQLite (libsqlite3).
/// Armazena todos os metadados, seções (cues), formas de onda e estado de capas em:
/// ~/Library/Application Support/VSControl/library.db
final class NativeDatabase {
    static let shared = NativeDatabase()
    
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let dbPath: String
    private let coversDirectory: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vsDir = appSupport.appendingPathComponent("VSControl")
        try? FileManager.default.createDirectory(at: vsDir, withIntermediateDirectories: true)
        
        self.dbPath = vsDir.appendingPathComponent("library.db").path
        self.coversDirectory = vsDir.appendingPathComponent("covers")
        try? FileManager.default.createDirectory(at: self.coversDirectory, withIntermediateDirectories: true)
        
        openDatabase()
        createTables()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    func getCoversDirectory() -> URL {
        return coversDirectory
    }
    
    func getCoverFilePath(for songId: String) -> String {
        return coversDirectory.appendingPathComponent("\(songId).jpg").path
    }
    
    // MARK: - Abertura e Configuração
    
    private func openDatabase() {
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            // WAL mode para alta performance e concorrência sem bloqueio
            execute(sql: "PRAGMA journal_mode = WAL;")
            execute(sql: "PRAGMA synchronous = NORMAL;")
            execute(sql: "PRAGMA foreign_keys = ON;")
            execute(sql: "ALTER TABLE songs ADD COLUMN auto_analysis TEXT;")
            execute(sql: "UPDATE songs SET auto_analysis = 'done' WHERE auto_analysis IS NULL AND id IN (SELECT DISTINCT song_id FROM cues);")
        } else {
            print("[NativeDatabase] Failed to open SQLite database at \(dbPath)")
        }
    }
    
    private func execute(sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("[NativeDatabase] SQLite error executing: \(sql) -> \(String(cString: err))")
                sqlite3_free(errMsg)
            }
        }
    }
    
    // MARK: - Criação das Tabelas
    
    private func createTables() {
        let sqlSongs = """
        CREATE TABLE IF NOT EXISTS songs (
            id TEXT PRIMARY KEY,
            name TEXT,
            filename TEXT,
            path TEXT,
            bpm REAL,
            time_signature TEXT,
            default_key TEXT,
            total_duration REAL,
            has_cover INTEGER DEFAULT 0,
            cover_url TEXT,
            search_query TEXT,
            is_metronome INTEGER DEFAULT 0,
            subdivide INTEGER DEFAULT 0,
            subdivision TEXT DEFAULT '1/4',
            no_cover INTEGER DEFAULT 0,
            user_edited INTEGER DEFAULT 0,
            auto_analysis TEXT,
            updated_at REAL
        );
        """
        execute(sql: sqlSongs)
        
        let sqlCues = """
        CREATE TABLE IF NOT EXISTS cues (
            song_id TEXT,
            cue_id TEXT,
            cue_order INTEGER,
            name TEXT,
            time REAL,
            bar REAL,
            color TEXT,
            waveform_json TEXT,
            PRIMARY KEY (song_id, cue_id)
        );
        CREATE INDEX IF NOT EXISTS idx_cues_song_id ON cues(song_id, cue_order);
        """
        execute(sql: sqlCues)
        
        let sqlWaveforms = """
        CREATE TABLE IF NOT EXISTS waveforms (
            song_id TEXT PRIMARY KEY,
            peaks_json TEXT,
            updated_at REAL
        );
        """
        execute(sql: sqlWaveforms)
    }
    
    // MARK: - Leitura de Músicas
    
    func getSong(id: String) -> SongItem? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let db = db else { return nil }
        let query = """
        SELECT id, name, filename, path, bpm, time_signature, default_key, total_duration,
               has_cover, cover_url, search_query, is_metronome, subdivide, subdivision, auto_analysis
        FROM songs WHERE id = ? LIMIT 1;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            let sId = String(cString: sqlite3_column_text(stmt, 0))
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? sId
            let filename = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? sId
            let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let bpm = sqlite3_column_double(stmt, 4)
            let timeSig = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "4/4"
            let defaultKey = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "D"
            let duration = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? sqlite3_column_double(stmt, 7) : nil
            let hasCover = sqlite3_column_int(stmt, 8) != 0
            let coverUrl = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
            let searchQuery = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            let isMetronome = sqlite3_column_int(stmt, 11) != 0
            let subdivide = sqlite3_column_int(stmt, 12) != 0
            let subdivision = sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? "1/4"
            let autoAnalysis = sqlite3_column_text(stmt, 14).map { String(cString: $0) }
            
            let cues = getCuesInternal(songId: sId)
            let waveform = getWaveformInternal(songId: sId)
            
            return SongItem(
                id: sId,
                name: name,
                filename: filename,
                path: path,
                bpm: bpm,
                time_signature: timeSig,
                default_key: defaultKey,
                full_waveform: waveform,
                has_cover: hasCover,
                cover_url: coverUrl,
                search_query: searchQuery,
                total_duration: duration,
                cues: cues,
                is_metronome: isMetronome,
                subdivide: subdivide,
                subdivision: subdivision,
                auto_analysis: autoAnalysis
            )
        }
        
        return nil
    }
    
    func isNoCoverRequested(songId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        guard let db = db else { return false }
        let query = "SELECT no_cover FROM songs WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (songId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0) != 0
        }
        return false
    }
    
    // MARK: - Salvar ou Atualizar Música
    
    func saveSong(item: SongItem, noCover: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let db = db else { return }
        
        let sql = """
        INSERT INTO songs (id, name, filename, path, bpm, time_signature, default_key, total_duration,
                           has_cover, cover_url, search_query, is_metronome, subdivide, subdivision, no_cover, auto_analysis, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            filename = excluded.filename,
            path = excluded.path,
            bpm = excluded.bpm,
            time_signature = excluded.time_signature,
            default_key = excluded.default_key,
            total_duration = COALESCE(excluded.total_duration, songs.total_duration),
            has_cover = excluded.has_cover,
            cover_url = excluded.cover_url,
            search_query = excluded.search_query,
            is_metronome = excluded.is_metronome,
            subdivide = excluded.subdivide,
            subdivision = excluded.subdivision,
            no_cover = excluded.no_cover,
            auto_analysis = COALESCE(excluded.auto_analysis, songs.auto_analysis),
            updated_at = excluded.updated_at;
        """
        
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (item.name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (item.filename as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (item.path as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, item.bpm ?? 120.0)
        sqlite3_bind_text(stmt, 6, ((item.time_signature ?? "4/4") as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, ((item.default_key ?? "D") as NSString).utf8String, -1, nil)
        
        if let dur = item.total_duration {
            sqlite3_bind_double(stmt, 8, dur)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        
        sqlite3_bind_int(stmt, 9, (item.has_cover == true) ? 1 : 0)
        
        if let cu = item.cover_url {
            sqlite3_bind_text(stmt, 10, (cu as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        
        let sq = item.search_query ?? cleanSongTitleForSearch(item.name)
        sqlite3_bind_text(stmt, 11, (sq as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 12, (item.is_metronome == true) ? 1 : 0)
        sqlite3_bind_int(stmt, 13, (item.subdivide == true) ? 1 : 0)
        sqlite3_bind_text(stmt, 14, ((item.subdivision ?? "1/4") as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 15, noCover ? 1 : 0)
        if let aa = item.auto_analysis {
            sqlite3_bind_text(stmt, 16, (aa as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 16)
        }
        sqlite3_bind_double(stmt, 17, Date().timeIntervalSince1970)
        
        sqlite3_step(stmt)
        
        if let cues = item.cues {
            saveCuesInternal(songId: item.id, cues: cues)
        }
        if let wf = item.full_waveform {
            saveWaveformInternal(songId: item.id, peaks: wf)
        }
    }
    
    // MARK: - Salvar Cues e Waveforms
    
    func saveCues(
        songId: String,
        cues: [CueSection],
        bpm: Double? = nil,
        timeSignature: String? = nil,
        fullWaveform: [Double]? = nil,
        autoAnalysis: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        
        saveCuesInternal(songId: songId, cues: cues)
        
        if let wf = fullWaveform {
            saveWaveformInternal(songId: songId, peaks: wf)
        }
        
        // Atualiza BPM, Time Signature e auto_analysis na tabela songs se fornecidos
        guard let db = db else { return }
        if bpm != nil || timeSignature != nil || autoAnalysis != nil {
            var updates: [String] = []
            if bpm != nil { updates.append("bpm = ?") }
            if timeSignature != nil { updates.append("time_signature = ?") }
            if autoAnalysis != nil { updates.append("auto_analysis = ?") }
            updates.append("updated_at = ?")
            
            let sql = "UPDATE songs SET \(updates.joined(separator: ", ")) WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var bindIdx: Int32 = 1
                if let b = bpm {
                    sqlite3_bind_double(stmt, bindIdx, b)
                    bindIdx += 1
                }
                if let ts = timeSignature {
                    sqlite3_bind_text(stmt, bindIdx, (ts as NSString).utf8String, -1, nil)
                    bindIdx += 1
                }
                if let aa = autoAnalysis {
                    sqlite3_bind_text(stmt, bindIdx, (aa as NSString).utf8String, -1, nil)
                    bindIdx += 1
                }
                sqlite3_bind_double(stmt, bindIdx, Date().timeIntervalSince1970)
                bindIdx += 1
                sqlite3_bind_text(stmt, bindIdx, (songId as NSString).utf8String, -1, nil)
                
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }
    
    private func saveCuesInternal(songId: String, cues: [CueSection]) {
        guard let db = db else { return }
        
        // Deleta cues antigas da música
        let delSql = "DELETE FROM cues WHERE song_id = ?;"
        var delStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(delStmt, 1, (songId as NSString).utf8String, -1, nil)
            sqlite3_step(delStmt)
            sqlite3_finalize(delStmt)
        }
        
        // Insere novas cues
        let insSql = """
        INSERT INTO cues (song_id, cue_id, cue_order, name, time, bar, color, waveform_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        var insStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insSql, -1, &insStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insStmt) }
        
        for (i, cue) in cues.enumerated() {
            sqlite3_reset(insStmt)
            sqlite3_bind_text(insStmt, 1, (songId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(insStmt, 2, (cue.id as NSString).utf8String, -1, nil)
            sqlite3_bind_int(insStmt, 3, Int32(i))
            sqlite3_bind_text(insStmt, 4, (cue.name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(insStmt, 5, cue.time)
            sqlite3_bind_double(insStmt, 6, cue.bar)
            sqlite3_bind_text(insStmt, 7, (cue.color as NSString).utf8String, -1, nil)
            
            if let wf = cue.waveform, let data = try? JSONSerialization.data(withJSONObject: wf),
               let str = String(data: data, encoding: .utf8) {
                sqlite3_bind_text(insStmt, 8, (str as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(insStmt, 8)
            }
            
            sqlite3_step(insStmt)
        }
    }
    
    private func getCuesInternal(songId: String) -> [CueSection]? {
        guard let db = db else { return nil }
        
        let query = """
        SELECT cue_id, name, time, bar, color, waveform_json
        FROM cues WHERE song_id = ? ORDER BY cue_order ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (songId as NSString).utf8String, -1, nil)
        
        var list: [CueSection] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let cid = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let time = sqlite3_column_double(stmt, 2)
            let bar = sqlite3_column_double(stmt, 3)
            let color = String(cString: sqlite3_column_text(stmt, 4))
            var wf: [Double]? = nil
            if let wfTxt = sqlite3_column_text(stmt, 5) {
                let str = String(cString: wfTxt)
                if let d = str.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: d) as? [Double] {
                    wf = parsed
                }
            }
            list.append(CueSection(id: cid, name: name, time: time, bar: bar, color: color, waveform: wf))
        }
        
        return list.isEmpty ? nil : list
    }
    
    private func saveWaveformInternal(songId: String, peaks: [Double]) {
        guard let db = db, let data = try? JSONSerialization.data(withJSONObject: peaks),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        
        let sql = """
        INSERT INTO waveforms (song_id, peaks_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(song_id) DO UPDATE SET
            peaks_json = excluded.peaks_json,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (songId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (jsonStr as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
    
    private func getWaveformInternal(songId: String) -> [Double]? {
        guard let db = db else { return nil }
        
        let query = "SELECT peaks_json FROM waveforms WHERE song_id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (songId as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) {
            let str = String(cString: txt)
            if let data = str.data(using: .utf8),
               let peaks = try? JSONSerialization.jsonObject(with: data) as? [Double] {
                return peaks
            }
        }
        return nil
    }
    
    // MARK: - Gerenciamento de Capas
    
    func setCoverStatus(songId: String, hasCover: Bool, noCover: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        
        guard let db = db else { return }
        let coverUrl = hasCover ? "/covers/\(songId)" : nil
        
        let sql = """
        UPDATE songs SET
            has_cover = ?,
            cover_url = ?,
            no_cover = ?,
            updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, hasCover ? 1 : 0)
            if let cu = coverUrl {
                sqlite3_bind_text(stmt, 2, (cu as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_int(stmt, 3, noCover ? 1 : 0)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 5, (songId as NSString).utf8String, -1, nil)
            
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }
    
    // MARK: - Migração Automática dos Arquivos .cues.json e Capas Antigas
    
    func migrateLegacyFilesIfNeeded(tracksDirectory: URL, deleteLegacy: Bool = true) -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tracksDirectory.path) else {
            return 0
        }
        
        var migratedCount = 0
        
        // 1. Migração das capas da pasta oculta antiga .covers para Application Support/VSControl/covers
        let legacyCoversDir = tracksDirectory.appendingPathComponent(".covers")
        if let coverFiles = try? FileManager.default.contentsOfDirectory(atPath: legacyCoversDir.path) {
            for cf in coverFiles where !cf.hasPrefix(".") {
                let src = legacyCoversDir.appendingPathComponent(cf)
                let dst = coversDirectory.appendingPathComponent(cf)
                if !FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
                if deleteLegacy {
                    try? FileManager.default.removeItem(at: src)
                }
            }
            if deleteLegacy {
                try? FileManager.default.removeItem(at: legacyCoversDir)
            }
        }
        
        // 2. Migração dos arquivos .cues.json
        for file in files where file.hasSuffix(".cues.json") {
            let jsonPath = tracksDirectory.appendingPathComponent(file).path
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            
            // O songId é o nome do arquivo de áudio correspondente (sem .cues.json)
            let songId = String(file.dropLast(".cues.json".count))
            let audioPath = tracksDirectory.appendingPathComponent(songId).path
            
            // Lê metadados
            let bpm = json["bpm"] as? Double ?? extractBpmFromFilename(songId) ?? 120.0
            let timeSig = json["time_signature"] as? String ?? extractTimeSignatureFromFilename(songId) ?? "4/4"
            let defaultKey = json["default_key"] as? String ?? extractKeyFromFilename(songId) ?? "D"
            let totalDur = json["total_duration"] as? Double
            let cleanName = (json["name"] as? String) ?? (songId as NSString).deletingPathExtension
            let isMetro = (json["is_metronome"] as? Bool) ?? false
            let subdiv = (json["subdivision"] as? String) ?? "1/4"
            let subdivide = (json["subdivide"] as? Bool) ?? (subdiv != "1/4")
            let noCover = (json["no_cover"] as? Bool) ?? false
            
            // Verifica se possui capa em Application Support ou legado
            let coverPath = getCoverFilePath(for: songId)
            let hasCover = FileManager.default.fileExists(atPath: coverPath)
            
            // Parse cues
            var parsedCues: [CueSection] = []
            if let cuesRaw = json["cues"] as? [[String: Any]],
               let cData = try? JSONSerialization.data(withJSONObject: cuesRaw),
               let decoded = try? JSONDecoder().decode([CueSection].self, from: cData) {
                parsedCues = decoded
            }
            
            let fullWf = json["full_waveform"] as? [Double]
            
            let item = SongItem(
                id: songId,
                name: cleanName,
                filename: songId,
                path: audioPath,
                bpm: bpm,
                time_signature: timeSig,
                default_key: defaultKey,
                full_waveform: fullWf,
                has_cover: hasCover,
                cover_url: hasCover ? "/covers/\(songId)" : nil,
                search_query: cleanSongTitleForSearch(cleanName),
                total_duration: totalDur,
                cues: parsedCues,
                is_metronome: isMetro,
                subdivide: subdivide,
                subdivision: subdiv
            )
            
            saveSong(item: item, noCover: noCover)
            migratedCount += 1
            
            // Remove o arquivo .cues.json solto e eventuais backups .bak da pasta
            if deleteLegacy {
                try? FileManager.default.removeItem(atPath: jsonPath)
                let bakPath = jsonPath + ".bak"
                if FileManager.default.fileExists(atPath: bakPath) {
                    try? FileManager.default.removeItem(atPath: bakPath)
                }
                let beforeAiBak = jsonPath + ".before_ai_reprocess.bak"
                if FileManager.default.fileExists(atPath: beforeAiBak) {
                    try? FileManager.default.removeItem(atPath: beforeAiBak)
                }
            }
        }
        
        // Remove também arquivos órfãos de backup .bak que possam ter ficado
        if deleteLegacy {
            for file in files where file.hasSuffix(".cues.json.bak") || file.hasSuffix(".before_ai_reprocess.bak") {
                try? FileManager.default.removeItem(at: tracksDirectory.appendingPathComponent(file))
            }
        }
        
        return migratedCount
    }
}
