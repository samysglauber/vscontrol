import SwiftUI
import AppKit
import Foundation
import Combine
import CoreImage
import UniformTypeIdentifiers

// ==========================================
// 1. MODELOS DE DADOS
// ==========================================

struct CueSection: Identifiable, Codable {
    var id: String
    var name: String
    var time: Double
    var bar: Double
    var color: String
    var waveform: [Double]?
    
    var cleanFullName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Section" }
        if trimmed.caseInsensitiveCompare("Outro") == .orderedSame { return "Ending" }
        return trimmed
    }
    
    var shortBadgeName: String {
        let raw = cleanFullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = raw.uppercased()
        
        if upper.contains("COUNT") || upper.contains("CONTAGEM") || upper.contains("1234") {
            return "Co"
        }
        if upper.contains("INTRO") {
            return "I"
        }
        if upper.contains("PRE") || upper.contains("PRÉ") {
            if upper.contains("2") { return "P2" }
            return "Pc"
        }
        if upper.contains("POST") || upper.contains("PÓS") || upper.contains("POS") {
            for n in ["2", "3"] {
                if upper.contains(n) { return "Po\(n)" }
            }
            return "Po"
        }
        if upper.contains("CHORUS") || upper.contains("REFRÃO") || upper.contains("REFRAO") {
            for n in ["2", "3", "4"] {
                if upper.contains(n) { return "C\(n)" }
            }
            return "C"
        }
        if upper.contains("VERSE") || upper.contains("VERSO") {
            for n in ["1", "2", "3", "4", "5", "6"] {
                if upper.contains(n) { return "V\(n)" }
            }
            return "V"
        }
        if upper.contains("BRIDGE") || upper.contains("PONTE") {
            for n in ["2", "3"] {
                if upper.contains(n) { return "B\(n)" }
            }
            return "B"
        }
        if upper.contains("SOLO") {
            return "S"
        }
        if upper.contains("VAMP") {
            return "Vp"
        }
        if upper.contains("TAG") {
            if upper.contains("2") { return "Tg2" }
            return "Tg"
        }
        if upper.contains("INTERLUDE") || upper.contains("INTERLÚDIO") || upper.contains("INTER") {
            return "It"
        }
        if upper.contains("INSTRUMENTAL") || upper.contains("INST") {
            return "Ins"
        }
        if upper.contains("ENDING") || upper.contains("OUTRO") || upper.contains("FINAL") {
            return "E"
        }
        
        if raw.count <= 2 {
            return raw.uppercased()
        }
        return String(raw.prefix(2)).capitalized
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch clean.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

func formatBpm(_ bpm: Double) -> String {
    if bpm.truncatingRemainder(dividingBy: 1) == 0 {
        return "\(Int(bpm))"
    } else {
        return String(format: "%.1f", bpm).replacingOccurrences(of: ".", with: ",")
    }
}

func formatBars(_ value: Double) -> String {
    if value.truncatingRemainder(dividingBy: 1.0) == 0 {
        return "\(Int(value))"
    } else if value.truncatingRemainder(dividingBy: 0.5) == 0 {
        let whole = Int(value)
        return whole > 0 ? "\(whole)½" : "½"
    } else {
        return String(format: "%.1f", value)
    }
}

func colorForCue(name: String) -> String {
    let upper = name.uppercased()
    if upper.contains("COUNT") || upper.contains("CONTAGEM") { return "#64748b" }
    if upper.contains("POST") || upper.contains("PÓS") || upper.contains("POS") { return "#fb7185" }
    if upper.contains("PRE") || upper.contains("PRÉ") { return "#eab308" }
    if upper.contains("CHORUS") || upper.contains("REFRÃO") || upper.contains("CORO") { return "#ef4444" }
    if upper.contains("BRIDGE") || upper.contains("PONTE") { return "#f97316" }
    if upper.contains("INTRO") { return "#38bdf8" }
    if upper.contains("INSTRUMENTAL") || upper.contains("INST") { return "#10b981" }
    if upper.contains("VERSE") || upper.contains("VERSO") { return "#a855f7" }
    if upper.contains("INTERLUDE") || upper.contains("INTERLÚDIO") || upper.contains("INTER") { return "#06b6d4" }
    if upper.contains("SOLO") { return "#06b6d4" }
    if upper.contains("TAG") { return "#ec4899" }
    if upper.contains("ENDING") || upper.contains("OUTRO") || upper.contains("FINAL") { return "#64748b" }
    return "#3b82f6"
}

func cleanSongTitleForSearch(_ name: String) -> String {
    var s = name
    for ext in [".mp3", ".wav", ".m4a", ".aif", ".aiff"] {
        if s.lowercased().hasSuffix(ext) {
            s = String(s.dropLast(ext.count))
            break
        }
    }
    if let match = s.range(of: #"^\d+\s*[-_]\s*"#, options: .regularExpression) {
        s.removeSubrange(match)
    }
    if let match = s.range(of: #"[-_]\s*vs\b.*$"#, options: [.regularExpression, .caseInsensitive]) {
        s.removeSubrange(match)
    }
    s = s.replacingOccurrences(of: #"\(\s*\d+\s*bpm\s*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
    s = s.replacingOccurrences(of: #"\(\s*[A-Ga-g][#b]?m?\s*\)"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\(com[^\)]*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.isEmpty ? name : s
}

struct SongItem: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let filename: String
    let path: String
    var bpm: Double?
    var time_signature: String?
    var default_key: String?
    var full_waveform: [Double]?
    var has_cover: Bool?
    var cover_url: String?
    var search_query: String?
    
    var displayKey: String {
        return default_key ?? "D"
    }
}

struct CoverSearchResult: Identifiable, Codable {
    let id: String
    let track_name: String
    let artist_name: String
    let collection_name: String
    let artwork_url: String
    let artwork_url_small: String
    let year: String
}

class CoverImageCache {
    static let shared = CoverImageCache()
    private let cache = NSCache<NSString, NSImage>()
    
    func image(for song: SongItem) -> NSImage? {
        let key = song.id as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let dir = (song.path as NSString).deletingLastPathComponent
        let coverPath = (dir as NSString).appendingPathComponent(".covers/\(song.id).jpg")
        if FileManager.default.fileExists(atPath: coverPath),
           let img = NSImage(contentsOfFile: coverPath) {
            cache.setObject(img, forKey: key)
            return img
        }
        return nil
    }
    
    func remove(for songId: String) {
        cache.removeObject(forKey: songId as NSString)
    }
    
    func clearAll() {
        cache.removeAllObjects()
    }
}

struct SongCoverView: View {
    let song: SongItem
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    var isSelected: Bool = false
    var refreshId: Int = 0
    
    var body: some View {
        ZStack {
            if let img = CoverImageCache.shared.image(for: song) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else if song.has_cover == true, let coverUrl = song.cover_url,
                      let url = URL(string: "http://127.0.0.1:8080" + coverUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: height)
                            .clipped()
                    case .failure(_):
                        fallbackGradient
                    default:
                        ZStack {
                            fallbackGradient
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
            } else {
                fallbackGradient
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(isSelected ? Color.white : Color.white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(color: isSelected ? Color.white.opacity(0.25) : Color.clear, radius: 8)
        .id("\(song.id)_\(refreshId)")
        .onAppear {
            if song.has_cover != true {
                PlaybackState.shared.autoFetchCover(for: song)
            }
        }
    }
    
    private var fallbackGradient: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.18, blue: 0.23),
                            Color(red: 0.09, green: 0.10, blue: 0.13)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Color.white.opacity(0.25))
        }
    }
}

struct SetlistSong: Identifiable, Equatable {
    let id: UUID
    let song: SongItem
    var transitionType: String
    
    init(id: UUID = UUID(), song: SongItem, transitionType: String = "AUTO") {
        self.id = id
        self.song = song
        self.transitionType = transitionType
    }
    
    static func == (lhs: SetlistSong, rhs: SetlistSong) -> Bool {
        lhs.id == rhs.id
    }
}

struct SavedSetlistSongItem: Codable {
    let song: SongItem
    let transitionType: String
}

struct SetlistDocumentItem: Codable {
    var song: SongItem
    var transitionType: String
    var cues: [CueSection]?
}

struct SetlistDocument: Codable {
    var version: Int = 1
    var name: String
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
    var items: [SetlistDocumentItem]
}

struct AudioDeviceItem: Identifiable, Codable {
    let id: Int
    let name: String
    let channels: Int
    let is_default: Bool
    let is_blackhole: Bool
}

struct TracksFolderResponse: Codable {
    let path: String
    let exists: Bool
    let songs_count: Int?
}

struct RefreshTracksResponse: Codable {
    let status: String
    let path: String
    let songs_count: Int
    let songs: [SongItem]?
}

struct CueHistorySnapshot {
    let cues: [CueSection]
    let bpm: Double
    let timeSignature: String
    let description: String
}

// ==========================================
// 2. GERENCIADOR DE ESTADO E WEBSOCKET
// ==========================================

class PlaybackState: ObservableObject {
    static let shared = PlaybackState()
    
    @Published var currentSetlistName: String = "Untitled Setlist"
    @Published var currentSetlistFilePath: String? = nil
    
    var defaultSetlistsFolder: URL {
        let preferred = URL(fileURLWithPath: "/Users/samysglauber/Documents/AbletonTracks/Setlists")
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred
        }
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AbletonTracks/Setlists") ?? preferred
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
    
    @Published var songs: [SongItem] = []
    @Published var librarySongs: [SongItem] = []
    @Published var isLoadingLibrary: Bool = false
    @Published var tracksFolderPath: String = ""
    @Published var isScanningFolder: Bool = false
    
    // Pilhas de Desfazer e Refazer (Undo / Redo) para Edição de Cues
    private var undoStack: [CueHistorySnapshot] = []
    private var redoStack: [CueHistorySnapshot] = []
    @Published var undoNotificationMessage: String? = nil
    
    // Controle de concorrência e throttle de auto-fetch de capas
    private var isSavingSetlistDoc = false
    private var attemptedCoverAutoFetchSongIds: Set<String> = []
    
    var shortFolderName: String {
        if tracksFolderPath.isEmpty { return "Tracks" }
        let name = URL(fileURLWithPath: tracksFolderPath).lastPathComponent
        return name.isEmpty ? "Tracks" : name
    }
    
    @Published var setlist: [SetlistSong] = [] {
        didSet {
            saveSetlistState()
        }
    }
    @Published var draggedSetlistSong: SetlistSong? = nil
    @Published var isEditMode: Bool = false
    
    @Published var currentSong: SongItem? = nil
    @Published var currentCues: [CueSection] = []
    @Published var fullWaveform: [Double] = []
    
    var displayFullWaveform: [Double] {
        if !fullWaveform.isEmpty { return fullWaveform }
        guard !currentCues.isEmpty, totalSeconds > 0 else { return [] }
        
        let targetTotalPeaks = 1000
        var result: [Double] = []
        for (idx, cue) in currentCues.enumerated() {
            let nextT = (idx + 1 < currentCues.count) ? currentCues[idx + 1].time : totalSeconds
            let dur = max(0.01, nextT - cue.time)
            let countForThisCue = max(1, Int(round((dur / totalSeconds) * Double(targetTotalPeaks))))
            let cueWf = cue.waveform ?? []
            if cueWf.isEmpty {
                result.append(contentsOf: Array(repeating: 0.04, count: countForThisCue))
            } else if cueWf.count == countForThisCue {
                result.append(contentsOf: cueWf)
            } else {
                for p in 0..<countForThisCue {
                    let t = Double(p) / Double(max(1, countForThisCue - 1))
                    let srcIdx = min(cueWf.count - 1, Int(t * Double(cueWf.count - 1)))
                    result.append(cueWf[srcIdx])
                }
            }
        }
        return result
    }
    
    @Published var isPlaying: Bool = false
    @Published var currentSeconds: Double = 0.0
    @Published var totalSeconds: Double = 240.0
    @Published var currentBar: Int = 1
    @Published var currentBeat: Int = 1
    @Published var bpm: Double = 120.0
    @Published var timeSignature: String = "4/4"
    
    @Published var currentCueIdx: Int = 0
    @Published var queuedCueIdx: Int? = nil
    @Published var focusedCueIdx: Int? = nil
    @Published var loopActive: Bool = false
    @Published var loopCueIdx: Int? = nil
    @Published var padActive: Bool = false
    @Published var padKey: String = "D"
    
    @Published var clickVol: Double = 1.0
    @Published var vsVol: Double = 1.0
    @Published var clickMute: Bool = false
    @Published var vsMute: Bool = false
    @Published var isFadingOut: Bool = false
    @Published var isFadedOut: Bool = false
    @Published var isFadingIn: Bool = false
    @Published var abletonSynced: Bool = false
    @Published var scrollToStartTrigger: Int = 0
    @Published var zoomLevel: Double = 0.35 {
        didSet {
            UserDefaults.standard.set(zoomLevel, forKey: "saved_timeline_zoom_level")
        }
    }
    
    func triggerScrollToStart() {
        DispatchQueue.main.async {
            self.scrollToStartTrigger += 1
        }
    }
    
    @Published var devices: [AudioDeviceItem] = []
    @Published var selectedDeviceId: Int = 7
    @Published var selectedDeviceName: String = "BlackHole 2ch"
    
    @Published var isAddSongSheetPresented: Bool = false
    @Published var isQrModalPresented: Bool = false
    @Published var isSongEditorPresented: Bool = false
    @Published var serverUrl: String = "http://localhost:8080"
    
    // Estado de Capas de Álbuns / Músicas
    @Published var isCoverPickerPresented: Bool = false
    @Published var coverPickerSong: SongItem? = nil
    @Published var coverSearchResults: [CoverSearchResult] = []
    @Published var isSearchingCovers: Bool = false
    @Published var isSavingCover: Bool = false
    @Published var coverSearchQuery: String = ""
    @Published var coverPickerError: String? = nil
    @Published var coverRefreshTrigger: Int = 0
    
    // Estado do Editor de Música
    @Published var editorBpm: Double = 120.0
    @Published var editorTimeSignature: String = "4/4"
    @Published var editorCues: [CueSection] = []
    @Published var isReprocessing: Bool = false
    @Published var quickEditingCueIdx: Int? = nil
    @Published var autoAdvance: Bool = true {
        didSet {
            UserDefaults.standard.set(autoAdvance, forKey: "saved_auto_advance")
        }
    }
    @Published var guideLeadInBars: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(guideLeadInBars, forKey: "saved_guide_lead_in")
            sendAction("set_guide_lead_in", body: ["bars": guideLeadInBars])
        }
    }
    
    private var webSocketTask: URLSessionWebSocketTask?
    
    init() {
        if UserDefaults.standard.object(forKey: "saved_auto_advance") != nil {
            self.autoAdvance = UserDefaults.standard.bool(forKey: "saved_auto_advance")
        }
        if let savedLeadIn = UserDefaults.standard.object(forKey: "saved_guide_lead_in") as? Double {
            self.guideLeadInBars = savedLeadIn
        }
        if let savedFolder = UserDefaults.standard.string(forKey: "saved_tracks_folder_path") {
            self.tracksFolderPath = savedFolder
        }
        if let savedZoom = UserDefaults.standard.object(forKey: "saved_timeline_zoom_level") as? Double {
            self.zoomLevel = savedZoom
        }
        
        // 1. Restauração instantânea (0.00s) das músicas da Setlist salvas localmente
        restoreInitialSetlistFromCache()
        
        // 2. Busca e atualiza apenas as músicas da Setlist no backend
        fetchSetlistSongs()
        fetchTracksFolder()
        fetchDevices()
        fetchNetworkInfo()
        setupWebSocket()
    }
    
    private func restoreInitialSetlistFromCache() {
        // 1. Tenta abrir por padrão o último setlist aberto
        if let lastPath = UserDefaults.standard.string(forKey: "last_opened_setlist_path"),
           FileManager.default.fileExists(atPath: lastPath) {
            let url = URL(fileURLWithPath: lastPath)
            if self.loadSetlistFrom(url: url, isInitialRestore: true) {
                return
            }
        }
        
        // 2. Fallback: carregar do cache local UserDefaults caso nenhum arquivo de setlist específico tenha sido aberto
        if let fullData = UserDefaults.standard.data(forKey: "saved_setlist_full_songs"),
           let savedList = try? JSONDecoder().decode([SavedSetlistSongItem].self, from: fullData),
           !savedList.isEmpty {
            self.setlist = savedList.map { SetlistSong(song: $0.song, transitionType: $0.transitionType) }
            let lastSongId = UserDefaults.standard.string(forKey: "saved_last_loaded_song_id")
            if let lastId = lastSongId, let target = self.setlist.first(where: { $0.song.id == lastId }) {
                self.loadSong(target.song)
            } else if let first = self.setlist.first {
                self.loadSong(first.song)
            }
        } else if let lastSongId = UserDefaults.standard.string(forKey: "saved_last_loaded_song_id") {
            let dummy = SongItem(id: lastSongId, name: lastSongId.replacingOccurrences(of: ".mp3", with: "").replacingOccurrences(of: ".wav", with: ""), filename: lastSongId, path: "/Users/samysglauber/Documents/Vs/\(lastSongId)", bpm: 120.0, time_signature: "4/4", default_key: "D", full_waveform: nil)
            self.loadSong(dummy)
        }
    }
    
    func setupWebSocket() {
        guard let url = URL(string: "ws://127.0.0.1:8080/ws") else { return }
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveWebSocketMessage()
    }
    
    private func receiveWebSocketMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleWebSocketJson(text)
                default: break
                }
                self.receiveWebSocketMessage()
            case .failure:
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.setupWebSocket()
                }
            }
        }
    }
    
    private func handleWebSocketJson(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String,
              let eventData = json["data"] as? [String: Any] else { return }
        
        DispatchQueue.main.async {
            if event == "tick" || event == "status" {
                if let playing = eventData["is_playing"] as? Bool {
                    // Fallback de segurança para avanço automático de Setlist caso o evento WebSocket de fim se perca
                    if self.isPlaying && !playing && self.totalSeconds > 0 && self.currentSeconds >= self.totalSeconds - 0.4 {
                        if self.autoAdvance {
                            self.advanceToNextSetlistSong()
                        }
                    }
                    if self.isPlaying != playing { self.isPlaying = playing }
                }
                if let fState = eventData["tracks_fade_state"] as? String {
                    self.isFadedOut = (fState == "faded_out")
                    self.isFadingOut = (fState == "fading_out")
                    self.isFadingIn = (fState == "fading_in")
                } else if let fActive = eventData["fade_stop_active"] as? Bool {
                    if !fActive && !self.isFadedOut {
                        self.isFadingOut = false
                        self.isFadingIn = false
                    }
                }
                if let isFaded = eventData["is_faded_out"] as? Bool {
                    self.isFadedOut = isFaded
                }
                if let cMute = eventData["click_mute"] as? Bool, self.clickMute != cMute { self.clickMute = cMute }
                if let vMute = eventData["vs_mute"] as? Bool, self.vsMute != vMute { self.vsMute = vMute }
                if let cVol = eventData["click_vol"] as? Double, abs(self.clickVol - cVol) > 0.005 { self.clickVol = cVol }
                if let vVol = eventData["vs_vol"] as? Double, abs(self.vsVol - vVol) > 0.005 { self.vsVol = vVol }
                if let curSec = eventData["current_seconds"] as? Double, abs(self.currentSeconds - curSec) > 0.015 { self.currentSeconds = curSec }
                if let totSec = eventData["total_seconds"] as? Double, totSec > 0, abs(self.totalSeconds - totSec) > 0.015 { self.totalSeconds = totSec }
                if let bar = eventData["bar"] as? Int, self.currentBar != bar { self.currentBar = bar }
                if let beat = eventData["beat"] as? Int, self.currentBeat != beat { self.currentBeat = beat }
                if let bpmVal = eventData["bpm"] as? Double, abs(self.bpm - bpmVal) > 0.01 { self.bpm = bpmVal }
                if let sig = eventData["time_signature"] as? String, self.timeSignature != sig { self.timeSignature = sig }
                if let cIdx = eventData["current_cue_idx"] as? Int, self.currentCueIdx != cIdx { self.currentCueIdx = cIdx }
                let newQueued = eventData["queued_cue_idx"] as? Int
                if self.queuedCueIdx != newQueued { self.queuedCueIdx = newQueued }
                if let loop = eventData["loop_active"] as? Bool, self.loopActive != loop { self.loopActive = loop }
                let newLoopCue = eventData["loop_cue_idx"] as? Int
                if self.loopCueIdx != newLoopCue { self.loopCueIdx = newLoopCue }
                if let pad = eventData["pad_active"] as? Bool, self.padActive != pad { self.padActive = pad }
            } else if event == "fade_tracks_started" || event == "fade_stop_started" {
                if let fState = eventData["state"] as? String {
                    self.isFadingOut = (fState == "fading_out")
                    self.isFadingIn = (fState == "fading_in")
                    if fState == "fading_out" { self.isFadedOut = false }
                } else {
                    self.isFadingOut = true
                }
            } else if event == "fade_tracks_ended" {
                if let fState = eventData["state"] as? String {
                    self.isFadedOut = (fState == "faded_out")
                    self.isFadingOut = false
                    self.isFadingIn = false
                }
            } else if event == "play_state" {
                if let p = eventData["is_playing"] as? Bool {
                    if self.isPlaying != p { self.isPlaying = p }
                }
            } else if event == "volume_state" {
                if let cm = eventData["click_mute"] as? Bool, self.clickMute != cm { self.clickMute = cm }
                if let vm = eventData["vs_mute"] as? Bool, self.vsMute != vm { self.vsMute = vm }
                if let cv = eventData["click_vol"] as? Double, abs(self.clickVol - cv) > 0.005 { self.clickVol = cv }
                if let vv = eventData["vs_vol"] as? Double, abs(self.vsVol - vv) > 0.005 { self.vsVol = vv }
            } else if event == "cue_queued" {
                let qIdx = eventData["queued_cue_idx"] as? Int
                if self.queuedCueIdx != qIdx { self.queuedCueIdx = qIdx }
            } else if event == "cue_jumped" {
                if let cIdx = eventData["current_cue_idx"] as? Int {
                    self.currentCueIdx = cIdx
                    if self.focusedCueIdx == cIdx {
                        self.focusedCueIdx = nil
                    }
                }
                self.queuedCueIdx = nil
            } else if event == "loop_state" {
                if let loop = eventData["loop_active"] as? Bool { self.loopActive = loop }
                if let lIdx = eventData["loop_cue_idx"] as? Int { self.loopCueIdx = lIdx } else { self.loopCueIdx = nil }
            } else if event == "song_ended" {
                self.isPlaying = false
                if self.autoAdvance {
                    self.advanceToNextSetlistSong()
                }
            }
        }
    }
    
    func advanceToNextSetlistSong() {
        guard let current = currentSong,
              let currentIndex = setlist.firstIndex(where: { $0.song.id == current.id }) else {
            return
        }
        let currentItem = setlist[currentIndex]
        let nextIndex = currentIndex + 1
        if nextIndex < setlist.count {
            let nextSong = setlist[nextIndex].song
            let shouldAutoPlay = (currentItem.transitionType == "AUTO")
            loadSong(nextSong, autoPlay: shouldAutoPlay)
        }
    }
    
    func saveSetlistState() {
        let savedItems = setlist.map { item -> [String: String] in
            return [
                "id": item.song.id,
                "transition": item.transitionType
            ]
        }
        if let data = try? JSONEncoder().encode(savedItems) {
            UserDefaults.standard.set(data, forKey: "saved_setlist_items")
        }
        
        let fullItems = setlist.map { item -> SavedSetlistSongItem in
            return SavedSetlistSongItem(song: item.song, transitionType: item.transitionType)
        }
        if let fullData = try? JSONEncoder().encode(fullItems) {
            UserDefaults.standard.set(fullData, forKey: "saved_setlist_full_songs")
        }
        
        if let currentId = currentSong?.id {
            UserDefaults.standard.set(currentId, forKey: "saved_last_loaded_song_id")
        }
        UserDefaults.standard.synchronize()
        
        // Auto-salvamento no arquivo de setlist ativo (se houver um arquivo aberto) com proteção contra reentrância
        if !isSavingSetlistDoc, let filePath = currentSetlistFilePath, FileManager.default.fileExists(atPath: filePath) {
            isSavingSetlistDoc = true
            saveSetlistTo(url: URL(fileURLWithPath: filePath), notify: false) { [weak self] in
                self?.isSavingSetlistDoc = false
            }
        }
    }
    
    func toggleTransition(at index: Int) {
        guard index >= 0 && index < setlist.count else { return }
        setlist[index].transitionType = (setlist[index].transitionType == "AUTO") ? "STOP" : "AUTO"
        saveSetlistState()
    }
    
    func restoreSetlist(with availableSongs: [SongItem]) {
        guard !availableSongs.isEmpty else { return }
        
        if let data = UserDefaults.standard.data(forKey: "saved_setlist_items"),
           let savedList = try? JSONDecoder().decode([[String: String]].self, from: data),
           !savedList.isEmpty {
            
            var restored: [SetlistSong] = []
            for item in savedList {
                if let sId = item["id"],
                   let foundSong = availableSongs.first(where: { $0.id == sId }) {
                    let trans = item["transition"] ?? "AUTO"
                    restored.append(SetlistSong(song: foundSong, transitionType: trans))
                }
            }
            
            if !restored.isEmpty {
                self.setlist = restored
                self.autoFetchCoversIfNeeded()
                
                let lastSongId = UserDefaults.standard.string(forKey: "saved_last_loaded_song_id")
                if let lastId = lastSongId,
                   let target = availableSongs.first(where: { $0.id == lastId }) {
                    self.loadSong(target)
                } else if let first = restored.first {
                    self.loadSong(first.song)
                }
                return
            }
        }
    }
    
    // ==========================================
    // GERENCIAMENTO DE ARQUIVOS DE SETLIST (.vset / .json)
    // ==========================================
    
    func newSetlist() {
        if isPlaying {
            playPause()
        }
        self.setlist = []
        self.currentSong = nil
        self.currentCues = []
        self.fullWaveform = []
        self.currentSetlistFilePath = nil
        self.currentSetlistName = "Untitled Setlist"
        UserDefaults.standard.removeObject(forKey: "last_opened_setlist_path")
        UserDefaults.standard.synchronize()
        showUndoFeedback("Novo Setlist criado. Adicione músicas pelo card '+ Add a Song'.")
    }
    
    func saveSetlist(completion: (() -> Void)? = nil) {
        if let path = currentSetlistFilePath, !path.isEmpty {
            saveSetlistTo(url: URL(fileURLWithPath: path), notify: true, completion: completion)
        } else {
            saveSetlistAs(completion: completion)
        }
    }
    
    func saveSetlistAs(completion: (() -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.title = "Save Setlist"
        panel.message = "Escolha o nome e local para salvar este Setlist"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        if let vsetType = UTType(filenameExtension: "vset") {
            panel.allowedContentTypes = [vsetType, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        let defaultName = (currentSetlistName.isEmpty || currentSetlistName == "Untitled Setlist") ? "Setlist 1.vset" : "\(currentSetlistName).vset"
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = defaultSetlistsFolder
        
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            DispatchQueue.main.async {
                self.saveSetlistTo(url: url, notify: true, completion: completion)
            }
        }
    }
    
    func saveSetlistTo(url: URL, notify: Bool = true, completion: (() -> Void)? = nil) {
        var docItems: [SetlistDocumentItem] = []
        for item in setlist {
            var cuesForThisSong: [CueSection]? = nil
            if item.song.id == currentSong?.id && !currentCues.isEmpty {
                cuesForThisSong = currentCues
            } else if let cachedData = UserDefaults.standard.data(forKey: "saved_cues_\(item.song.id)"),
                      let decoded = try? JSONDecoder().decode([CueSection].self, from: cachedData) {
                cuesForThisSong = decoded
            }
            docItems.append(SetlistDocumentItem(song: item.song, transitionType: item.transitionType, cues: cuesForThisSong))
        }
        
        let docName = url.deletingPathExtension().lastPathComponent
        let doc = SetlistDocument(
            version: 1,
            name: docName,
            createdAt: Date(),
            updatedAt: Date(),
            items: docItems
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(doc)
            try data.write(to: url, options: .atomic)
            
            DispatchQueue.main.async {
                self.currentSetlistFilePath = url.path
                self.currentSetlistName = docName
                self.addRecentSetlistPath(url.path)
                UserDefaults.standard.set(url.path, forKey: "last_opened_setlist_path")
                UserDefaults.standard.synchronize()
                
                if notify {
                    self.showUndoFeedback("Setlist '\(docName)' salva com sucesso!")
                }
                completion?()
            }
        } catch {
            DispatchQueue.main.async {
                if notify {
                    self.showUndoFeedback("Erro ao salvar Setlist: \(error.localizedDescription)")
                }
                completion?()
            }
        }
    }
    
    func openSetlistDialog(completion: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.title = "Open Setlist"
        panel.message = "Selecione um arquivo de Setlist (.vset ou .json) para abrir"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsOtherFileTypes = true
        if let vsetType = UTType(filenameExtension: "vset") {
            panel.allowedContentTypes = [vsetType, .json, .data]
        } else {
            panel.allowedContentTypes = [.json, .data]
        }
        panel.directoryURL = defaultSetlistsFolder
        
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            DispatchQueue.main.async {
                self.loadSetlistFrom(url: url)
                completion?()
            }
        }
    }
    
    @discardableResult
    func loadSetlistFrom(url: URL, isInitialRestore: Bool = false) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            if !isInitialRestore {
                showUndoFeedback("Arquivo de setlist não encontrado.")
            }
            return false
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        var loadedItems: [SetlistDocumentItem] = []
        var docName = url.deletingPathExtension().lastPathComponent
        
        if let doc = try? decoder.decode(SetlistDocument.self, from: data) {
            loadedItems = doc.items
            if !doc.name.isEmpty {
                docName = doc.name
            }
        } else if let legacyItems = try? decoder.decode([SavedSetlistSongItem].self, from: data) {
            loadedItems = legacyItems.map { SetlistDocumentItem(song: $0.song, transitionType: $0.transitionType, cues: nil) }
        } else {
            if !isInitialRestore {
                showUndoFeedback("Formato de setlist inválido.")
            }
            return false
        }
        
        if isPlaying {
            playPause()
        }
        
        var restoredSongs: [SetlistSong] = []
        for it in loadedItems {
            // Se o setlist trouxer cues, restaura no cache local
            if let cues = it.cues, !cues.isEmpty,
               let cuesData = try? JSONEncoder().encode(cues) {
                UserDefaults.standard.set(cuesData, forKey: "saved_cues_\(it.song.id)")
            }
            
            // Prioriza músicas da biblioteca caso estejam carregadas
            let songToUse: SongItem
            if let found = librarySongs.first(where: { $0.id == it.song.id }) {
                songToUse = found
            } else {
                songToUse = it.song
            }
            restoredSongs.append(SetlistSong(song: songToUse, transitionType: it.transitionType))
        }
        
        DispatchQueue.main.async {
            self.setlist = restoredSongs
            self.autoFetchCoversIfNeeded()
            self.currentSetlistFilePath = url.path
            self.currentSetlistName = docName
            self.addRecentSetlistPath(url.path)
            UserDefaults.standard.set(url.path, forKey: "last_opened_setlist_path")
            UserDefaults.standard.synchronize()
            self.saveSetlistState()
            
            if let first = restoredSongs.first {
                self.loadSong(first.song)
            } else {
                self.currentSong = nil
                self.currentCues = []
                self.fullWaveform = []
            }
            
            self.fetchSetlistSongs()
            
            if !isInitialRestore {
                self.showUndoFeedback("Setlist '\(docName)' carregada!")
            }
        }
        return true
    }
    
    func getRecentSetlistPaths() -> [String] {
        let list = UserDefaults.standard.stringArray(forKey: "recent_setlist_paths") ?? []
        return list.filter { FileManager.default.fileExists(atPath: $0) }
    }
    
    func addRecentSetlistPath(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: "recent_setlist_paths") ?? []
        list.removeAll(where: { $0 == path })
        list.insert(path, at: 0)
        if list.count > 10 {
            list = Array(list.prefix(10))
        }
        UserDefaults.standard.set(list, forKey: "recent_setlist_paths")
        UserDefaults.standard.synchronize()
    }
    
    func clearRecentSetlists() {
        UserDefaults.standard.removeObject(forKey: "recent_setlist_paths")
        UserDefaults.standard.synchronize()
        showUndoFeedback("Histórico de setlists recentes limpo.")
    }
    
    func fetchSetlistSongs(retryCount: Int = 0) {
        // Carrega APENAS as músicas que estão na setlist para inicialização relâmpago
        let ids = setlist.map { $0.song.id }
        let urlStr: String
        if !ids.isEmpty {
            let joined = ids.joined(separator: ",")
            let encoded = joined.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? joined
            urlStr = "http://127.0.0.1:8080/api/songs?ids=\(encoded)"
        } else {
            urlStr = "http://127.0.0.1:8080/api/songs"
        }
        
        guard let url = URL(string: urlStr) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            if let data = data, let songs = try? JSONDecoder().decode([SongItem].self, from: data), !songs.isEmpty {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.songs = songs
                    if self.setlist.isEmpty {
                        self.restoreSetlist(with: songs)
                    } else {
                        // Atualiza as instâncias da setlist com dados frescos do servidor
                        for (idx, item) in self.setlist.enumerated() {
                            if let updated = songs.first(where: { $0.id == item.song.id }) {
                                self.setlist[idx] = SetlistSong(id: item.id, song: updated, transitionType: item.transitionType)
                            }
                        }
                        if let current = self.currentSong {
                            self.loadSong(current)
                        } else if let first = self.setlist.first {
                            self.loadSong(first.song)
                        }
                    }
                }
            } else {
                // Tenta novamente enquanto o servidor Python inicializa
                if retryCount < 15 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.fetchSetlistSongs(retryCount: retryCount + 1)
                    }
                }
            }
        }.resume()
    }
    
    func fetchAllLibrarySongs() {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        guard let url = URL(string: "http://127.0.0.1:8080/api/songs") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.isLoadingLibrary = false
                if let data = data, let songs = try? JSONDecoder().decode([SongItem].self, from: data) {
                    self?.librarySongs = songs
                    self?.songs = songs
                }
            }
        }.resume()
    }
    
    func fetchTracksFolder() {
        guard let url = URL(string: "http://127.0.0.1:8080/api/tracks/folder") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let resp = try? JSONDecoder().decode(TracksFolderResponse.self, from: data) else { return }
            DispatchQueue.main.async {
                self?.tracksFolderPath = resp.path
                UserDefaults.standard.set(resp.path, forKey: "saved_tracks_folder_path")
            }
        }.resume()
    }
    
    func selectTracksFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Select Folder"
        panel.message = "Choose the folder where your Multitrack / VS audio files are stored."
        if !tracksFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: tracksFolderPath)
        }
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            let path = selectedURL.path
            setTracksFolder(path: path)
        }
    }
    
    func setTracksFolder(path: String) {
        self.tracksFolderPath = path
        UserDefaults.standard.set(path, forKey: "saved_tracks_folder_path")
        self.isScanningFolder = true
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/tracks/folder") else {
            self.isScanningFolder = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["path": path]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.isScanningFolder = false
                self?.fetchAllLibrarySongs()
                self?.fetchSetlistSongs()
            }
        }.resume()
    }
    
    func refreshTracks() {
        guard !isScanningFolder else { return }
        isScanningFolder = true
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/tracks/refresh") else {
            isScanningFolder = false
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isScanningFolder = false
                if let data = data,
                   let resp = try? JSONDecoder().decode(RefreshTracksResponse.self, from: data),
                   let songs = resp.songs {
                    self.librarySongs = songs
                    self.songs = songs
                    
                    // Atualiza dados de músicas que já estejam no setlist sem alterar a lista
                    for (idx, item) in self.setlist.enumerated() {
                        if let updated = songs.first(where: { $0.id == item.song.id }) {
                            self.setlist[idx] = SetlistSong(id: item.id, song: updated, transitionType: item.transitionType)
                        }
                    }
                }
            }
        }.resume()
    }
    
    func fetchSongs(retryCount: Int = 0) {
        fetchSetlistSongs(retryCount: retryCount)
    }
    
    func fetchDevices() {
        guard let url = URL(string: "http://127.0.0.1:8080/api/devices") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let devs = try? JSONDecoder().decode([AudioDeviceItem].self, from: data) else { return }
            DispatchQueue.main.async {
                self?.devices = devs
                
                let savedName = UserDefaults.standard.string(forKey: "saved_audio_device_name")
                let savedId = UserDefaults.standard.object(forKey: "saved_audio_device_id") as? Int
                
                // 1. Tenta restaurar pelo nome salvo
                if let savedName = savedName, let match = devs.first(where: { $0.name == savedName }) {
                    self?.selectedDeviceId = match.id
                    self?.selectedDeviceName = match.name
                    self?.setAudioDevice(id: match.id, save: false)
                } else if let savedId = savedId, let match = devs.first(where: { $0.id == savedId }) {
                    self?.selectedDeviceId = match.id
                    self?.selectedDeviceName = match.name
                    self?.setAudioDevice(id: match.id, save: false)
                } else if let blackhole = devs.first(where: { $0.is_blackhole }) {
                    self?.selectedDeviceId = blackhole.id
                    self?.selectedDeviceName = blackhole.name
                    self?.setAudioDevice(id: blackhole.id, save: false)
                } else if let def = devs.first(where: { $0.is_default }) {
                    self?.selectedDeviceId = def.id
                    self?.selectedDeviceName = def.name
                    self?.setAudioDevice(id: def.id, save: false)
                } else if let first = devs.first {
                    self?.selectedDeviceId = first.id
                    self?.selectedDeviceName = first.name
                    self?.setAudioDevice(id: first.id, save: false)
                }
            }
        }.resume()
    }
    
    func setAudioDevice(id: Int, save: Bool = true) {
        self.selectedDeviceId = id
        if let d = devices.first(where: { $0.id == id }) {
            self.selectedDeviceName = d.name
            if save {
                UserDefaults.standard.set(d.name, forKey: "saved_audio_device_name")
                UserDefaults.standard.set(id, forKey: "saved_audio_device_id")
            }
        }
        sendAction("device", body: ["device_id": id])
    }
    
    func fetchNetworkInfo() {
        guard let url = URL(string: "http://127.0.0.1:8080/api/network_info") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                if let u = json["url"] as? String { self?.serverUrl = u }
            }
        }.resume()
    }
    
    func loadSong(_ song: SongItem, autoPlay: Bool = false) {
        self.undoStack.removeAll()
        self.redoStack.removeAll()
        self.undoNotificationMessage = nil
        self.focusedCueIdx = nil
        self.currentSong = song
        self.isFadingOut = false
        self.isFadedOut = false
        self.isFadingIn = false
        
        // Carrega imediatamente cache local de waveform e cues para transição instantânea sem congelar a tela
        if let savedW = UserDefaults.standard.array(forKey: "saved_waveform_\(song.id)") as? [Double], !savedW.isEmpty {
            self.fullWaveform = savedW
        } else {
            self.fullWaveform = []
        }
        if let localData = UserDefaults.standard.data(forKey: "saved_cues_\(song.id)"),
           var localCues = try? JSONDecoder().decode([CueSection].self, from: localData),
           !localCues.isEmpty {
            for i in 0..<localCues.count {
                if localCues[i].name.caseInsensitiveCompare("Outro") == .orderedSame {
                    localCues[i].name = "Ending"
                }
            }
            self.currentCues = localCues
        }
        
        self.triggerScrollToStart()
        UserDefaults.standard.set(song.id, forKey: "saved_last_loaded_song_id")
        guard let url = URL(string: "http://127.0.0.1:8080/api/load") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["song_id": song.id]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songData = json["song"] as? [String: Any],
                  let cuesRaw = songData["cues"] as? [[String: Any]] else { return }
            
            let cuesData = try? JSONSerialization.data(withJSONObject: cuesRaw)
            var parsedCues = (try? JSONDecoder().decode([CueSection].self, from: cuesData ?? Data())) ?? []
            for i in 0..<parsedCues.count {
                if parsedCues[i].name.caseInsensitiveCompare("Outro") == .orderedSame {
                    parsedCues[i].name = "Ending"
                }
            }
            if parsedCues.isEmpty {
                if let localData = UserDefaults.standard.data(forKey: "saved_cues_\(song.id)"),
                   let localCues = try? JSONDecoder().decode([CueSection].self, from: localData),
                   !localCues.isEmpty {
                    parsedCues = localCues
                }
            } else if let validData = cuesData {
                UserDefaults.standard.set(validData, forKey: "saved_cues_\(song.id)")
                UserDefaults.standard.synchronize()
            }
            let fullW = songData["full_waveform"] as? [Double] ?? []
            let totDur = songData["total_duration"] as? Double ?? (songData["total_seconds"] as? Double ?? 0.0)
            
            DispatchQueue.main.async {
                self?.currentCues = parsedCues
                if totDur > 0 {
                    self?.totalSeconds = totDur
                }
                if !fullW.isEmpty {
                    self?.fullWaveform = fullW
                    UserDefaults.standard.set(fullW, forKey: "saved_waveform_\(song.id)")
                }
                if let b = songData["bpm"] as? Double { self?.bpm = b }
                if let ts = songData["time_signature"] as? String { self?.timeSignature = ts }
                if let hasC = songData["has_cover"] as? Bool {
                    self?.currentSong?.has_cover = hasC
                    self?.currentSong?.cover_url = songData["cover_url"] as? String
                }
                self?.abletonSynced = true
                self?.sendAction("set_guide_lead_in", body: ["bars": self?.guideLeadInBars ?? 1.0])
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    self?.abletonSynced = false
                }
                if autoPlay {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.sendAction("play")
                    }
                }
            }
        }.resume()
    }
    
    // ==========================================
    // CAPAS DE ÁLBUNS / MÚSICAS (APPLE MUSIC & LOCAL)
    // ==========================================
    func openCoverPicker(for song: SongItem) {
        self.coverPickerSong = song
        let cleanQuery = song.search_query ?? cleanSongTitleForSearch(song.name)
        self.coverSearchQuery = cleanQuery
        self.coverSearchResults = []
        self.coverPickerError = nil
        self.isCoverPickerPresented = true
        self.searchCovers(query: cleanQuery)
    }
    
    func searchCovers(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:8080/api/covers/search?q=\(encoded)") else { return }
        
        self.isSearchingCovers = true
        self.coverPickerError = nil
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isSearchingCovers = false
                if let error = error {
                    self?.coverPickerError = "Falha ao buscar: \(error.localizedDescription)"
                    return
                }
                guard let data = data,
                      let results = try? JSONDecoder().decode([CoverSearchResult].self, from: data) else {
                    self?.coverSearchResults = []
                    return
                }
                self?.coverSearchResults = results
            }
        }.resume()
    }
    
    func selectCover(song: SongItem, artworkUrl: String) {
        guard let url = URL(string: "http://127.0.0.1:8080/api/covers/select") else { return }
        self.isSavingCover = true
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "song_id": song.id,
            "artwork_url": artworkUrl
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isSavingCover = false
                guard error == nil else { return }
                
                // Limpa cache de imagem para renderizar imediatamente
                CoverImageCache.shared.remove(for: song.id)
                self?.updateSongCoverState(songId: song.id, hasCover: true)
                self?.isCoverPickerPresented = false
            }
        }.resume()
    }
    
    func chooseCoverFromFile(song: SongItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .jpeg, .png]
        panel.message = "Escolha uma imagem de capa para \(song.name)"
        panel.prompt = "Escolher Capa"
        
        if panel.runModal() == .OK, let fileUrl = panel.url {
            guard let url = URL(string: "http://127.0.0.1:8080/api/covers/upload") else { return }
            self.isSavingCover = true
            
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "song_id": song.id,
                "file_path": fileUrl.path
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                DispatchQueue.main.async {
                    self?.isSavingCover = false
                    guard error == nil else { return }
                    
                    CoverImageCache.shared.remove(for: song.id)
                    self?.updateSongCoverState(songId: song.id, hasCover: true)
                    self?.isCoverPickerPresented = false
                }
            }.resume()
        }
    }
    
    func removeCover(for song: SongItem) {
        guard let url = URL(string: "http://127.0.0.1:8080/api/covers/remove") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["song_id": song.id]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                CoverImageCache.shared.remove(for: song.id)
                self?.updateSongCoverState(songId: song.id, hasCover: false)
            }
        }.resume()
    }
    
    func autoFetchCoversIfNeeded() {
        for item in self.setlist {
            if item.song.has_cover != true {
                self.autoFetchCover(for: item.song)
            }
        }
    }
    
    func autoFetchCover(for song: SongItem) {
        guard !attemptedCoverAutoFetchSongIds.contains(song.id) else { return }
        attemptedCoverAutoFetchSongIds.insert(song.id)
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/covers/auto") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["song_id": song.id]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard error == nil, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? String, status == "ok" else { return }
            
            DispatchQueue.main.async {
                CoverImageCache.shared.remove(for: song.id)
                self?.updateSongCoverState(songId: song.id, hasCover: true)
            }
        }.resume()
    }
    
    func updateSongCoverState(songId: String, hasCover: Bool) {
        let encodedId = songId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? songId
        let coverUrl = hasCover ? "/api/covers?id=\(encodedId)" : nil
        
        for i in 0..<self.setlist.count {
            if self.setlist[i].song.id == songId {
                var s = self.setlist[i].song
                s.has_cover = hasCover
                s.cover_url = coverUrl
                self.setlist[i] = SetlistSong(id: self.setlist[i].id, song: s, transitionType: self.setlist[i].transitionType)
            }
        }
        
        if self.currentSong?.id == songId {
            self.currentSong?.has_cover = hasCover
            self.currentSong?.cover_url = coverUrl
        }
        
        self.coverRefreshTrigger += 1
        self.saveSetlistState()
    }
    
    func openSongEditor(for song: SongItem? = nil) {
        if let s = song, currentSong?.id != s.id {
            loadSong(s, autoPlay: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self = self else { return }
                self.editorBpm = self.bpm
                self.editorTimeSignature = self.timeSignature
                self.editorCues = self.currentCues
                self.isSongEditorPresented = true
            }
            return
        }
        guard currentSong != nil else { return }
        editorBpm = bpm
        editorTimeSignature = timeSignature
        editorCues = currentCues
        isSongEditorPresented = true
    }
    
    func saveSongEditor(bpm: Double, timeSignature: String, cues: [CueSection]) {
        guard let song = currentSong else { return }
        pushUndoSnapshot(description: "Edição no Editor")
        self.bpm = bpm
        self.timeSignature = timeSignature
        self.currentCues = cues
        
        // 1. Salva imediatamente em UserDefaults local para garantir persistência contínua
        let encoder = JSONEncoder()
        if let cuesData = try? encoder.encode(cues) {
            UserDefaults.standard.set(cuesData, forKey: "saved_cues_\(song.id)")
            UserDefaults.standard.synchronize()
        }
        
        // Atualiza a música no setlist se estiver presente
        if let idx = self.setlist.firstIndex(where: { $0.song.id == song.id }) {
            var updatedSong = self.setlist[idx].song
            updatedSong.bpm = bpm
            updatedSong.time_signature = timeSignature
            self.setlist[idx] = SetlistSong(id: self.setlist[idx].id, song: updatedSong, transitionType: self.setlist[idx].transitionType)
            self.saveSetlistState()
        }
        
        // Fecha o editor imediatamente com resposta visual ágil
        self.isSongEditorPresented = false
        
        guard let cuesData = try? encoder.encode(cues),
              let cuesJson = try? JSONSerialization.jsonObject(with: cuesData) as? [[String: Any]] else { return }
        
        let body: [String: Any] = [
            "song_id": song.id,
            "bpm": bpm,
            "time_signature": timeSignature,
            "cues": cuesJson
        ]
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/save_cues") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songData = json["song"] as? [String: Any],
                  let cuesRaw = songData["cues"] as? [[String: Any]] else { return }
            
            let rawData = try? JSONSerialization.data(withJSONObject: cuesRaw)
            guard let updatedCues = try? JSONDecoder().decode([CueSection].self, from: rawData ?? Data()) else { return }
            
            DispatchQueue.main.async {
                guard let self = self, self.currentSong?.id == song.id else { return }
                for (idx, updated) in updatedCues.enumerated() {
                    if idx < self.currentCues.count && self.currentCues[idx].id == updated.id {
                        self.currentCues[idx].waveform = updated.waveform
                    }
                }
            }
        }.resume()
        
        self.isSongEditorPresented = false
    }
    
    func reprocessWithAI() {
        guard let song = currentSong else { return }
        pushUndoSnapshot(description: "Re-análise IA")
        self.isReprocessing = true
        
        let body: [String: Any] = [
            "song_id": song.id,
            "bpm": editorBpm,
            "time_signature": editorTimeSignature
        ]
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/reprocess") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.isReprocessing = false
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let songDict = json["song"] as? [String: Any] else { return }
                
                if let newBpm = songDict["bpm"] as? Double {
                    self?.bpm = newBpm
                    self?.editorBpm = newBpm
                }
                if let newTs = songDict["time_signature"] as? String {
                    self?.timeSignature = newTs
                    self?.editorTimeSignature = newTs
                }
                if let cuesRaw = songDict["cues"],
                   let rawData = try? JSONSerialization.data(withJSONObject: cuesRaw),
                   let newCues = try? JSONDecoder().decode([CueSection].self, from: rawData) {
                    self?.currentCues = newCues
                    self?.editorCues = newCues
                }
            }
        }.resume()
    }
    
    func playPause() {
        if isFadingOut {
            isFadingOut = false
        }
        if isPlaying {
            // Cancelar salto enfileirado ao pausar
            queuedCueIdx = nil
        }
        let action = isPlaying ? "pause" : "play"
        sendAction(action)
    }
    
    // Inicia a música correspondente do Setlist pelo índice (teclas 1 a 8)
    func playSetlistSong(at index: Int) {
        guard index >= 0 && index < setlist.count else { return }
        let target = setlist[index].song
        if isFadingOut { isFadingOut = false }
        queuedCueIdx = nil
        triggerScrollToStart()
        if currentSong?.id == target.id {
            restart()
            if !isPlaying {
                sendAction("play")
            }
        } else {
            loadSong(target, autoPlay: true)
        }
    }
    
    func toggleFadeTracks(duration: Double = 3.0) {
        guard isPlaying else { return }
        let targetDirection = (isFadedOut || isFadingOut) ? "in" : "out"
        if targetDirection == "in" {
            isFadingIn = true
            isFadingOut = false
        } else {
            isFadingOut = true
            isFadingIn = false
        }
        sendAction("fade_tracks", body: ["direction": targetDirection, "duration": duration])
    }
    
    func fadeStop(duration: Double = 3.0) {
        toggleFadeTracks(duration: duration)
    }
    
    func restart() {
        if isFadingOut { isFadingOut = false }
        queuedCueIdx = nil
        focusedCueIdx = nil
        triggerScrollToStart()
        sendAction("seek", body: ["seconds": 0.0])
    }
    
    func seekToSeconds(_ sec: Double) {
        if isFadingOut { isFadingOut = false }
        queuedCueIdx = nil
        sendAction("seek", body: ["seconds": sec])
    }
    
    // Disparo Quantizado: cai no tempo 1 do próximo compasso
    func triggerCue(idx: Int, quantize: Bool = true) {
        if isFadingOut { isFadingOut = false }
        sendAction("trigger_cue", body: ["cue_idx": idx, "quantize": quantize])
    }
    
    func toggleLoop(cueIdx: Int? = nil) {
        var body: [String: Any] = [:]
        if let idx = cueIdx {
            body["cue_idx"] = idx
        }
        sendAction("toggle_loop", body: body)
    }
    
    func togglePad() {
        sendAction("pad", body: ["active": !padActive, "key": padKey, "volume": 0.35])
    }
    
    func sendVolumes() {
        sendAction("volumes", body: [
            "click_vol": clickVol,
            "vs_vol": vsVol,
            "click_mute": clickMute,
            "vs_mute": vsMute
        ])
    }
    
    func toggleClickMute() {
        clickMute.toggle()
        sendVolumes()
    }
    
    func toggleVsMute() {
        vsMute.toggle()
        sendVolumes()
    }
    
    func calculateSecPerBar() -> Double {
        let bpmVal = bpm > 20 ? bpm : 120.0
        let parts = timeSignature.split(separator: "/")
        let beatsPerBar = Double(parts.first ?? "4") ?? 4.0
        return (60.0 / bpmVal) * beatsPerBar
    }
    
    // Métodos para Ajuste Rápido de Duração e Cues via Right-Click (Suporta Meios Compassos / 2/4)
    func calculateDurationBars(for index: Int) -> Double {
        guard index >= 0 && index < currentCues.count else { return 4.0 }
        let curBar = currentCues[index].bar
        if index + 1 < currentCues.count {
            return max(0.5, currentCues[index + 1].bar - curBar)
        } else {
            let secPerBeat = 60.0 / bpm
            let beatsPerBar = Double(timeSignature.split(separator: "/").first ?? "4") ?? 4.0
            let secPerBar = secPerBeat * beatsPerBar
            let totalBars = max(curBar, totalSeconds / secPerBar)
            let rawDuration = totalBars - curBar + 1.0
            return max(0.5, round(rawDuration * 2.0) / 2.0)
        }
    }
    
    func adjustSectionDuration(at index: Int, deltaBars: Double) {
        guard index >= 0 && index < currentCues.count else { return }
        guard index + 1 < currentCues.count else {
            // Último bloco da música: não possui bloco à direita para tomar ou ceder compassos
            return
        }
        
        let curDuration = calculateDurationBars(for: index)
        let nextDuration = calculateDurationBars(for: index + 1)
        
        // Regra: Se for aumentar (+deltaBars), os compassos são tomados APENAS do bloco à direita (index + 1).
        // Limite máximo: o bloco da direita deve ficar com no mínimo 1 compasso de tempo (>= 1.0).
        if deltaBars > 0 {
            if nextDuration - deltaBars < 0.999 { return }
        }
        
        // Se for diminuir (-deltaBars), o bloco atual diminui e o bloco à direita expande para a esquerda.
        // Limite mínimo: o bloco atual deve ficar com no mínimo 1 compasso de tempo (>= 1.0).
        if deltaBars < 0 {
            if curDuration + deltaBars < 0.999 { return }
        }
        
        let deltaStr = deltaBars > 0 ? "+\(formatBars(deltaBars))" : "\(formatBars(deltaBars))"
        pushUndoSnapshot(description: "Ajuste de Compasso (\(deltaStr) comp)")
        
        let secPerBeat = 60.0 / bpm
        let beatsPerBar = Double(timeSignature.split(separator: "/").first ?? "4") ?? 4.0
        let secPerBar = secPerBeat * beatsPerBar
        
        // Desloca APENAS a fronteira do bloco à direita (index + 1).
        // Nenhuma outra seção subsequente (index + 2 em diante) é alterada!
        let newBar = currentCues[index + 1].bar + deltaBars
        currentCues[index + 1].bar = newBar
        currentCues[index + 1].time = round(Double(newBar - 1.0) * secPerBar * 100) / 100
        
        saveCurrentCues()
    }
    
    func changeSectionType(at index: Int, newType: String) {
        guard index >= 0 && index < currentCues.count else { return }
        let oldName = currentCues[index].name
        if oldName == newType { return }
        pushUndoSnapshot(description: "Tipo de Seção (\(newType))")
        currentCues[index].name = newType
        currentCues[index].color = colorForCue(name: newType)
        saveCurrentCues()
    }
    
    func splitSection(at index: Int) {
        guard index >= 0 && index < currentCues.count else { return }
        let cur = currentCues[index]
        pushUndoSnapshot(description: "Divisão de Seção (\(cur.cleanFullName))")
        let totalBars = calculateDurationBars(for: index)
        
        let secPerBeat = 60.0 / bpm
        let beatsPerBar = Double(timeSignature.split(separator: "/").first ?? "4") ?? 4.0
        let secPerBar = secPerBeat * beatsPerBar
        
        // Divide os compassos ao meio com precisão de meio compasso
        let firstHalfBars = max(0.5, round((totalBars / 2.0) * 2.0) / 2.0)
        let splitBar = cur.bar + firstHalfBars
        let splitTime = round(Double(splitBar - 1.0) * secPerBar * 100) / 100
        
        // Divide os picos de forma de onda do Canal R
        var firstWaveform: [Double]? = nil
        var secondWaveform: [Double]? = nil
        if let wf = cur.waveform, wf.count >= 4 {
            let mid = wf.count / 2
            firstWaveform = Array(wf[0..<mid])
            secondWaveform = Array(wf[mid..<wf.count])
        }
        
        currentCues[index].waveform = firstWaveform
        
        let newId = "cue_\(UUID().uuidString.prefix(6))"
        let newSection = CueSection(
            id: newId,
            name: cur.name,
            time: splitTime,
            bar: splitBar,
            color: cur.color,
            waveform: secondWaveform
        )
        
        currentCues.insert(newSection, at: index + 1)
        quickEditingCueIdx = nil
        saveCurrentCues()
    }
    
    func deleteSection(at index: Int) {
        guard currentCues.count > 1, index >= 0 && index < currentCues.count else { return }
        let cur = currentCues[index]
        pushUndoSnapshot(description: "Exclusão de Seção (\(cur.cleanFullName))")
        currentCues.remove(at: index)
        if index == 0 && !currentCues.isEmpty {
            currentCues[0].bar = 1.0
            currentCues[0].time = 0.0
        }
        quickEditingCueIdx = nil
        saveCurrentCues()
    }
    
    func saveCurrentCues() {
        guard let song = currentSong else { return }
        let encoder = JSONEncoder()
        
        // 1. Salva imediatamente em UserDefaults local para garantir que nunca se perca
        if let cuesData = try? encoder.encode(currentCues) {
            UserDefaults.standard.set(cuesData, forKey: "saved_cues_\(song.id)")
            UserDefaults.standard.synchronize()
        }
        
        guard let cuesData = try? encoder.encode(currentCues),
              let cuesJson = try? JSONSerialization.jsonObject(with: cuesData) as? [[String: Any]] else { return }
        
        let body: [String: Any] = [
            "song_id": song.id,
            "bpm": bpm,
            "time_signature": timeSignature,
            "cues": cuesJson
        ]
        
        guard let url = URL(string: "http://127.0.0.1:8080/api/save_cues") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let songData = json["song"] as? [String: Any],
                  let cuesRaw = songData["cues"] as? [[String: Any]] else { return }
            
            let rawData = try? JSONSerialization.data(withJSONObject: cuesRaw)
            guard let updatedCues = try? JSONDecoder().decode([CueSection].self, from: rawData ?? Data()) else { return }
            
            DispatchQueue.main.async {
                guard let self = self, self.currentSong?.id == song.id else { return }
                for (idx, updated) in updatedCues.enumerated() {
                    if idx < self.currentCues.count && self.currentCues[idx].id == updated.id {
                        self.currentCues[idx].waveform = updated.waveform
                    }
                }
            }
        }.resume()
    }
    
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    
    func pushUndoSnapshot(description: String = "Edição") {
        let snapshot = CueHistorySnapshot(
            cues: self.currentCues,
            bpm: self.bpm,
            timeSignature: self.timeSignature,
            description: description
        )
        undoStack.append(snapshot)
        if undoStack.count > 50 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
    
    func undo() {
        guard let previous = undoStack.popLast() else {
            showUndoFeedback("Nada para desfazer")
            return
        }
        let currentSnapshot = CueHistorySnapshot(
            cues: self.currentCues,
            bpm: self.bpm,
            timeSignature: self.timeSignature,
            description: previous.description
        )
        redoStack.append(currentSnapshot)
        self.currentCues = previous.cues
        self.bpm = previous.bpm
        self.timeSignature = previous.timeSignature
        self.quickEditingCueIdx = nil
        if self.currentCueIdx >= self.currentCues.count {
            self.currentCueIdx = max(0, self.currentCues.count - 1)
        }
        saveCurrentCues()
        showUndoFeedback("Desfeito: \(previous.description)")
    }
    
    func redo() {
        guard let next = redoStack.popLast() else {
            showUndoFeedback("Nada para refazer")
            return
        }
        let currentSnapshot = CueHistorySnapshot(
            cues: self.currentCues,
            bpm: self.bpm,
            timeSignature: self.timeSignature,
            description: next.description
        )
        undoStack.append(currentSnapshot)
        self.currentCues = next.cues
        self.bpm = next.bpm
        self.timeSignature = next.timeSignature
        self.quickEditingCueIdx = nil
        if self.currentCueIdx >= self.currentCues.count {
            self.currentCueIdx = max(0, self.currentCues.count - 1)
        }
        saveCurrentCues()
        showUndoFeedback("Refeito: \(next.description)")
    }
    
    func showUndoFeedback(_ message: String) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                self.undoNotificationMessage = message
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.undoNotificationMessage == message {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self?.undoNotificationMessage = nil
                }
            }
        }
    }
    
    func removeSetlistSong(at index: Int) {
        guard index >= 0 && index < setlist.count else { return }
        _ = withAnimation(.easeInOut(duration: 0.2)) {
            setlist.remove(at: index)
        }
    }
    
    private func sendAction(_ endpoint: String, body: [String: Any]? = nil) {
        guard let url = URL(string: "http://127.0.0.1:8080/api/\(endpoint)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req).resume()
    }
}

// ==========================================
// 3. DROP DELEGATE PARA ARRASTAR MÚSICAS DO SETLIST
// ==========================================

struct SetlistDropDelegate: DropDelegate {
    let item: SetlistSong
    @ObservedObject var state: PlaybackState
    
    func performDrop(info: DropInfo) -> Bool {
        state.draggedSetlistSong = nil
        state.saveSetlistState()
        return true
    }
    
    func dropEntered(info: DropInfo) {
        guard state.isEditMode,
              let dragged = state.draggedSetlistSong,
              dragged.id != item.id,
              let from = state.setlist.firstIndex(where: { $0.id == dragged.id }),
              let to = state.setlist.firstIndex(where: { $0.id == item.id }) else { return }
        
        withAnimation(.easeInOut(duration: 0.25)) {
            state.setlist.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
}

// ==========================================
// 4. VIEW PRINCIPAL (SWIFTUI)
// ==========================================

struct PlaybackAppView: View {
    @ObservedObject var state: PlaybackState = PlaybackState.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Bar com Botão EDIT, Métricas e Transporte
            TopBarView(state: state)
            
            Divider().background(Color.white.opacity(0.08))
            
            // 2. Carrossel Reordenável por Arraste (Drag-and-Drop)
            SetlistCarouselView(state: state)
            
            Divider().background(Color.white.opacity(0.08))
            
            // 3. Espectrograma Real & Blocos de Seções Quantizados
            SpectrogramWaveformView(state: state)
            
            Divider().background(Color.white.opacity(0.08))
            
            // 4. Mixer Dock com Seletor de Saída de Áudio Dinâmico
            BottomMixerDock(state: state)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .edgesIgnoringSafeArea(.all)
        .sheet(isPresented: $state.isAddSongSheetPresented) {
            AddSongSheetView(state: state)
        }
        .sheet(isPresented: $state.isQrModalPresented) {
            QrCodeSheetView(state: state)
        }
        .sheet(isPresented: $state.isSongEditorPresented) {
            SongEditorSheetView(state: state)
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if let window = NSApp.keyWindow,
                   let responder = window.firstResponder,
                   (responder is NSTextView || responder is NSTextField || responder is NSText) {
                    return event
                }
                // Atalho Cmd+Q: Fecha o app imediatamente
                if event.modifierFlags.contains(.command) && (event.charactersIgnoringModifiers == "q" || event.keyCode == 12) {
                    NSApp.terminate(nil)
                    return nil
                }
                // Atalho Cmd+W: Fecha a janela
                if event.modifierFlags.contains(.command) && (event.charactersIgnoringModifiers == "w" || event.keyCode == 13) {
                    NSApp.keyWindow?.performClose(nil)
                    return nil
                }
                
                // Atalho Cmd+Z / Cmd+Shift+Z (Desfazer / Refazer)
                let isZ = event.keyCode == 6 || event.charactersIgnoringModifiers?.lowercased() == "z"
                if event.modifierFlags.contains(.command) && isZ {
                    if state.isSongEditorPresented {
                        NotificationCenter.default.post(name: NSNotification.Name("SongEditorUndo"), object: nil)
                        return nil
                    } else if !state.isAddSongSheetPresented && !state.isQrModalPresented {
                        if event.modifierFlags.contains(.shift) {
                            state.redo()
                        } else {
                            state.undo()
                        }
                        return nil
                    }
                }
                
                // Se algum modal ou popover estiver aberto, não processa atalhos globais de playback
                if state.isAddSongSheetPresented || state.isQrModalPresented || state.isSongEditorPresented || state.quickEditingCueIdx != nil {
                    return event
                }
                if event.keyCode == 49 { // 49 = Barra de Espaço
                    state.playPause()
                    return nil
                }
                
                // Navegação pelos Blocos de Seções com as Setas do Teclado (Esquerda / Direita)
                // Exibe o cursor de foco em branco translúcido sem alterar a reprodução de imediato
                if event.keyCode == 123 { // Seta para Esquerda (←)
                    if !state.currentCues.isEmpty {
                        let curIdx: Int = {
                            if let f = state.focusedCueIdx { return f }
                            if let q = state.queuedCueIdx { return q }
                            return state.currentCueIdx
                        }()
                        let prevIdx = max(0, curIdx - 1)
                        state.focusedCueIdx = prevIdx
                    }
                    return nil
                }
                
                if event.keyCode == 124 { // Seta para Direita (→)
                    if !state.currentCues.isEmpty {
                        let curIdx: Int = {
                            if let f = state.focusedCueIdx { return f }
                            if let q = state.queuedCueIdx { return q }
                            return state.currentCueIdx
                        }()
                        let nextIdx = min(state.currentCues.count - 1, curIdx + 1)
                        state.focusedCueIdx = nextIdx
                    }
                    return nil
                }
                
                // Tecla Enter / Return: Alterna a seleção do bloco (Laranja <-> Branco)
                if event.keyCode == 36 || event.keyCode == 76 { // 36 = Return, 76 = Enter (Keypad)
                    let targetIdxOpt = state.focusedCueIdx ?? state.queuedCueIdx
                    if let targetIdx = targetIdxOpt {
                        if state.isPlaying {
                            if targetIdx == state.currentCueIdx {
                                // Se estiver no trecho que já está tocando: cancela qualquer fila pendente
                                if state.queuedCueIdx != nil {
                                    state.triggerCue(idx: targetIdx, quantize: true)
                                    state.queuedCueIdx = nil
                                }
                                state.focusedCueIdx = targetIdx
                            } else if state.queuedCueIdx == targetIdx {
                                // SEGUNDO ENTER: O bloco já estava laranja (enfileirado), remove a seleção e volta a ficar branco!
                                state.triggerCue(idx: targetIdx, quantize: true)
                                state.queuedCueIdx = nil
                                state.focusedCueIdx = targetIdx
                            } else {
                                // PRIMEIRO ENTER: Agenda o salto quantizado no tempo 1 do próximo compasso (fica laranja)
                                state.triggerCue(idx: targetIdx, quantize: true)
                                state.queuedCueIdx = targetIdx
                                state.focusedCueIdx = targetIdx
                            }
                        } else {
                            // Quando parado: busca para o início exato da seção
                            state.seekToSeconds(state.currentCues[targetIdx].time)
                            state.triggerCue(idx: targetIdx, quantize: false)
                            state.focusedCueIdx = targetIdx
                        }
                        return nil
                    }
                }
                
                // Tecla Escape: Cancela a pré-visualização de foco ou desfaz a fila
                if event.keyCode == 53 { // 53 = Escape
                    if state.focusedCueIdx != nil {
                        state.focusedCueIdx = nil
                        return nil
                    }
                    if state.queuedCueIdx != nil {
                        state.queuedCueIdx = nil
                        return nil
                    }
                }
                
                // Atalhos Numéricos e Letras (sem teclas modificadoras como Cmd/Opt/Ctrl)
                if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                    let char = event.charactersIgnoringModifiers ?? ""
                    
                    // Tecla L: Alterna o modo Loop da seção focada ou da seção atual
                    if char.lowercased() == "l" || event.keyCode == 37 {
                        if let focusedIdx = state.focusedCueIdx {
                            state.toggleLoop(cueIdx: focusedIdx)
                        } else {
                            state.toggleLoop()
                        }
                        return nil
                    }
                    
                    // Tecla 0: Dispara o Fade Out / Fade In de 3 segundos nas Tracks
                    if char == "0" || event.keyCode == 29 || event.keyCode == 82 {
                        state.toggleFadeTracks(duration: 3.0)
                        return nil
                    }
                    
                    // Teclas 1 a 8: Inicia as músicas 1 a 8 do Setlist
                    let songMap: [String: Int] = [
                        "1": 0, "2": 1, "3": 2, "4": 3,
                        "5": 4, "6": 5, "7": 6, "8": 7
                    ]
                    if let index = songMap[char] {
                        state.playSetlistSong(at: index)
                        return nil
                    }
                    
                    // Fallback por keyCode (teclado numérico ou superior)
                    let keyCodeMap: [UInt16: Int] = [
                        18: 0, 83: 0, // 1
                        19: 1, 84: 1, // 2
                        20: 2, 85: 2, // 3
                        21: 3, 86: 3, // 4
                        23: 4, 87: 4, // 5
                        22: 5, 88: 5, // 6
                        26: 6, 89: 6, // 7
                        28: 7, 91: 7  // 8
                    ]
                    if let index = keyCodeMap[event.keyCode] {
                        state.playSetlistSong(at: index)
                        return nil
                    }
                }
                return event
            }
        }
    }
}

// ==========================================
// 5. TOP BAR (TRANSPORTE & EDIT BUTTON)
// ==========================================

// Ícone de Curva Suave de Fade Out / Fade In (Estilo DAW / MultiTracks)
struct FadeOutCurveIcon: View {
    var color: Color = .white
    var isFading: Bool = false
    var isFlipped: Bool = false
    
    var body: some View {
        FadeOutCurveShape()
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .scaleEffect(x: isFlipped ? -1 : 1, y: 1)
            .animation(.easeInOut(duration: 0.25), value: isFlipped)
            .frame(width: 17, height: 16)
    }
}

struct FadeOutCurveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let padX: CGFloat = 1.0
        let padY: CGFloat = 1.0
        let left = rect.minX + padX
        let right = rect.maxX - padX
        let top = rect.minY + padY
        let bottom = rect.maxY - padY
        
        path.move(to: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: left, y: top),
            control: CGPoint(x: left + (right - left) * 0.40, y: bottom - (bottom - top) * 0.15)
        )
        path.closeSubpath()
        return path
    }
}

struct WindowTitlebarDragView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragNSView { WindowDragNSView() }
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {}
    
    class WindowDragNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct TopBarView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 0) {
            // Linha 1: Barra de Título Nativa Customizada (Alinhada perfeitamente na mesma linha horizontal dos botões de fechar/minimizar/expandir do macOS)
            HStack {
                Spacer()
                Text(state.currentSetlistName.isEmpty ? "VS Control" : state.currentSetlistName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 80)
            .frame(height: 32)
            .background(WindowTitlebarDragView())
            
            // Linha 2: Métricas, Controles Centrais de Transporte e Remote
            ZStack {
                // Camada 1: Laterais (Esquerda: Métricas + Clock; Direita: Botão EDIT / DONE ao lado do Remote)
                HStack(spacing: 20) {
                    // Métricas (BPM com decimal e Compasso)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatBpm(state.bpm))
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                        Text(state.timeSignature)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(Color.gray)
                    }
                    .frame(minWidth: 48, alignment: .leading)
                    
                    // Clock Principal (Sem contador duplicado)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(formatTime(state.currentSeconds))
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Text("/ \(formatTime(state.totalSeconds))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    // Área Direita: Botão EDIT / DONE ao lado do Botão Remote Celular (QR)
                    HStack(spacing: 10) {
                        // Botão EDIT / DONE (ao lado do remote)
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                state.isEditMode.toggle()
                            }
                        }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(state.isEditMode ? Color.yellow.opacity(0.22) : Color.white.opacity(0.06))
                                    .frame(width: 36, height: 36)
                                Text(state.isEditMode ? "DONE" : "EDIT")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundColor(state.isEditMode ? Color.yellow : Color.white.opacity(0.75))
                            }
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(state.isEditMode ? Color.yellow.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(state.isEditMode ? "Finish editing setlist" : "Reorder and remove songs from setlist")
                        
                        // Botão Remote Celular (QR) sóbrio com mesmo padrão dos botões centrais
                        Button(action: { state.isQrModalPresented = true }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(state.isQrModalPresented ? Color.white.opacity(0.18) : Color.white.opacity(0.06))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "iphone")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(state.isQrModalPresented ? Color.white : Color.white.opacity(0.75))
                            }
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(state.isQrModalPresented ? Color.white.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Connect smartphone remote control via QR Code")
                    }
                }
                
                // Camada 2: 5 Botões de Transporte Perfeitamente Centralizados na Janela
                HStack(spacing: 10) {
                    // 1. Botão AUTO (Auto-Advance do Setlist) - colocado à esquerda do botão retroceder
                    Button(action: { state.autoAdvance.toggle() }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(state.autoAdvance ? Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.22) : Color.white.opacity(0.06))
                                .frame(width: 36, height: 36)
                            Text("AUTO")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(state.autoAdvance ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color.white.opacity(0.55))
                        }
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(state.autoAdvance ? Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.5) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Auto-Advance: automatically play next track when current song finishes")
                    
                    // 2. Botão Retroceder / Restart (Branco)
                    Button(action: { state.restart() }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 36, height: 36)
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .frame(width: 36, height: 36)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Restart song from beginning")
                    
                    // 3. Botão Play / Pause
                    Button(action: { state.playPause() }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(state.isPlaying ? Color(red: 0.19, green: 0.82, blue: 0.60).opacity(0.25) : Color.white.opacity(0.06))
                                .frame(width: 36, height: 36)
                            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(Color(red: 0.19, green: 0.82, blue: 0.60))
                        }
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(state.isPlaying ? Color(red: 0.19, green: 0.82, blue: 0.60).opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play / Pause [Espaço]")
                    
                    // 4. Botão FADE TRACKS com Ícone de Curva DAW (Inverte para Fade In quando atenuado)
                    let isFadeActive = state.isFadingOut || state.isFadedOut || state.isFadingIn
                    let isInverted = state.isFadedOut || state.isFadingIn
                    Button(action: { state.toggleFadeTracks(duration: 3.0) }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isFadeActive ? Color.orange.opacity(0.28) : Color.white.opacity(0.06))
                                .frame(width: 36, height: 36)
                            FadeOutCurveIcon(
                                color: isFadeActive ? Color.orange : (state.isPlaying ? Color.white : Color.white.opacity(0.40)),
                                isFading: state.isFadingOut || state.isFadingIn,
                                isFlipped: isInverted
                            )
                        }
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isFadeActive ? Color.orange.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(!state.isPlaying && !isFadeActive)
                    .help(isInverted ? "Fade In Tracks (3s) [Atalho: Tecla 0]" : "Fade Out Tracks (3s) [Atalho: Tecla 0]")
                    
                    // 5. Botão Loop da Seção Atual
                    Button(action: { state.toggleLoop() }) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(state.loopActive ? Color.cyan.opacity(0.28) : Color.white.opacity(0.06))
                                .frame(width: 36, height: 36)
                            Image(systemName: "repeat")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(state.loopActive ? Color.cyan : Color.white.opacity(0.65))
                        }
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(state.loopActive ? Color.cyan.opacity(0.6) : Color.white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Loop current section (L)")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 12)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }
    
    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// ==========================================
// 6. SETLIST CAROUSEL COM DRAG-AND-DROP E EXCLUSÃO EM EDIT MODE
// ==========================================
struct SetlistCarouselView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(state.setlist.enumerated()), id: \.element.id) { index, item in
                        let isSelected = state.currentSong?.id == item.song.id
                        
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .topTrailing) {
                                // Card da Música com Capa do Álbum
                                Button(action: {
                                    if !state.isEditMode {
                                        state.loadSong(item.song)
                                    }
                                }) {
                                    SongCoverView(
                                        song: item.song,
                                        width: 160,
                                        height: 88,
                                        cornerRadius: 10,
                                        isSelected: isSelected,
                                        refreshId: state.coverRefreshTrigger
                                    )
                                }
                                .buttonStyle(PlainButtonStyle())
                                .frame(width: 160, height: 88)
                                .contextMenu {
                                    Button(action: {
                                        state.openCoverPicker(for: item.song)
                                    }) {
                                        Label("Buscar / Alterar Capa...", systemImage: "photo.badge.plus")
                                    }
                                    
                                    if item.song.has_cover == true {
                                        Button(role: .destructive, action: {
                                            state.removeCover(for: item.song)
                                        }) {
                                            Label("Remover Capa", systemImage: "trash")
                                        }
                                    }
                                    
                                    Divider()
                                    
                                    Button(action: {
                                        state.openSongEditor(for: item.song)
                                    }) {
                                        Label("Edit Song", systemImage: "slider.horizontal.3")
                                    }
                                    
                                    Divider()
                                    
                                    Button(action: {
                                        state.playSetlistSong(at: index)
                                    }) {
                                        Label("Play Now", systemImage: "play.fill")
                                    }
                                    
                                    Button(role: .destructive, action: {
                                        state.removeSetlistSong(at: index)
                                    }) {
                                        Label("Remove from Setlist", systemImage: "trash")
                                    }
                                }
                                .onDrag {
                                    guard state.isEditMode else { return NSItemProvider() }
                                    state.draggedSetlistSong = item
                                    return NSItemProvider(object: item.id.uuidString as NSString)
                                }
                                .onDrop(of: [UTType.text], delegate: SetlistDropDelegate(item: item, state: state))
                                
                                // Botão Excluir (✕) - VISÍVEL APENAS EM EDIT MODE
                                if state.isEditMode {
                                    Button(action: { state.removeSetlistSong(at: index) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundColor(Color.red)
                                            .background(Color.white.clipShape(Circle()))
                                            .padding(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                            .frame(width: 160, height: 88)
                            
                            // Info da Música Embaixo (Apenas o Nome da Música)
                            HStack(alignment: .center, spacing: 4) {
                                if isSelected {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(Color(red: 0.2, green: 0.9, blue: 0.5))
                                }
                                
                                Text(item.song.name)
                                    .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: 160, alignment: .leading)
                        }
                        .opacity(isSelected ? 1.0 : 0.7)
                        .animation(.easeInOut(duration: 0.2), value: isSelected)
                        
                        // Seta de Transição (Clica para alternar AUTO / STOP)
                        if index < state.setlist.count - 1 {
                            Button(action: {
                                state.toggleTransition(at: index)
                            }) {
                                Circle()
                                    .fill(Color(red: 0.16, green: 0.16, blue: 0.18))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Image(systemName: item.transitionType == "AUTO" ? "arrow.right" : "pause.fill")
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(item.transitionType == "AUTO" ? .white : Color.gray)
                                    )
                                    .overlay(
                                        Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .offset(y: 32)
                            .help(item.transitionType == "AUTO" ? "Auto-transition to next track" : "Stop after this track")
                        }
                    }
                    
                    // Card "Add a Song" no mesmo formato e tamanho das músicas (adicionando ao lado)
                    Button(action: { state.isAddSongSheetPresented = true }) {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.85))
                                    .frame(width: 160, height: 88)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.20), lineWidth: 1.2)
                                    )
                                
                                VStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .light))
                                        .foregroundColor(.white)
                                    Text("Add a Song")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(width: 160, height: 88)
                            
                            Text("")
                                .font(.system(size: 11))
                                .frame(width: 160, height: 16)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Add a song to setlist")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.10))
        .sheet(isPresented: $state.isCoverPickerPresented) {
            CoverPickerSheetView(state: state)
        }
    }
}

// ==========================================
// 6.1 MODAL DE BUSCA DE CAPAS DE ÁLBUM (APPLE MUSIC & LOCAL)
// ==========================================
struct CoverPickerSheetView: View {
    @ObservedObject var state: PlaybackState
    @Environment(\.presentationMode) var presentationMode
    @State private var queryText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.cyan)
                        Text("Buscar Capa do Álbum")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    if let song = state.coverPickerSong {
                        Text(song.name)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                if let song = state.coverPickerSong {
                    Button(action: { state.chooseCoverFromFile(song: song) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11, weight: .bold))
                            Text("Escolher do Mac...")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Escolher arquivo de imagem do computador")
                    
                    if song.has_cover == true {
                        Button(action: {
                            state.removeCover(for: song)
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Remover")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundColor(.red.opacity(0.9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.12))
                            .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Remover capa atribuída")
                    }
                }
                
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(18)
            .background(Color(red: 0.12, green: 0.12, blue: 0.14))
            
            Divider().background(Color.white.opacity(0.1))
            
            // Search Bar
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.gray)
                        .font(.system(size: 13))
                    
                    TextField("Digite o nome da música, artista ou álbum...", text: $queryText, onCommit: {
                        state.searchCovers(query: queryText)
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    
                    if !queryText.isEmpty {
                        Button(action: { queryText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.gray)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.35))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15), lineWidth: 1))
                
                Button(action: {
                    state.searchCovers(query: queryText)
                }) {
                    HStack(spacing: 6) {
                        if state.isSearchingCovers {
                            ProgressView().scaleEffect(0.7).colorInvert()
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                        }
                        Text("Buscar")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.cyan)
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(state.isSearchingCovers || queryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(red: 0.10, green: 0.10, blue: 0.12))
            
            Divider().background(Color.white.opacity(0.08))
            
            // Results Grid
            ZStack {
                if state.isSearchingCovers {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Buscando versões e capas na Apple Music...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.isSavingCover {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Otimizando e salvando capa (300x300 JPEG leve)...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.cyan)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = state.coverPickerError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                        Button("Tentar Novamente") {
                            state.searchCovers(query: queryText)
                        }
                        .foregroundColor(.cyan)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.coverSearchResults.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.gray.opacity(0.4))
                        Text("Nenhum resultado para esta busca.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.gray)
                        Text("Tente digitar o nome do artista ou versão (ex: 'Bondade de Deus Isaias Saad')")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 165), spacing: 14)], spacing: 14) {
                            ForEach(state.coverSearchResults) { item in
                                CoverResultCard(item: item) {
                                    if let song = state.coverPickerSong {
                                        state.selectCover(song: song, artworkUrl: item.artwork_url)
                                    }
                                }
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        }
        .frame(width: 720, height: 520)
        .onAppear {
            queryText = state.coverSearchQuery
        }
    }
}

struct CoverResultCard: View {
    let item: CoverSearchResult
    let onSelect: () -> Void
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let url = URL(string: item.artwork_url_small) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 140, height: 140)
                                    .clipped()
                            case .failure(_):
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.2))
                                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
                            default:
                                ProgressView().scaleEffect(0.7)
                            }
                        }
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovered ? Color.cyan : Color.white.opacity(0.12), lineWidth: isHovered ? 2 : 1)
                )
                .shadow(color: isHovered ? Color.cyan.opacity(0.35) : Color.clear, radius: 6)
                
                Text(item.track_name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Text(item.artist_name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                if !item.year.isEmpty {
                    Text(item.year)
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 140)
            .padding(6)
            .background(isHovered ? Color.white.opacity(0.06) : Color.clear)
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { isHovered = $0 }
    }
}

// ==========================================
// 7. CONTROLADOR E HOOK DE SCROLL HORIZONTAL (ARRASTE COM MOUSE, RODA, TRACKPAD)
// ==========================================

class WaveformScrollController {
    static let shared = WaveformScrollController()
    weak var scrollView: NSScrollView?
    var dragStartOriginX: CGFloat = 0
    var isDragging: Bool = false
    
    func getScrollView() -> NSScrollView? {
        if let sv = scrollView { return sv }
        if let win = NSApp.keyWindow ?? NSApp.windows.first {
            func findSV(in view: NSView) -> NSScrollView? {
                if let sv = view as? NSScrollView { return sv }
                for sub in view.subviews {
                    if let found = findSV(in: sub) { return found }
                }
                return nil
            }
            if let root = win.contentView {
                if let found = findSV(in: root) {
                    self.scrollView = found
                    return found
                }
            }
        }
        return nil
    }
    
    func onDragChanged(translationX: CGFloat) {
        guard let sv = getScrollView() else { return }
        if !isDragging {
            isDragging = true
            dragStartOriginX = sv.contentView.bounds.origin.x
            NSCursor.closedHand.push()
        }
        let clip = sv.contentView
        let docWidth = sv.documentView?.frame.width ?? 0
        let maxOffsetX = max(0, docWidth - clip.bounds.width)
        guard maxOffsetX > 0 else { return }
        
        let targetX = max(0, min(maxOffsetX, dragStartOriginX - translationX))
        var origin = clip.bounds.origin
        origin.x = targetX
        clip.scroll(to: origin)
        sv.reflectScrolledClipView(clip)
    }
    
    func onDragEnded() {
        if isDragging {
            NSCursor.pop()
            isDragging = false
        }
    }
}

struct WaveformMouseTrackingView: NSViewRepresentable {
    func makeNSView(context: Context) -> WaveformTrackingNSView { WaveformTrackingNSView() }
    func updateNSView(_ nsView: WaveformTrackingNSView, context: Context) {}
    
    class WaveformTrackingNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

struct HorizontalScrollWheelHook: NSViewRepresentable {
    var onUserScrolled: (() -> Void)? = nil
    var resetTrigger: Int = 0
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> HorizontalScrollNSView {
        let view = HorizontalScrollNSView()
        view.onUserScrolled = onUserScrolled
        return view
    }
    
    func updateNSView(_ nsView: HorizontalScrollNSView, context: Context) {
        nsView.onUserScrolled = onUserScrolled
        if context.coordinator.lastResetTrigger != resetTrigger {
            context.coordinator.lastResetTrigger = resetTrigger
            nsView.scrollToStart()
        }
    }
    
    class Coordinator {
        var lastResetTrigger: Int = 0
    }
}

class HorizontalScrollNSView: NSView {
    weak var targetScrollView: NSScrollView?
    var monitor: Any?
    var onUserScrolled: (() -> Void)?
    
    override var mouseDownCanMoveWindow: Bool { false }
    
    func scrollToStart() {
        if targetScrollView == nil {
            findScrollView()
        }
        guard let sv = targetScrollView else { return }
        let clipView = sv.contentView
        var origin = clipView.bounds.origin
        origin.x = 0
        clipView.scroll(to: origin)
        sv.reflectScrolledClipView(clipView)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            findScrollView()
            DispatchQueue.main.async { [weak self] in
                self?.findScrollView()
            }
            setupMonitor()
        } else {
            removeMonitor()
        }
    }
    
    func findScrollView() {
        var current: NSView? = self
        while let parent = current?.superview {
            if let sv = parent as? NSScrollView {
                self.targetScrollView = sv
                sv.hasHorizontalScroller = false
                sv.horizontalScroller = nil
                WaveformScrollController.shared.scrollView = sv
                return
            }
            current = parent
        }
    }
    
    func setupMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self = self, let window = self.window, event.window == window else {
                return event
            }
            if self.targetScrollView == nil {
                self.findScrollView()
            }
            guard let sv = self.targetScrollView else { return event }
            
            let mouseInWindow = event.locationInWindow
            let mouseInSV = sv.convert(mouseInWindow, from: nil)
            let isInsideSV = sv.bounds.contains(mouseInSV)
            
            // Roda do Mouse e Trackpad
            if event.type == .scrollWheel && isInsideSV {
                let deltaY = event.scrollingDeltaY
                let deltaX = event.scrollingDeltaX
                
                var horizontalDelta: CGFloat = 0.0
                if abs(deltaX) > 0.001 {
                    horizontalDelta = deltaX
                } else if abs(deltaY) > 0.001 {
                    horizontalDelta = deltaY
                }
                
                if abs(horizontalDelta) > 0.001 {
                    let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 22.0
                    let shift = -horizontalDelta * factor
                    
                    let clipView = sv.contentView
                    var newOrigin = clipView.bounds.origin
                    let docWidth = sv.documentView?.frame.width ?? 0
                    let maxOffsetX = max(0, docWidth - clipView.bounds.width)
                    
                    if maxOffsetX > 0 {
                        newOrigin.x = max(0, min(maxOffsetX, newOrigin.x + shift))
                        clipView.scroll(to: newOrigin)
                        sv.reflectScrolledClipView(clipView)
                        
                        DispatchQueue.main.async {
                            self.onUserScrolled?()
                        }
                        return nil // Evento consumido
                    }
                }
            }
            return event
        }
    }
    
    func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
    
    deinit {
        removeMonitor()
    }
}

// ==========================================
// 8. ESPECTROGRAMA & SEÇÕES COM SALTO QUANTIZADO (TEMPO 1)
// ==========================================
struct SpectrogramWaveformView: View {
    @ObservedObject var state: PlaybackState
    @State private var lastUserScrollTime: Date = .distantPast
    
    var body: some View {
        GeometryReader { geo in
            let totalAvailableWidth = geo.size.width - 40
            let scale = calculateScale(totalAvailableWidth: totalAvailableWidth)
            let totalTrackWidth = max(totalAvailableWidth, CGFloat(max(1.0, state.totalSeconds)) * scale)
            let blockWidths = calculateBlockWidths(scale: scale, totalTrackWidth: totalTrackWidth)
            let playheadX = CGFloat(max(0.0, state.currentSeconds)) * scale
            
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .leading) {
                        // Hook de Rolagem com Rodinha do Mouse e Trackpad
                        HorizontalScrollWheelHook(
                            onUserScrolled: {
                                lastUserScrollTime = Date()
                            },
                            resetTrigger: state.scrollToStartTrigger
                        )
                        .frame(width: 1, height: 1)
                        
                        if state.currentCues.isEmpty {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                                Text("Loading audio tracks and cue sections...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .frame(minWidth: totalAvailableWidth, maxHeight: .infinity)
                        } else {
                            // 1. Fundo Geral Estático & Onda Contínua Global (Acelerado por GPU Metal via .drawingGroup & Equatable)
                            WaveformStaticBackgroundView(
                                songId: state.currentSong?.id ?? "",
                                peaks: state.displayFullWaveform,
                                totalTrackWidth: totalTrackWidth
                            )
                            .equatable()
                            .id("\(state.currentSong?.id ?? "none")_\(state.displayFullWaveform.count)")
                            
                            // 2. CAMADA DE SEÇÕES SOBREPOSTAS (Divisões e Ações por Cima da Onda)
                            HStack(spacing: 0) {
                                ForEach(Array(state.currentCues.enumerated()), id: \.element.id) { idx, section in
                                    sectionItemView(idx: idx, section: section, blockWidths: blockWidths, proxy: proxy)
                                }
                            }
                            .frame(width: totalTrackWidth, height: 175)
                            
                            // 5. LINHAS DIVISÓRIAS VERTICAIS ENTRE TODOS OS TRECHOS (Alinhadas perfeitamente com os cartões)
                            let dividerPositions = calculateDividerPositions(blockWidths: blockWidths)
                            ZStack(alignment: .leading) {
                                ForEach(Array(dividerPositions.enumerated()), id: \.offset) { _, xPos in
                                    Rectangle()
                                        .fill(Color.white.opacity(0.42))
                                        .frame(width: 1.5, height: 171)
                                        .position(x: xPos, y: 175 / 2)
                                }
                            }
                            .frame(width: totalTrackWidth, height: 175)
                            
                            // 6. PLAYHEAD VERMELHO ALINHADO COM PRECISÃO
                            if state.totalSeconds > 0 {
                                Rectangle()
                                    .fill(Color.red)
                                    .frame(width: 2.5, height: 175)
                                    .shadow(color: Color.red.opacity(0.85), radius: 6)
                                    .offset(x: playheadX)
                                    .animation(.linear(duration: 0.06), value: playheadX)
                            }
                        }
                    }
                    .frame(height: 195)
                    .padding(.horizontal, 20)
                    .frame(minHeight: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { val in
                                lastUserScrollTime = Date()
                                WaveformScrollController.shared.onDragChanged(translationX: val.translation.width)
                            }
                            .onEnded { _ in
                                lastUserScrollTime = Date()
                                WaveformScrollController.shared.onDragEnded()
                            }
                    )
                }
                .onChange(of: state.scrollToStartTrigger) { _, _ in
                    lastUserScrollTime = .distantPast
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(0, anchor: .leading)
                    }
                }
                .onChange(of: state.currentSong?.id) { _, _ in
                    lastUserScrollTime = .distantPast
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(0, anchor: .leading)
                    }
                }
                .onChange(of: state.isPlaying) { _, playing in
                    if playing {
                        lastUserScrollTime = .distantPast
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(state.currentCueIdx, anchor: .center)
                        }
                    }
                }
                .onChange(of: state.currentCueIdx) { _, targetIdx in
                    // Se o usuário rolou recentemente para inspecionar, não interrompe a visão dele
                    if Date().timeIntervalSince(lastUserScrollTime) > 3.5 {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(targetIdx, anchor: .center)
                        }
                    }
                }
                .onChange(of: state.queuedCueIdx) { _, targetIdx in
                    if let idx = targetIdx {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
                .onChange(of: state.focusedCueIdx) { _, targetIdx in
                    if let idx = targetIdx {
                        lastUserScrollTime = .distantPast
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 180, maxHeight: .infinity)
        .padding(.vertical, 8)
        .background(
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.08)
                WaveformMouseTrackingView()
            }
        )
        .overlay(
            Group {
                if let msg = state.undoNotificationMessage {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundColor(.cyan)
                            Text(msg)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                        .shadow(color: .black.opacity(0.7), radius: 10, y: 4)
                        .padding(.top, 8)
                        
                        Spacer()
                    }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.95)), removal: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: state.undoNotificationMessage)
                }
            }
        )
    }
    
    private func calculateScale(totalAvailableWidth: CGFloat) -> CGFloat {
        guard !state.currentCues.isEmpty, state.totalSeconds > 0 else { return 25.0 }
        
        let secPerBar: Double = {
            let b = state.bpm > 30 ? state.bpm : 120.0
            let num = Double(state.timeSignature.split(separator: "/").first ?? "4") ?? 4.0
            return (60.0 / b) * num
        }()
        
        let fitPxPerSec = totalAvailableWidth / CGFloat(max(1.0, state.totalSeconds))
        let comfortablePxPerSec = CGFloat(65.0 / max(0.5, secPerBar))
        let maxPxPerSec = max(comfortablePxPerSec * 2.2, fitPxPerSec * 3.8)
        
        if state.zoomLevel <= 0.02 {
            return fitPxPerSec
        }
        
        let t = CGFloat(max(0.0, min(1.0, state.zoomLevel)))
        return fitPxPerSec + (maxPxPerSec - fitPxPerSec) * (t * 0.30)
    }
    
    private func calculateBlockWidths(scale: CGFloat, totalTrackWidth: CGFloat) -> [CGFloat] {
        guard !state.currentCues.isEmpty, state.totalSeconds > 0 else { return [] }
        let count = state.currentCues.count
        
        var widths: [CGFloat] = []
        for i in 0..<count {
            let curTime = state.currentCues[i].time
            let nextTime = (i + 1 < count) ? state.currentCues[i + 1].time : state.totalSeconds
            let duration = max(0.01, nextTime - curTime)
            widths.append(CGFloat(duration) * scale)
        }
        
        // Ajusta o último bloco para somar exatamente totalTrackWidth (evita desvios por arredondamento)
        if !widths.isEmpty {
            let sumExceptLast = widths.dropLast().reduce(0, +)
            widths[widths.count - 1] = max(10, totalTrackWidth - sumExceptLast)
        }
        return widths
    }
    
    private func calculateDividerPositions(blockWidths: [CGFloat]) -> [CGFloat] {
        guard blockWidths.count > 1 else { return [] }
        var positions: [CGFloat] = []
        var runningSum: CGFloat = 0.0
        // Cada divisor fica na soma exata das larguras dos blocos anteriores (fronteira exata)
        for i in 0..<(blockWidths.count - 1) {
            runningSum += blockWidths[i]
            positions.append(runningSum)
        }
        return positions
    }
    
    private func isLooping(idx: Int, isPlaying: Bool) -> Bool {
        guard state.loopActive else { return false }
        if let loopCue = state.loopCueIdx {
            return loopCue == idx
        }
        return isPlaying
    }
    
    private func handleCueSelection(index idx: Int, section: CueSection, proxy: ScrollViewProxy) {
        state.focusedCueIdx = nil
        lastUserScrollTime = .distantPast
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(idx, anchor: .center)
        }
        // SALTO QUANTIZADO NO TEMPO 1 DO PRÓXIMO COMPASSO
        if state.isPlaying {
            if idx == state.currentCueIdx {
                if state.queuedCueIdx != nil {
                    state.triggerCue(idx: idx, quantize: true)
                }
                return
            }
            state.triggerCue(idx: idx, quantize: true)
        } else {
            state.seekToSeconds(section.time)
            state.triggerCue(idx: idx, quantize: false)
        }
    }
    
    @ViewBuilder
    private func sectionItemView(idx: Int, section: CueSection, blockWidths: [CGFloat], proxy: ScrollViewProxy) -> some View {
        let isPlaying = (idx == state.currentCueIdx)
        let isQueued = (idx == state.queuedCueIdx)
        let isFocused = (idx == state.focusedCueIdx)
        let isEditing = (idx == state.quickEditingCueIdx)
        let isLoop = isLooping(idx: idx, isPlaying: isPlaying)
        let w: CGFloat = (idx < blockWidths.count) ? blockWidths[idx] : 90.0
        
        WaveformSectionBlock(
            state: state,
            index: idx,
            section: section,
            isEditing: isEditing,
            isPlaying: isPlaying,
            isQueued: isQueued,
            isFocused: isFocused,
            isLoopActive: isLoop,
            width: w,
            timeSignature: state.timeSignature,
            durationBars: state.calculateDurationBars(for: idx),
            onSelect: {
                handleCueSelection(index: idx, section: section, proxy: proxy)
            },
            onLoopToggle: {
                state.toggleLoop(cueIdx: idx)
            }
        )
        .equatable()
        .id(idx)
    }
}

// ==========================================
// DETECTOR DE CLIQUE COM BOTÃO DIREITO PARA MAC (SEM MENU DE CONTEXTO DO SISTEMA)
// ==========================================
struct RightClickModifier: ViewModifier {
    let action: () -> Void
    
    func body(content: Content) -> some View {
        content.overlay(
            RightClickRepresentable(action: action)
        )
    }
}

struct RightClickRepresentable: NSViewRepresentable {
    let action: () -> Void
    
    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.action = action
        return view
    }
    
    func updateNSView(_ nsView: RightClickNSView, context: Context) {
        nsView.action = action
    }
    
    class RightClickNSView: NSView {
        var action: (() -> Void)?
        
        override func hitTest(_ point: NSPoint) -> NSView? {
            // 1. Verifica geometricamente se o clique está dentro dos limites deste bloco específico
            guard let sup = superview else {
                return self.frame.contains(point) ? self : nil
            }
            let localPoint = self.convert(point, from: sup)
            guard self.bounds.contains(localPoint) else {
                return nil
            }
            
            // 2. Detecta se é clique secundário (botão direito físico ou via trackpad) ou Control+Clique
            let pressed = NSEvent.pressedMouseButtons
            let isRightPressed = (pressed & (1 << 1)) != 0
            let isCtrlLeft = (pressed & 1 != 0) && NSEvent.modifierFlags.contains(.control)
            let currentType = NSApp.currentEvent?.type
            let isRightEvent = currentType == .rightMouseDown || currentType == .rightMouseUp ||
                               (currentType == .leftMouseDown && NSApp.currentEvent?.modifierFlags.contains(.control) == true)
            
            if isRightPressed || isCtrlLeft || isRightEvent {
                return self
            }
            
            // 3. Clique esquerdo comum: retorna nil para repassar para seleção de trecho e botão de loop
            return nil
        }
        
        override func rightMouseDown(with event: NSEvent) {
            DispatchQueue.main.async { [weak self] in
                self?.action?()
            }
        }
        
        override func rightMouseUp(with event: NSEvent) {
            // Consome o mouseUp para não propagar
        }
        
        override func menu(for event: NSEvent) -> NSMenu? {
            DispatchQueue.main.async { [weak self] in
                self?.action?()
            }
            return nil
        }
        
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                action?()
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

// Overlay Pulsante dedicado exclusivamente para o bloco agendado para salto quantizado (Laranja)
struct QueuedJumpPulsingOverlay: View {
    @State private var isPulsing: Bool = false
    
    var body: some View {
        ZStack {
            // Preenchimento laranja pulsante suave
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.95, green: 0.50, blue: 0.10).opacity(isPulsing ? 0.38 : 0.14))
                .padding(2)
            
            // Borda laranja pulsante evidente
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(isPulsing ? 1.0 : 0.55), lineWidth: isPulsing ? 2.8 : 1.8)
                .padding(2)
                .shadow(color: Color.orange.opacity(isPulsing ? 0.90 : 0.35), radius: isPulsing ? 8 : 3)
        }
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 0.65).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// ==========================================
// 8.1 FUNDO ESTÁTICO & ONDA CONTÍNUA (GPU METAL ACCELERATED VIA .drawingGroup)
// ==========================================
struct WaveformStaticBackgroundView: View, Equatable {
    let songId: String
    let peaks: [Double]
    let totalTrackWidth: CGFloat
    
    static func == (lhs: WaveformStaticBackgroundView, rhs: WaveformStaticBackgroundView) -> Bool {
        lhs.songId == rhs.songId &&
        lhs.totalTrackWidth == rhs.totalTrackWidth &&
        lhs.peaks.count == rhs.peaks.count &&
        lhs.peaks.first == rhs.peaks.first &&
        lhs.peaks.last == rhs.peaks.last
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                .frame(width: totalTrackWidth, height: 175)
            
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: totalTrackWidth, height: 1)
                .position(x: totalTrackWidth / 2, y: 175 / 2)
            
            if !peaks.isEmpty {
                ContinuousWaveformShape(peaks: peaks)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.white.opacity(0.85),
                                Color(white: 0.85).opacity(0.65)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: totalTrackWidth, height: 175)
                    .drawingGroup()
            }
        }
        .frame(width: totalTrackWidth, height: 175)
    }
}

// Bloco de Seção Sobreposto (Divisões, Métricas e Controles sobre a Onda Contínua)
struct WaveformSectionBlock: View, Equatable {
    let state: PlaybackState
    let index: Int
    let section: CueSection
    let isEditing: Bool
    let isPlaying: Bool
    let isQueued: Bool
    let isFocused: Bool
    let isLoopActive: Bool
    let width: CGFloat
    let timeSignature: String
    let durationBars: Double
    let onSelect: () -> Void
    let onLoopToggle: () -> Void
    
    static func == (lhs: WaveformSectionBlock, rhs: WaveformSectionBlock) -> Bool {
        lhs.index == rhs.index &&
        lhs.section.id == rhs.section.id &&
        lhs.isEditing == rhs.isEditing &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.isQueued == rhs.isQueued &&
        lhs.isFocused == rhs.isFocused &&
        lhs.isLoopActive == rhs.isLoopActive &&
        lhs.width == rhs.width &&
        lhs.timeSignature == rhs.timeSignature &&
        lhs.durationBars == rhs.durationBars
    }
    
    let cueTypes = ["Count-In", "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3", "Pre-Chorus", "Chorus", "Post Chorus", "Instrumental", "Interlude", "Bridge", "Solo", "Tag", "Ending"]
    
    var body: some View {
        ZStack(alignment: .topLeading) {
                // Fundo translúcido com a cor de leve de cada parte (conforme foto de referência MultiTracks)
                RoundedRectangle(cornerRadius: 8)
                    .fill(blockBgColor)
                    .padding(2)
                
                // Divisões verticais dos compassos da seção
                let total = durationBars
                if total > 0.5 {
                    let numLines = Int(floor(total - 0.001))
                    if numLines >= 1 {
                        ForEach(1...numLines, id: \.self) { b in
                            let xPos = (CGFloat(b) / CGFloat(total)) * width
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1)
                                .position(x: xPos, y: 175 / 2)
                        }
                    }
                }
                
                // Header: Playback Circular Badge ("Co", "I", "V1", etc.) + Botão de Loop
                HStack(alignment: .center, spacing: 4) {
                    if width >= 24 {
                        let badgeSize: CGFloat = width < 42 ? 18 : 22
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .overlay(Circle().stroke(badgeColor, lineWidth: 1.6))
                            .frame(width: badgeSize, height: badgeSize)
                            .overlay(
                                Text(section.shortBadgeName)
                                    .font(.system(size: width < 42 ? 8 : 10, weight: .black, design: .rounded))
                                    .foregroundColor(.white)
                            )
                            .shadow(color: Color.black.opacity(0.4), radius: 2, x: 0, y: 1)
                            .help(section.cleanFullName)
                    }
                    
                    Spacer(minLength: 0)
                    
                    if width >= 44 {
                        Button(action: onLoopToggle) {
                            Image(systemName: "repeat")
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundColor(isLoopActive ? Color.black : Color.white.opacity(0.85))
                                .padding(4)
                                .background(isLoopActive ? Color.cyan : Color.black.opacity(0.55))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(isLoopActive ? Color.white.opacity(0.35) : Color.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Loop this section (L)")
                    }
                }
                .padding(.leading, index > 0 ? max(5, min(8, (width - 24) / 4) + 2) : max(2, min(6, (width - 24) / 4)))
                .padding(.trailing, max(2, min(6, (width - 24) / 4)))
                .padding(.top, 6)
            }
            .frame(width: width, height: 175)
            .clipped()
            // Borda de destaque quando ativa / enfileirada / focada com o teclado ou borda colorida da seção
            .overlay(
                Group {
                    if isPlaying {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green, lineWidth: 2.5)
                            .padding(2)
                            .shadow(color: Color.green.opacity(0.6), radius: 6)
                            .overlay(
                                Group {
                                    if isFocused && !isQueued {
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.95), lineWidth: 2.0)
                                            .padding(2)
                                            .shadow(color: Color.white.opacity(0.8), radius: 4)
                                    }
                                }
                            )
                    } else if isQueued {
                        // APENAS o bloco em laranja (salto quantizado) fica pulsando
                        QueuedJumpPulsingOverlay()
                    } else if isFocused {
                        // Destaque visual branco translúcido do cursor de navegação por setas (aguardando Enter)
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.95), lineWidth: 2.2)
                            .padding(2)
                            .shadow(color: Color.white.opacity(0.7), radius: 6)
                    } else {
                        // Borda sutil estática com a cor da seção (sem pulsar)
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(badgeColor.opacity(0.28), lineWidth: 1.2)
                            .padding(2)
                    }
                }
            )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .frame(width: width, height: 175)
        .clipped()
        .modifier(RightClickModifier(action: {
            DispatchQueue.main.async {
                state.quickEditingCueIdx = index
            }
        }))
        .popover(
            isPresented: Binding(
                get: { isEditing },
                set: { if !$0 { state.quickEditingCueIdx = nil } }
            ),
            arrowEdge: .top
        ) {
            QuickSectionEditPopoverView(state: state, cueIndex: index)
        }
    }
    
    private var blockBgColor: Color {
        if isPlaying {
            if isFocused && !isQueued {
                return Color(red: 0.16, green: 0.45, blue: 0.28).opacity(0.55)
            }
            return Color(red: 0.10, green: 0.40, blue: 0.22).opacity(0.35)
        }
        if isQueued {
            return Color.clear // QueuedJumpPulsingOverlay gerencia o preenchimento e brilho laranja
        }
        if isFocused {
            // Fundo de destaque branco translúcido elegante
            return Color.white.opacity(0.20)
        }
        // Cor de leve no fundo de acordo com cada parte (mais discreta e sutil)
        return badgeColor.opacity(0.09)
    }
    
    private var borderColor: Color {
        if isPlaying { return Color(red: 0.19, green: 0.88, blue: 0.60) }
        if isQueued { return Color(red: 0.98, green: 0.75, blue: 0.15) }
        return badgeColor.opacity(0.40)
    }
    
    private var badgeColor: Color {
        let upper = section.name.uppercased()
        if upper.contains("COUNT") || upper.contains("CONTAGEM") { return Color(red: 0.48, green: 0.55, blue: 0.65) }
        if upper.contains("POST") || upper.contains("PÓS") || upper.contains("POS") { return Color(red: 0.98, green: 0.44, blue: 0.52) }
        if upper.contains("PRE") || upper.contains("PRÉ") { return Color(red: 0.95, green: 0.78, blue: 0.18) }
        if upper.contains("CHORUS") || upper.contains("REFRÃO") { return Color(red: 0.92, green: 0.32, blue: 0.28) }
        if upper.contains("BRIDGE") || upper.contains("PONTE") { return Color(red: 0.95, green: 0.55, blue: 0.20) }
        if upper.contains("INTRO") { return Color(red: 0.18, green: 0.72, blue: 0.92) }
        if upper.contains("VERSE") || upper.contains("VERSO") { return Color(red: 0.55, green: 0.38, blue: 0.92) }
        if upper.contains("INTERLUDE") || upper.contains("INTERLÚDIO") || upper.contains("INTER") { return Color(red: 0.16, green: 0.75, blue: 0.70) }
        if upper.contains("SOLO") { return Color(red: 0.16, green: 0.75, blue: 0.70) }
        if upper.contains("TAG") { return Color(red: 0.22, green: 0.78, blue: 0.45) }
        if upper.contains("ENDING") || upper.contains("OUTRO") || upper.contains("FINAL") { return Color(red: 0.50, green: 0.55, blue: 0.62) }
        return Color(red: 0.25, green: 0.55, blue: 0.95)
    }
}

// Forma de Onda Contínua e Espelhada (Estilo DAW / MultiTracks Playback como na imagem 3 de referência)
struct ContinuousWaveformShape: Shape {
    let peaks: [Double]
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard peaks.count > 1 else { return path }
        
        let midY = rect.midY
        // Amplitude moderada da onda (respiro apenas no topo e no fundo; sem margens nas laterais)
        let maxHeight = rect.height * 0.30
        let step = rect.width / CGFloat(peaks.count - 1)
        
        // Linha superior
        let firstY = midY - CGFloat(peaks[0]) * maxHeight
        path.move(to: CGPoint(x: 0, y: firstY))
        
        for i in 1..<peaks.count {
            let x = CGFloat(i) * step
            let y = midY - CGFloat(peaks[i]) * maxHeight
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        // Linha inferior espelhada
        for i in (0..<peaks.count).reversed() {
            let x = CGFloat(i) * step
            let y = midY + CGFloat(peaks[i]) * maxHeight
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        path.closeSubpath()
        return path
    }
}

// Renderização dos Picos Reais do Canal R com Linhas de Compasso Estilo DAW
struct RealWaveformPeaksView: View {
    let waveform: [Double]?
    let color: Color
    let durationBars: Double
    
    var body: some View {
        let peaks: [Double] = {
            if let w = waveform, !w.isEmpty { return w }
            return [0.03, 0.05, 0.15, 0.35, 0.65, 0.8, 0.9, 0.75, 0.6, 0.85, 0.95, 0.7, 0.4, 0.2, 0.08, 0.03]
        }()
        
        GeometryReader { geo in
            ZStack {
                // Divisões verticais dos compassos da seção
                if durationBars > 0.5 {
                    let total = durationBars
                    let numLines = Int(floor(total - 0.001))
                    if numLines >= 1 {
                        ForEach(1...numLines, id: \.self) { b in
                            let xPos = (CGFloat(b) / CGFloat(total)) * geo.size.width
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1)
                                .position(x: xPos, y: geo.size.height / 2)
                        }
                    }
                }
                
                // Linha de centro discreta
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                
                // Silhueta Contínua Sólida da Forma de Onda do Canal R (Estilo DAW / Playback)
                ContinuousWaveformShape(peaks: peaks)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                color.opacity(0.95),
                                color.opacity(0.70)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
    }
}

// ==========================================
// 8. FADER ESTILO PLAYBACK (CONSOLE CHANNEL STRIP)
// ==========================================

// MOUSE TRACKING DEDICADO DO FADER (IMPEDE ARRASTO DA JANELA MAC VIA mouseDownCanMoveWindow = false)
struct FaderMouseTrackingView: NSViewRepresentable {
    @Binding var volume: Double
    let maxVolume: Double = 1.5
    let capWidth: CGFloat = 16.0
    let onVolumeChange: () -> Void
    
    func makeNSView(context: Context) -> FaderTrackingNSView {
        let view = FaderTrackingNSView()
        view.capWidth = capWidth
        view.onChanged = { [self] newProg in
            self.volume = round((newProg * self.maxVolume) * 100) / 100.0
            self.onVolumeChange()
        }
        view.onDoubleClick = { [self] in
            self.volume = 1.0
            self.onVolumeChange()
        }
        return view
    }
    
    func updateNSView(_ nsView: FaderTrackingNSView, context: Context) {
        nsView.capWidth = capWidth
        nsView.onChanged = { [self] newProg in
            self.volume = round((newProg * self.maxVolume) * 100) / 100.0
            self.onVolumeChange()
        }
        nsView.onDoubleClick = { [self] in
            self.volume = 1.0
            self.onVolumeChange()
        }
    }
    
    class FaderTrackingNSView: NSView {
        var onChanged: ((Double) -> Void)?
        var onDoubleClick: (() -> Void)?
        var capWidth: CGFloat = 16.0
        
        override var mouseDownCanMoveWindow: Bool { false }
        
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            updateFromLocation(event.locationInWindow)
        }
        
        override func mouseDragged(with event: NSEvent) {
            updateFromLocation(event.locationInWindow)
        }
        
        private func updateFromLocation(_ locInWindow: NSPoint) {
            let localPoint = convert(locInWindow, from: nil)
            let w = bounds.width
            let travel = max(1.0, w - capWidth)
            let touchX = localPoint.x - (capWidth / 2)
            let progress = max(0.0, min(1.0, Double(touchX / travel)))
            onChanged?(progress)
        }
    }
}

// 8.1 CABEÇALHO DO CANAL (MINIMALISTA, SEM BUBBLES/CAIXAS)
struct ChannelHeaderView: View {
    let title: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 16)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color.gray)
                    .lineLimit(1)
            }
        }
        .frame(width: 85, alignment: .leading)
    }
}

// 8.2 BOTÃO MUTE DISCRETO
struct MuteButtonView: View {
    let isMuted: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            Text("M")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(isMuted ? .white : Color.white.opacity(0.40))
                .frame(width: 22, height: 22)
                .background(isMuted ? Color(red: 0.85, green: 0.25, blue: 0.25) : Color.white.opacity(0.06))
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isMuted ? Color.clear : Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .help(isMuted ? "Unmute channel" : "Mute channel")
    }
}

// 8.3 FADER CAP MINIMALISTA (SÓLIDO, MATTE, SEM GRADIENTES OU SOMBRAS PESADAS)
struct FaderCapKnobView: View {
    let accentColor: Color
    let isMuted: Bool
    
    var body: some View {
        ZStack {
            // Corpo retangular minimalista e sólido com bordas suaves
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color(white: 0.28))
                .frame(width: 16, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
            
            // Traço central limpo e nítido
            Rectangle()
                .fill(isMuted ? Color(red: 0.90, green: 0.25, blue: 0.25) : Color.white)
                .frame(width: 1.5, height: 16)
        }
        .frame(width: 16, height: 26)
    }
}

// 8.4 VALOR DE VOLUME (MINIMALISTA)
struct FaderValueBadgeView: View {
    let isMuted: Bool
    let volume: Double
    let dbText: String
    
    var body: some View {
        Text(isMuted ? "MUTE" : dbText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(isMuted ? Color(red: 0.90, green: 0.30, blue: 0.30) : Color.white.opacity(0.85))
            .frame(width: 48, alignment: .trailing)
    }
}

// 8.5 PLAYBACK FADER STRIP (SEAMLESS, SEM CAIXA/CARD FLUTUANTE)
struct PlaybackFaderView: View {
    let title: String
    let subtitle: String
    let icon: String
    let accentColor: Color
    @Binding var volume: Double     // 0.0 ... 1.5
    @Binding var isMuted: Bool
    let onMuteToggle: () -> Void
    let onVolumeChange: () -> Void
    
    private let trackWidth: CGFloat = 140.0
    private let faderCapWidth: CGFloat = 16.0
    
    private var availableTravel: CGFloat {
        max(1.0, trackWidth - faderCapWidth)
    }
    
    private var capOffset: CGFloat {
        let progress = CGFloat(max(0.0, min(1.5, volume)) / 1.5)
        return progress * availableTravel
    }
    
    private var unityX: CGFloat {
        (1.0 / 1.5) * availableTravel + (faderCapWidth / 2)
    }
    
    private var dbText: String {
        if isMuted { return "MUTED" }
        if volume <= 0.001 { return "-∞ dB" }
        let db = 20.0 * log10(volume)
        if abs(db) < 0.15 { return "0.0 dB" }
        return String(format: "%+.1f dB", db)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ChannelHeaderView(title: title, subtitle: subtitle, icon: icon, accentColor: accentColor)
            
            MuteButtonView(isMuted: isMuted, onToggle: onMuteToggle)
            
            // Fenda e Knob com tracking anti-arraste de janela
            ZStack(alignment: .leading) {
                // Trilho / Fenda preta simples e elegante
                ZStack(alignment: .leading) {
                    // Marcação sutil de 0dB
                    Rectangle()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 1, height: 8)
                        .offset(x: unityX - 0.5)
                    
                    // Fenda preta fosca contínua
                    Capsule()
                        .fill(Color.black)
                        .frame(width: trackWidth, height: 2.5)
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    
                    // Knob sólido matte
                    FaderCapKnobView(accentColor: accentColor, isMuted: isMuted)
                        .offset(x: capOffset)
                }
                .frame(width: trackWidth, height: 28)
                
                // Camada de mouse tracking nativo (previne arraste da janela)
                FaderMouseTrackingView(volume: $volume, onVolumeChange: onVolumeChange)
                    .frame(width: trackWidth, height: 28)
            }
            .frame(width: trackWidth, height: 28)
            
            FaderValueBadgeView(isMuted: isMuted, volume: volume, dbText: dbText)
        }
    }
}

// ==========================================
// 8. BOTTOM MIXER DOCK (SEAMLESS, MINIMALISTA, SEM GRADIENTES OU CAIXAS)
// ==========================================
struct BottomMixerDock: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        HStack(spacing: 18) {
            // Canal L: CLICK
            PlaybackFaderView(
                title: "CLICK",
                subtitle: "Guide (L)",
                icon: "metronome",
                accentColor: Color.cyan,
                volume: $state.clickVol,
                isMuted: $state.clickMute,
                onMuteToggle: { state.toggleClickMute() },
                onVolumeChange: { state.sendVolumes() }
            )
            
            // Divisor vertical sutil
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 22)
            
            // Canal R: TRACKS
            PlaybackFaderView(
                title: "TRACKS",
                subtitle: "Audio (R)",
                icon: "waveform",
                accentColor: Color(red: 0.35, green: 0.65, blue: 1.0),
                volume: $state.vsVol,
                isMuted: $state.vsMute,
                onMuteToggle: { state.toggleVsMute() },
                onVolumeChange: { state.sendVolumes() }
            )
            
            Spacer(minLength: 16)
            
            // Divisor vertical sutil
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 22)
            
            // Controle de Zoom da Timeline (Minimalista)
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(state.zoomLevel <= 0.05 ? Color.white.opacity(0.20) : Color.white.opacity(0.60))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            state.zoomLevel = max(0.0, state.zoomLevel - 0.2)
                        }
                    }
                    .help("Zoom Out")
                
                Slider(value: $state.zoomLevel, in: 0.0...1.0)
                    .frame(width: 75)
                    .accentColor(.cyan)
                
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(state.zoomLevel >= 0.95 ? Color.white.opacity(0.20) : Color.cyan)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            state.zoomLevel = min(1.0, state.zoomLevel + 0.2)
                        }
                    }
                    .help("Zoom In")
            }
            
            // Divisor vertical sutil
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 22)
            
            // Seletor de Saída de Áudio (Minimalista)
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Color.cyan)
                
                Picker("", selection: $state.selectedDeviceId) {
                    ForEach(state.devices) { dev in
                        Text(dev.name)
                            .tag(dev.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(MenuPickerStyle())
                .frame(width: 150)
                .onChange(of: state.selectedDeviceId) { _, newId in
                    state.setAudioDevice(id: newId, save: true)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 9)
        .padding(.bottom, 9)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }
}

// ==========================================
// 9. MODAL PARA ADICIONAR MÚSICAS AO SETLIST
// ==========================================
struct AddSongSheetView: View {
    @ObservedObject var state: PlaybackState
    @Environment(\.presentationMode) var presentationMode
    @State private var searchText = ""
    
    var availablePool: [SongItem] {
        return state.librarySongs.isEmpty ? state.songs : state.librarySongs
    }
    
    var filteredSongs: [SongItem] {
        if searchText.isEmpty { return availablePool }
        return availablePool.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.filename.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("Add Song")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                
                // Pasta atual clicável e discreta
                Button(action: { state.selectTracksFolder() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text(state.shortFolderName.isEmpty ? "Select Folder" : state.shortFolderName)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .help(state.tracksFolderPath.isEmpty ? "Select Tracks Folder" : "Folder: \(state.tracksFolderPath)")
                
                Spacer()
                
                // Botão Refresh discreto
                Button(action: { state.refreshTracks() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(state.isScanningFolder ? Color.cyan : Color.white.opacity(0.6))
                        .rotationEffect(Angle(degrees: state.isScanningFolder ? 360 : 0))
                        .animation(state.isScanningFolder ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: state.isScanningFolder)
                        .padding(5)
                        .background(state.isScanningFolder ? Color.cyan.opacity(0.18) : Color.white.opacity(0.06))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(state.isScanningFolder)
                .help("Refresh tracks from folder")
                
                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .cornerRadius(5)
            }
            
            // Campo de busca nativo minimalista
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                    .font(.system(size: 11))
                TextField("Search songs...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .cornerRadius(7)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 1))
            
            if (state.isLoadingLibrary || state.isScanningFolder) && filteredSongs.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .cyan))
                    Text("Scanning tracks folder...")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .frame(maxHeight: .infinity)
            } else if filteredSongs.isEmpty {
                VStack(spacing: 12) {
                    Text("No tracks found in current folder.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                    HStack(spacing: 10) {
                        Button("Select Folder") {
                            state.selectTracksFolder()
                        }
                        .buttonStyle(BorderedButtonStyle())
                        
                        Button("Refresh Tracks") {
                            state.refreshTracks()
                        }
                        .buttonStyle(BorderedButtonStyle())
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(filteredSongs) { song in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(song.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                            if let bpm = song.bpm {
                                Text("\(formatBpm(bpm)) BPM")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        Spacer()
                        Button("Add") {
                            state.setlist.append(SetlistSong(song: song))
                            state.saveSetlistState()
                            state.autoFetchCover(for: song)
                            presentationMode.wrappedValue.dismiss()
                        }
                        .buttonStyle(BorderedProminentButtonStyle())
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 450, height: 420)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .onAppear {
            if state.librarySongs.isEmpty {
                state.fetchAllLibrarySongs()
            }
        }
    }
}

// ==========================================
// 10. MODAL QR CODE NATIVO (COREIMAGE)
// ==========================================
struct QrCodeSheetView: View {
    @ObservedObject var state: PlaybackState
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        VStack(spacing: 16) {
            Text("📱 Mobile Remote Control")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Scan with your mobile camera to control playback:")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            if let qrImage = generateQRCodeImage(from: state.serverUrl) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .padding(10)
                    .background(Color.white)
                    .cornerRadius(12)
            }
            
            Text(state.serverUrl)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
                .padding(6)
            
            Text("💡 Ensure your smartphone is connected to the same Wi-Fi network as this Mac.")
                .font(.caption)
                .foregroundColor(.gray)
            
            Button("Done") {
                presentationMode.wrappedValue.dismiss()
            }
            .buttonStyle(BorderedProminentButtonStyle())
        }
        .padding(24)
        .frame(width: 390, height: 440)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }
    
    private func generateQRCodeImage(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = ciImage.transformed(by: transform)
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}

// ==========================================
// 12. MINI POPOVER DE EDIÇÃO RÁPIDA DE SEÇÃO (RIGHT-CLICK EXCLUSIVO)
// ==========================================

// Ícone de Divisão / Corte com Linha Tracejada no Meio (Estilo Clip Cut / Video Editor)
struct VideoCutSplitIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3.5)
                .stroke(Color.cyan, lineWidth: 1.6)
                .frame(width: 19, height: 14)
            
            // Linha vertical tracejada no centro
            Path { path in
                path.move(to: CGPoint(x: 9.5, y: 1.5))
                path.addLine(to: CGPoint(x: 9.5, y: 12.5))
            }
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2.5, 2.0]))
            .frame(width: 19, height: 14)
        }
    }
}

struct QuickSectionEditPopoverView: View {
    @ObservedObject var state: PlaybackState
    let cueIndex: Int
    
    let cueTypes = [
        "Count-In", "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3", 
        "Pre-Chorus", "Chorus", "Post Chorus", "Instrumental", "Interlude", 
        "Bridge", "Solo", "Tag", "Ending"
    ]
    
    @State private var isCustom: Bool = false
    @State private var customText: String = ""
    
    var body: some View {
        if cueIndex >= 0 && cueIndex < state.currentCues.count {
            let cue = state.currentCues[cueIndex]
            let curDuration = state.calculateDurationBars(for: cueIndex)
            
            VStack(alignment: .leading, spacing: 12) {
                // Header com badge Playback + nome completo + compasso
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(hex: cue.color))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text(cue.shortBadgeName)
                                .font(.system(size: 10, weight: .black, design: .rounded))
                                .foregroundColor(.white)
                        )
                    Text(cue.cleanFullName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text("• Bar \(formatBars(cue.bar))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    if state.canUndo {
                        Button(action: {
                            state.undo()
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 8, weight: .bold))
                                Text("Undo")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.cyan.opacity(0.12))
                            .cornerRadius(4)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Undo last edit (⌘Z)")
                    }
                    Button(action: { state.quickEditingCueIdx = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                Divider().background(Color.white.opacity(0.12))
                
                // Section Type (com Interlude, Post Chorus e Personalizado)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Type")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: 55, alignment: .leading)
                        
                        Picker("", selection: Binding(
                            get: {
                                if isCustom || !cueTypes.contains(cue.name) {
                                    return "__custom__"
                                }
                                return cue.name
                            },
                            set: { newType in
                                if newType == "__custom__" {
                                    isCustom = true
                                    if customText.isEmpty {
                                        customText = cue.name
                                    }
                                } else {
                                    isCustom = false
                                    state.changeSectionType(at: cueIndex, newType: newType)
                                }
                            }
                        )) {
                            ForEach(cueTypes, id: \.self) { t in
                                Text(t).tag(t)
                            }
                            Divider()
                            Text("Custom (Personalizado)...").tag("__custom__")
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                    
                    if isCustom || !cueTypes.contains(cue.name) {
                        HStack(spacing: 6) {
                            TextField("Custom name (e.g. Instrumental)", text: $customText, onCommit: {
                                applyCustom()
                            })
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.cyan.opacity(0.6), lineWidth: 1))
                            
                            Button(action: applyCustom) {
                                Text("Apply")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(Color.cyan)
                                    .cornerRadius(5)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.leading, 55)
                    }
                }
                
                // Duration in Bars with Stepper [-1] [-½] [ 8½ bars ] [+½] [+1]
                let hasNext = cueIndex + 1 < state.currentCues.count
                let nextDuration = hasNext ? state.calculateDurationBars(for: cueIndex + 1) : 0.0
                
                HStack {
                    Text("Duration")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.gray)
                        .frame(width: 52, alignment: .leading)
                    
                    HStack(spacing: 3) {
                        Button(action: {
                            state.adjustSectionDuration(at: cueIndex, deltaBars: -1.0)
                        }) {
                            Text("-1")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 25, height: 24)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!hasNext || curDuration - 1.0 < 0.999)
                        .help("Remove 1 whole bar (right block expands left)")
                        
                        Button(action: {
                            state.adjustSectionDuration(at: cueIndex, deltaBars: -0.5)
                        }) {
                            Text("-½")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.cyan)
                                .frame(width: 25, height: 24)
                                .background(Color.cyan.opacity(0.14))
                                .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!hasNext || curDuration - 0.5 < 0.999)
                        .help("Remove half bar (right block expands left)")
                        
                        Text("\(formatBars(curDuration)) bars")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(minWidth: 54, alignment: .center)
                        
                        Button(action: {
                            state.adjustSectionDuration(at: cueIndex, deltaBars: 0.5)
                        }) {
                            Text("+½")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.cyan)
                                .frame(width: 25, height: 24)
                                .background(Color.cyan.opacity(0.14))
                                .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!hasNext || nextDuration - 0.5 < 0.999)
                        .help("Add half bar (taken from right block, keeping min 1 bar)")
                        
                        Button(action: {
                            state.adjustSectionDuration(at: cueIndex, deltaBars: 1.0)
                        }) {
                            Text("+1")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 25, height: 24)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(5)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(!hasNext || nextDuration - 1.0 < 0.999)
                        .help("Add 1 whole bar (taken from right block, keeping min 1 bar)")
                    }
                }
                
                Divider().background(Color.white.opacity(0.12))
                
                // Action Buttons
                HStack(spacing: 12) {
                    // Split Section Button (with Dashed Line)
                    Button(action: {
                        state.splitSection(at: cueIndex)
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.cyan.opacity(0.18))
                                .frame(width: 36, height: 36)
                            VideoCutSplitIcon()
                        }
                        .overlay(Circle().stroke(Color.cyan.opacity(0.35), lineWidth: 1.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Split section in two (Cut with dashed line)")
                    
                    // Botão Unir Seção com o Bloco à Esquerda (Em Vermelho)
                    if state.currentCues.count > 1 {
                        Button(action: {
                            state.deleteSection(at: cueIndex)
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.red.opacity(0.18))
                                    .frame(width: 36, height: 36)
                                Image(systemName: "arrow.left.to.line.compact")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(Color(red: 1.0, green: 0.35, blue: 0.35))
                            }
                            .overlay(Circle().stroke(Color.red.opacity(0.35), lineWidth: 1.5))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(cueIndex == 0 ? "Unir seção com a próxima" : "Unir com o bloco à esquerda")
                    }
                    
                    Spacer()
                    
                    // Play Section Button (Ouvir Seção com Voz Guia Prévia)
                    Button(action: {
                        state.triggerCue(idx: cueIndex, quantize: false)
                        if !state.isPlaying { state.playPause() }
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.green.opacity(0.18))
                                .frame(width: 36, height: 36)
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.green)
                        }
                        .overlay(Circle().stroke(Color.green.opacity(0.35), lineWidth: 1.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Play section from start")
                }
            }
            .padding(16)
            .frame(width: 260)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            .onAppear {
                if !cueTypes.contains(cue.name) {
                    isCustom = true
                    customText = cue.name
                }
            }
        } else {
            EmptyView()
        }
    }
    
    private func applyCustom() {
        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            state.changeSectionType(at: cueIndex, newType: trimmed)
        }
    }
    
    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// ==========================================
// 13. MODAL EDITOR DE MÚSICA & CUES (IA & COMPASSOS)
// ==========================================
struct SongEditorSheetView: View {
    @ObservedObject var state: PlaybackState
    @Environment(\.presentationMode) var presentationMode
    
    @State private var localBpmText: String = ""
    @State private var localTimeSignature: String = "4/4"
    @State private var localCues: [CueSection] = []
    @State private var localUndoStack: [[CueSection]] = []
    
    private func pushLocalUndo() {
        localUndoStack.append(localCues)
        if localUndoStack.count > 30 { localUndoStack.removeFirst() }
    }
    
    private func undoLocal() {
        guard let prev = localUndoStack.popLast() else { return }
        localCues = prev
    }
    
    let timeSignatureOptions = ["4/4", "2/4", "3/4", "6/8"]
    let cueTypeOptions = [
        "Count-In", "Intro", "Verse", "Verse 1", "Verse 2", "Verse 3", 
        "Pre-Chorus", "Chorus", "Post Chorus", "Instrumental", "Interlude", 
        "Bridge", "Solo", "Tag", "Ending"
    ]
    @State private var customEditingIdx: Int? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header do Editor
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.cyan)
                        Text("Song Editor & Cue Mapping")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    if let song = state.currentSong {
                        Text(song.name)
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer()
                if !localUndoStack.isEmpty {
                    Button(action: undoLocal) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 10, weight: .bold))
                            Text("Desfazer")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cyan.opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Desfazer alteração local (⌘Z)")
                }
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)
            .background(Color(red: 0.12, green: 0.12, blue: 0.13))
            
            Divider().background(Color.white.opacity(0.1))
            
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 20) {
                    // 1. Painel de BPM, Compasso, Capa e Reprocessamento com IA
                    HStack(spacing: 16) {
                        // Capa da Música
                        if let song = state.currentSong {
                            HStack(spacing: 10) {
                                SongCoverView(
                                    song: song,
                                    width: 52,
                                    height: 52,
                                    cornerRadius: 8,
                                    isSelected: false,
                                    refreshId: state.coverRefreshTrigger
                                )
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("COVER")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.gray)
                                    
                                    Button(action: {
                                        state.openCoverPicker(for: song)
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "photo")
                                                .font(.system(size: 10, weight: .bold))
                                            Text(song.has_cover == true ? "Alterar..." : "Buscar...")
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        .foregroundColor(.cyan)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.cyan.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(10)
                        }
                        
                        // Edição de BPM
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TEMPO (BPM)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            HStack(spacing: 8) {
                                Button(action: {
                                    if let val = Double(localBpmText.replacingOccurrences(of: ",", with: ".")), val > 30 {
                                        let next = round(val - 1.0)
                                        localBpmText = String(format: "%.1f", next)
                                        recalculateCueTimes()
                                    }
                                }) {
                                    Image(systemName: "minus")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                                
                                TextField("BPM", text: $localBpmText)
                                    .textFieldStyle(PlainTextFieldStyle())
                                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    .frame(width: 65, height: 28)
                                    .multilineTextAlignment(.center)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                                    .onChange(of: localBpmText) { _, _ in
                                        recalculateCueTimes()
                                    }
                                
                                Button(action: {
                                    if let val = Double(localBpmText.replacingOccurrences(of: ",", with: ".")), val < 280 {
                                        let next = round(val + 1.0)
                                        localBpmText = String(format: "%.1f", next)
                                        recalculateCueTimes()
                                    }
                                }) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .bold))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        // Edição do Tipo de Compasso
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TIME SIGNATURE")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Picker("", selection: $localTimeSignature) {
                                ForEach(timeSignatureOptions, id: \.self) { ts in
                                    Text(ts).tag(ts)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 150)
                            .onChange(of: localTimeSignature) { _, _ in
                                recalculateCueTimes()
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        // Voz Guia na Troca (Lead-in)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("GUIDE LEAD-IN")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Picker("", selection: $state.guideLeadInBars) {
                                Text("1 Bar").tag(1.0)
                                Text("½ Bar").tag(0.5)
                                Text("Off").tag(0.0)
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 140)
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.03))
                        .cornerRadius(10)
                        
                        Spacer()
                        
                        // Botão Reprocessar com IA
                        Button(action: {
                            if let bpmVal = Double(localBpmText.replacingOccurrences(of: ",", with: ".")) {
                                state.editorBpm = bpmVal
                                state.editorTimeSignature = localTimeSignature
                                state.reprocessWithAI()
                            }
                        }) {
                            HStack(spacing: 8) {
                                if state.isReprocessing {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .colorInvert()
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Reprocess with AI")
                                        .font(.system(size: 12, weight: .bold))
                                    Text("Analyzes Guide & Dynamics")
                                        .font(.system(size: 9))
                                        .opacity(0.8)
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .cornerRadius(10)
                            .shadow(color: Color.purple.opacity(0.4), radius: 6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(state.isReprocessing)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    
                    // 2. Seções e Compassos da Música
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("SECTIONS & BARS (CUES)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(localCues.count) sections")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.gray)
                        }
                        .padding(.horizontal, 20)
                        
                        // Cabeçalho das Colunas
                        HStack(spacing: 12) {
                            Text("SECTION TYPE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 150, alignment: .leading)
                            
                            Text("BAR")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 145, alignment: .center)
                            
                            Text("TIME")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 80, alignment: .leading)
                            
                            Spacer()
                            
                            Text("ACTIONS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.gray)
                                .frame(width: 70, alignment: .trailing)
                        }
                        .padding(.horizontal, 20)
                        
                        // Lista de Cues
                        VStack(spacing: 6) {
                            ForEach(Array(localCues.enumerated()), id: \.element.id) { idx, cue in
                                HStack(spacing: 12) {
                                    // Nome / Tipo de Cue com Badge Colorido (com Interlude, Post Chorus e Custom)
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(Color(hex: cue.color))
                                            .frame(width: 10, height: 10)
                                        
                                        if customEditingIdx == idx || !cueTypeOptions.contains(cue.name) {
                                            HStack(spacing: 4) {
                                                TextField("Section", text: Binding(
                                                    get: { cue.name },
                                                    set: { newName in
                                                        localCues[idx].name = newName
                                                        localCues[idx].color = colorForCue(name: newName)
                                                    }
                                                ))
                                                .textFieldStyle(PlainTextFieldStyle())
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color.white.opacity(0.08))
                                                .cornerRadius(5)
                                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.cyan.opacity(0.6), lineWidth: 1))
                                                .frame(width: 95)
                                                
                                                Button(action: {
                                                    if !cueTypeOptions.contains(cue.name) {
                                                        localCues[idx].name = "Chorus"
                                                        localCues[idx].color = colorForCue(name: "Chorus")
                                                    }
                                                    customEditingIdx = nil
                                                }) {
                                                    Image(systemName: "list.bullet")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(.gray)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                                .help("Switch to preset types picker")
                                            }
                                        } else {
                                            Picker("", selection: Binding(
                                                get: { cue.name },
                                                set: { newName in
                                                    pushLocalUndo()
                                                    if newName == "__custom__" {
                                                        customEditingIdx = idx
                                                        localCues[idx].name = "Custom Section"
                                                        localCues[idx].color = colorForCue(name: "Custom Section")
                                                    } else {
                                                        localCues[idx].name = newName
                                                        localCues[idx].color = colorForCue(name: newName)
                                                    }
                                                }
                                            )) {
                                                ForEach(cueTypeOptions, id: \.self) { opt in
                                                    Text(opt).tag(opt)
                                                }
                                                Divider()
                                                Text("Custom (Personalizado)...").tag("__custom__")
                                            }
                                            .pickerStyle(MenuPickerStyle())
                                            .frame(width: 120)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    
                                    // Compasso (Bar #) com Stepper de Inteiros e Meios Compassos
                                    HStack(spacing: 3) {
                                        Button(action: {
                                            if localCues[idx].bar > 1.0 {
                                                pushLocalUndo()
                                                localCues[idx].bar = max(1.0, localCues[idx].bar - 1.0)
                                                recalculateCueTimes()
                                            }
                                        }) {
                                            Text("-1")
                                                .font(.system(size: 9, weight: .bold))
                                                .frame(width: 20, height: 22)
                                                .background(Color.white.opacity(0.08))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(idx == 0)
                                        .help("Remove 1 whole bar")
                                        
                                        Button(action: {
                                            if localCues[idx].bar > 1.0 {
                                                pushLocalUndo()
                                                localCues[idx].bar = max(1.0, localCues[idx].bar - 0.5)
                                                recalculateCueTimes()
                                            }
                                        }) {
                                            Text("-½")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.cyan)
                                                .frame(width: 20, height: 22)
                                                .background(Color.cyan.opacity(0.12))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(idx == 0)
                                        .help("Remove half bar (-½ comp / 2 tempos)")
                                        
                                        Text("Bar \(formatBars(localCues[idx].bar))")
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundColor(.white)
                                            .frame(width: 58, alignment: .center)
                                        
                                        Button(action: {
                                            pushLocalUndo()
                                            localCues[idx].bar += 0.5
                                            recalculateCueTimes()
                                        }) {
                                            Text("+½")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundColor(.cyan)
                                                .frame(width: 20, height: 22)
                                                .background(Color.cyan.opacity(0.12))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(idx == 0)
                                        .help("Add half bar (+½ comp / 2 tempos - compasso quebrado)")
                                        
                                        Button(action: {
                                            pushLocalUndo()
                                            localCues[idx].bar += 1.0
                                            recalculateCueTimes()
                                        }) {
                                            Text("+1")
                                                .font(.system(size: 9, weight: .bold))
                                                .frame(width: 20, height: 22)
                                                .background(Color.white.opacity(0.08))
                                                .cornerRadius(4)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(idx == 0)
                                        .help("Add 1 whole bar")
                                    }
                                    .frame(width: 145, alignment: .center)
                                    
                                    // Tempo Calculado (MM:SS)
                                    Text(formatTime(localCues[idx].time))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .frame(width: 80, alignment: .leading)
                                    
                                    Spacer()
                                    
                                    // Ações: Ouvir / Remover
                                    HStack(spacing: 8) {
                                        Button(action: {
                                            state.triggerCue(idx: idx, quantize: false)
                                            if !state.isPlaying { state.playPause() }
                                        }) {
                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 16))
                                                .foregroundColor(.green)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .help("Play from this section with voice guide lead-in")
                                        
                                        Button(action: {
                                            if localCues.count > 1 && idx > 0 {
                                                pushLocalUndo()
                                                localCues.remove(at: idx)
                                                recalculateCueTimes()
                                            }
                                        }) {
                                            Image(systemName: "trash")
                                                .font(.system(size: 12))
                                                .foregroundColor(idx > 0 ? Color.red.opacity(0.8) : Color.clear)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(idx == 0)
                                        .help("Delete section")
                                    }
                                    .frame(width: 70, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.04))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 20)
                        
                        // Botão Adicionar Seção
                        Button(action: {
                            pushLocalUndo()
                            let lastBar = localCues.last?.bar ?? 1.0
                            let newBar = lastBar + 8.0
                            let secPerBar = calculateSecPerBar()
                            let newTime = Double(newBar - 1.0) * secPerBar
                            let nextName = getNextDefaultName()
                            let newCue = CueSection(
                                id: "cue_\(UUID().uuidString.prefix(8))",
                                name: nextName,
                                time: round(newTime * 100) / 100,
                                bar: newBar,
                                color: colorForCue(name: nextName),
                                waveform: nil
                            )
                            localCues.append(newCue)
                            recalculateCueTimes()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text("Add New Section")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(Color.cyan.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                    }
                }
                .padding(.bottom, 20)
            }
            
            Divider().background(Color.white.opacity(0.1))
            
            // Footer: Cancelar e Salvar
            HStack {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.gray)
                
                Spacer()
                
                Button(action: {
                    if let bpmVal = Double(localBpmText.replacingOccurrences(of: ",", with: ".")) {
                        state.saveSongEditor(bpm: bpmVal, timeSignature: localTimeSignature, cues: localCues)
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("Save Changes")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(16)
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        }
        .frame(width: 760, height: 600)
        .background(Color(red: 0.09, green: 0.09, blue: 0.10))
        .sheet(isPresented: $state.isCoverPickerPresented) {
            CoverPickerSheetView(state: state)
        }
        .onAppear {
            localBpmText = formatBpm(state.bpm)
            localTimeSignature = state.timeSignature
            localCues = state.currentCues
            localUndoStack.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SongEditorUndo"))) { _ in
            undoLocal()
        }
        .onChange(of: state.currentCues.count) { _, _ in
            localCues = state.currentCues
        }
    }
    
    private func calculateSecPerBar() -> Double {
        guard let bpm = Double(localBpmText.replacingOccurrences(of: ",", with: ".")), bpm > 20 else { return 2.0 }
        let beatsPerBar: Double = {
            let parts = localTimeSignature.split(separator: "/")
            if let first = parts.first, let num = Double(first) { return num }
            return 4.0
        }()
        let secPerBeat = 60.0 / bpm
        return secPerBeat * beatsPerBar
    }
    
    private func recalculateCueTimes() {
        let secPerBar = calculateSecPerBar()
        for i in 0..<localCues.count {
            if i == 0 {
                localCues[i].bar = 1.0
                localCues[i].time = 0.0
            } else {
                let bar = max(localCues[i - 1].bar + 0.5, localCues[i].bar)
                localCues[i].bar = bar
                localCues[i].time = round(Double(bar - 1.0) * secPerBar * 100) / 100
            }
        }
        localCues.sort { $0.bar < $1.bar }
    }
    
    private func getNextDefaultName() -> String {
        let count = localCues.count
        if count == 1 { return "Verse 1" }
        if count == 2 { return "Chorus" }
        if count == 3 { return "Verse 2" }
        if count == 4 { return "Chorus" }
        if count == 5 { return "Bridge" }
        if count == 6 { return "Chorus" }
        return "Ending"
    }
    
    private func formatTime(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// ==========================================
// 11. INICIALIZAÇÃO NATIVA APPKIT
// ==========================================

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var window: NSWindow!
    private var recentSetlistsSubmenu: NSMenu?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        
        let contentView = PlaybackAppView()
        
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 900, height: 440)
        
        window.center()
        window.title = PlaybackState.shared.currentSetlistName.isEmpty ? "VS Control" : PlaybackState.shared.currentSetlistName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        setupTitleBinding()
    }
    
    private func setupTitleBinding() {
        PlaybackState.shared.$currentSetlistName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newName in
                self?.window?.title = newName.isEmpty ? "VS Control" : newName
            }
            .store(in: &cancellables)
    }
    
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        
        // 1. App Menu (VS Control com Atalho Cmd+Q)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "VS Control")
        
        let aboutItem = NSMenuItem(title: "About VS Control", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())
        
        let hideItem = NSMenuItem(title: "Hide VS Control", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        
        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit VS Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        
        // 2. File Menu (Setlists: New, Open, Open Recent, Save, Save As)
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        
        // New Setlist (Cmd+N)
        let newItem = NSMenuItem(title: "New Setlist", action: #selector(newSetlistAction), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(newItem)
        
        // Open Setlist (Cmd+O)
        let openItem = NSMenuItem(title: "Open Setlist...", action: #selector(openSetlistAction), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        
        // Open Recent Submenu
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)
        self.recentSetlistsSubmenu = recentMenu
        rebuildRecentSetlistsMenu(recentMenu)
        
        fileMenu.addItem(NSMenuItem.separator())
        
        // Save Setlist (Cmd+S)
        let saveItem = NSMenuItem(title: "Save Setlist", action: #selector(saveSetlistAction), keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)
        
        // Save Setlist As... (Shift+Cmd+S)
        let saveAsItem = NSMenuItem(title: "Save Setlist As...", action: #selector(saveSetlistAsAction), keyEquivalent: "S")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)
        
        fileMenuItem.submenu = fileMenu
        
        // 3. Window Menu (Cmd+W para fechar janela, Cmd+M para minimizar)
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        let closeItem = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        let miniItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(miniItem)
        windowMenuItem.submenu = windowMenu
        
        NSApp.mainMenu = mainMenu
    }
    
    // NSMenuDelegate
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == recentSetlistsSubmenu {
            rebuildRecentSetlistsMenu(menu)
        }
    }
    
    private func rebuildRecentSetlistsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = PlaybackState.shared.getRecentSetlistPaths()
        if recents.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Setlists", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for path in recents {
                let url = URL(fileURLWithPath: path)
                let displayName = url.deletingPathExtension().lastPathComponent
                let item = NSMenuItem(title: displayName, action: #selector(openRecentItemAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentMenuAction), keyEquivalent: "")
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }
    
    @objc func newSetlistAction() {
        PlaybackState.shared.newSetlist()
        updateWindowTitle()
    }
    
    @objc func openSetlistAction() {
        PlaybackState.shared.openSetlistDialog { [weak self] in
            self?.updateWindowTitle()
        }
    }
    
    @objc func saveSetlistAction() {
        PlaybackState.shared.saveSetlist { [weak self] in
            self?.updateWindowTitle()
        }
    }
    
    @objc func saveSetlistAsAction() {
        PlaybackState.shared.saveSetlistAs { [weak self] in
            self?.updateWindowTitle()
        }
    }
    
    @objc func openRecentItemAction(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        DispatchQueue.main.async {
            PlaybackState.shared.loadSetlistFrom(url: URL(fileURLWithPath: path))
            self.updateWindowTitle()
        }
    }
    
    @objc func clearRecentMenuAction() {
        PlaybackState.shared.clearRecentSetlists()
    }
    
    func updateWindowTitle() {
        let name = PlaybackState.shared.currentSetlistName
        window?.title = name.isEmpty ? "VS Control" : name
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
