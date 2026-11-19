import Foundation
import SwiftUI
import AppKit
import CoreMIDI

// ==========================================
// 1. AÇÕES MAPEÁVEIS NO VS CONTROL
// ==========================================

enum MappableAction: String, CaseIterable, Codable, Hashable {
    case playPause = "play_pause"
    case stop = "stop"
    case restart = "restart"
    case nextSong = "next_song"
    case prevSong = "prev_song"
    case nextSection = "next_section"
    case prevSection = "prev_section"
    case toggleLoop = "toggle_loop"
    case toggleInfinite = "toggle_infinite"
    case muteClick = "mute_click"
    case muteTracks = "mute_tracks"
    case fadeTracks = "fade_tracks"
    case song1 = "song_1"
    case song2 = "song_2"
    case song3 = "song_3"
    case song4 = "song_4"
    case song5 = "song_5"
    case song6 = "song_6"
    case song7 = "song_7"
    case song8 = "song_8"
    
    var displayName: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .stop: return "Stop"
        case .restart: return "Restart"
        case .nextSong: return "Next Song"
        case .prevSong: return "Prev Song"
        case .nextSection: return "Next Section"
        case .prevSection: return "Prev Section"
        case .toggleLoop: return "Loop 1x"
        case .toggleInfinite: return "Infinite Loop"
        case .muteClick: return "Mute Click"
        case .muteTracks: return "Mute Tracks"
        case .fadeTracks: return "Fade Tracks"
        case .song1: return "Song 1"
        case .song2: return "Song 2"
        case .song3: return "Song 3"
        case .song4: return "Song 4"
        case .song5: return "Song 5"
        case .song6: return "Song 6"
        case .song7: return "Song 7"
        case .song8: return "Song 8"
        }
    }
}

// ==========================================
// 2. MODOS DE MAPEAMENTO
// ==========================================

enum MappingMode: String, Equatable {
    case none
    case key
    case midi
}

// ==========================================
// 3. ESTRUTURAS DE MAPEAMENTO DE TECLADO E MIDI
// ==========================================

struct KeyMapping: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let displayName: String
}

struct MIDIMapping: Codable, Equatable, Hashable {
    let isCC: Bool
    let channel: UInt8
    let number: UInt8
    let displayName: String
}

// ==========================================
// 4. RECEPTOR NATIVO DE ENTRADAS COREMIDI
// ==========================================

typealias NativeMIDIReceiver = MIDIReceiver
typealias NativeMappingManager = MappingManager

final class MIDIReceiver {
    static let shared = MIDIReceiver()
    private var client: MIDIClientRef = 0
    private var inPort: MIDIPortRef = 0
    private var connectedSources: Set<MIDIEndpointRef> = []
    
    private init() {
        setupReceiver()
    }
    
    func setupReceiver() {
        var status = MIDIClientCreateWithBlock("VS Control MIDI In Client" as CFString, &client) { [weak self] notifyRef in
            self?.handleNotification(notifyRef.pointee)
        }
        guard status == noErr else { return }
        
        status = MIDIInputPortCreateWithBlock(client, "VS Control InPort" as CFString, &inPort) { [weak self] packetList, srcConnRefCon in
            self?.handlePacketList(packetList.pointee)
        }
        guard status == noErr else { return }
        
        connectAllSources()
    }
    
    func connectAllSources() {
        guard inPort != 0 else { return }
        let n = MIDIGetNumberOfSources()
        for i in 0..<n {
            let src = MIDIGetSource(i)
            if src != 0 && !connectedSources.contains(src) {
                MIDIPortConnectSource(inPort, src, nil)
                connectedSources.insert(src)
            }
        }
    }
    
    private func handleNotification(_ message: MIDINotification) {
        if message.messageID == .msgObjectAdded || message.messageID == .msgSetupChanged {
            DispatchQueue.main.async { [weak self] in
                self?.connectAllSources()
            }
        }
    }
    
    private func handlePacketList(_ packetList: MIDIPacketList) {
        var packet = packetList.packet
        for _ in 0..<packetList.numPackets {
            let len = Int(packet.length)
            if len >= 2 {
                // Leitura dos bytes do pacote MIDI
                var d0: UInt8 = 0
                var d1: UInt8 = 0
                var d2: UInt8 = 0
                
                withUnsafePointer(to: packet.data) { ptr in
                    let raw = UnsafeRawPointer(ptr)
                    d0 = raw.load(fromByteOffset: 0, as: UInt8.self)
                    d1 = raw.load(fromByteOffset: 1, as: UInt8.self)
                    d2 = len >= 3 ? raw.load(fromByteOffset: 2, as: UInt8.self) : 0
                }
                
                let msgType = d0 & 0xF0
                let channel = (d0 & 0x0F) + 1
                
                // Note On com velocidade > 0
                if msgType == 0x90 && d2 > 0 {
                    DispatchQueue.main.async {
                        MappingManager.shared.handleMIDITrigger(channel: channel, number: d1, isCC: false)
                    }
                }
                // Control Change (CC) com valor > 0
                else if msgType == 0xB0 && d2 > 0 {
                    DispatchQueue.main.async {
                        MappingManager.shared.handleMIDITrigger(channel: channel, number: d1, isCC: true)
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}

// ==========================================
// 5. GERENCIADOR CENTRAL DE MAPEAMENTO
// ==========================================

final class MappingManager: ObservableObject {
    static let shared = MappingManager()
    
    @Published var mode: MappingMode = .none {
        didSet {
            if mode == .none {
                selectedAction = nil
            }
        }
    }
    
    @Published var selectedAction: MappableAction? = nil
    @Published var keyMappings: [MappableAction: KeyMapping] = [:]
    @Published var midiMappings: [MappableAction: MIDIMapping] = [:]
    
    private let keyStorageKey = "vs_control_key_mappings"
    private let midiStorageKey = "vs_control_midi_mappings"
    
    // Atalhos nativos padrão do VS Control (Space, I, L, 0, 1..8, etc.)
    static let defaultKeyMappings: [MappableAction: KeyMapping] = [
        .playPause: KeyMapping(keyCode: 49, displayName: "Space"),
        .toggleInfinite: KeyMapping(keyCode: 34, displayName: "I"),
        .toggleLoop: KeyMapping(keyCode: 37, displayName: "L"),
        .fadeTracks: KeyMapping(keyCode: 29, displayName: "0"),
        .song1: KeyMapping(keyCode: 18, displayName: "1"),
        .song2: KeyMapping(keyCode: 19, displayName: "2"),
        .song3: KeyMapping(keyCode: 20, displayName: "3"),
        .song4: KeyMapping(keyCode: 21, displayName: "4"),
        .song5: KeyMapping(keyCode: 23, displayName: "5"),
        .song6: KeyMapping(keyCode: 22, displayName: "6"),
        .song7: KeyMapping(keyCode: 26, displayName: "7"),
        .song8: KeyMapping(keyCode: 28, displayName: "8"),
        .prevSong: KeyMapping(keyCode: 126, displayName: "↑"),
        .nextSong: KeyMapping(keyCode: 125, displayName: "↓"),
        .prevSection: KeyMapping(keyCode: 123, displayName: "←"),
        .nextSection: KeyMapping(keyCode: 124, displayName: "→")
    ]
    
    private init() {
        loadMappings()
        _ = MIDIReceiver.shared // Inicializa escuta CoreMIDI nativa
    }
    
    func resetKeyDefaults() {
        self.keyMappings = Self.defaultKeyMappings
        self.selectedAction = nil
        saveMappings()
    }
    
    // MARK: - Seleção e Limpeza
    
    func selectAction(_ action: MappableAction) {
        guard mode != .none else { return }
        if selectedAction == action {
            selectedAction = nil
        } else {
            selectedAction = action
        }
    }
    
    func clearSelectedMapping() {
        guard let action = selectedAction else { return }
        clearMapping(for: action)
    }
    
    func clearMapping(for action: MappableAction) {
        if mode == .key {
            keyMappings.removeValue(forKey: action)
        } else if mode == .midi {
            midiMappings.removeValue(forKey: action)
        }
        saveMappings()
    }
    
    func clearAllCurrentMode() {
        if mode == .key {
            keyMappings.removeAll()
        } else if mode == .midi {
            midiMappings.removeAll()
        }
        selectedAction = nil
        saveMappings()
    }
    
    // MARK: - Atribuição de Teclado
    
    func assignKey(action: MappableAction, keyCode: UInt16, name: String) {
        // Tecla Enter/Return (36) e Keypad Enter (76) são estritamente reservadas pelo sistema e não podem ser mapeadas
        guard keyCode != 36 && keyCode != 76 else { return }
        
        // Remove qualquer ação anterior mapeada para a mesma tecla
        for (act, mapping) in keyMappings where mapping.keyCode == keyCode {
            keyMappings.removeValue(forKey: act)
        }
        keyMappings[action] = KeyMapping(keyCode: keyCode, displayName: name)
        saveMappings()
    }
    
    // MARK: - Atribuição de MIDI
    
    func assignMIDI(action: MappableAction, channel: UInt8, number: UInt8, isCC: Bool) {
        let typeStr = isCC ? "CC \(number)" : "Note \(number)"
        let disp = "Ch\(channel) \(typeStr)"
        
        // Remove qualquer ação anterior com a mesma assinatura MIDI
        for (act, mapping) in midiMappings where mapping.channel == channel && mapping.number == number && mapping.isCC == isCC {
            midiMappings.removeValue(forKey: act)
        }
        midiMappings[action] = MIDIMapping(isCC: isCC, channel: channel, number: number, displayName: disp)
        saveMappings()
    }
    
    // MARK: - Tratamento de Eventos de Teclado
    
    func handleKeyDown(event: NSEvent) -> Bool {
        // 1. Se estiver no modo de Mapeamento (KEY MAP ou MIDI MAP):
        if mode != .none {
            // Tecla Delete / Backspace (51) ou Forward Delete (117): limpa o botão selecionado!
            if event.keyCode == 51 || event.keyCode == 117 {
                if let action = selectedAction {
                    clearMapping(for: action)
                    return true
                }
            }
            // Tecla Esc (53): cancela a seleção atual
            if event.keyCode == 53 {
                if selectedAction != nil {
                    selectedAction = nil
                    return true
                }
            }
            // Tecla Enter/Return (36) ou Keypad Enter (76): estritamente reservadas pelo sistema e não podem ser mapeadas
            if event.keyCode == 36 || event.keyCode == 76 {
                return true // Consome no modo de mapeamento para não disparar saltos acidentais
            }
            // No modo KEY MAP, qualquer outra tecla atribui ao botão selecionado
            if mode == .key {
                if let action = selectedAction {
                    let name = keyDisplayName(for: event)
                    assignKey(action: action, keyCode: event.keyCode, name: name)
                    return true
                }
            }
            return false
        }
        
        // 2. Se estiver em modo de execução normal (mode == .none):
        if mode == .none {
            // Procura se a tecla pressionada possui ação mapeada
            for (action, mapping) in keyMappings {
                if mapping.keyCode == event.keyCode {
                    executeAction(action)
                    return true
                }
                // Suporte para teclado numérico equivalente a 0..8
                if let alt = keypadAlternative(for: mapping.keyCode), alt == event.keyCode {
                    executeAction(action)
                    return true
                }
            }
        }
        
        return false
    }
    
    private func keypadAlternative(for keyCode: UInt16) -> UInt16? {
        switch keyCode {
        case 18: return 83 // 1
        case 19: return 84 // 2
        case 20: return 85 // 3
        case 21: return 86 // 4
        case 23: return 87 // 5
        case 22: return 88 // 6
        case 26: return 89 // 7
        case 28: return 91 // 8
        case 29: return 82 // 0
        default: return nil
        }
    }
    
    // MARK: - Tratamento de Eventos MIDI Recebidos
    
    func handleMIDITrigger(channel: UInt8, number: UInt8, isCC: Bool) {
        // 1. Se estiver no modo de Mapeamento MIDI e tiver botão focado:
        if mode == .midi {
            if let action = selectedAction {
                assignMIDI(action: action, channel: channel, number: number, isCC: isCC)
            }
            return
        }
        
        // 2. Se estiver em execução normal:
        if mode == .none {
            for (action, mapping) in midiMappings where mapping.channel == channel && mapping.number == number && mapping.isCC == isCC {
                executeAction(action)
                return
            }
        }
    }
    
    // MARK: - Execução da Ação no PlaybackState
    
    func executeAction(_ action: MappableAction) {
        let state = PlaybackState.shared
        switch action {
        case .playPause:
            state.playPause()
        case .stop:
            AudioEngine.shared.stop()
            state.isPlaying = false
            state.currentSeconds = 0.0
            state.currentCueIdx = 0
        case .restart:
            state.restart()
        case .nextSong:
            state.switchToNextSong()
        case .prevSong:
            state.switchToPreviousSong()
        case .nextSection:
            if !state.currentCues.isEmpty {
                let curIdx: Int = {
                    if let f = state.focusedCueIdx { return f }
                    if let q = state.queuedCueIdx { return q }
                    return state.currentCueIdx
                }()
                let nextIdx = min(state.currentCues.count - 1, curIdx + 1)
                state.focusedCueIdx = nextIdx
            }
        case .prevSection:
            if !state.currentCues.isEmpty {
                let curIdx: Int = {
                    if let f = state.focusedCueIdx { return f }
                    if let q = state.queuedCueIdx { return q }
                    return state.currentCueIdx
                }()
                let prevIdx = max(0, curIdx - 1)
                state.focusedCueIdx = prevIdx
            }
        case .toggleLoop:
            if let focusedIdx = state.focusedCueIdx {
                state.toggleLoop(cueIdx: focusedIdx)
            } else {
                state.toggleLoop()
            }
        case .toggleInfinite:
            if let focusedIdx = state.focusedCueIdx {
                state.toggleInfinite(cueIdx: focusedIdx)
            } else {
                state.toggleInfinite()
            }
        case .muteClick:
            state.toggleClickMute()
        case .muteTracks:
            state.toggleVsMute()
        case .fadeTracks:
            state.toggleFadeTracks(duration: 3.0)
        case .song1: state.playSetlistSong(at: 0)
        case .song2: state.playSetlistSong(at: 1)
        case .song3: state.playSetlistSong(at: 2)
        case .song4: state.playSetlistSong(at: 3)
        case .song5: state.playSetlistSong(at: 4)
        case .song6: state.playSetlistSong(at: 5)
        case .song7: state.playSetlistSong(at: 6)
        case .song8: state.playSetlistSong(at: 7)
        }
    }
    
    // MARK: - Utilitário de Nomes de Teclas Amigáveis
    
    func keyDisplayName(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 76: return "Enter"
        case 48: return "Tab"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                return chars.uppercased()
            }
            return "Key \(event.keyCode)"
        }
    }
    
    // MARK: - Persistência em Disco (UserDefaults)
    
    private func saveMappings() {
        if let data = try? JSONEncoder().encode(keyMappings) {
            UserDefaults.standard.set(data, forKey: keyStorageKey)
        }
        if let data = try? JSONEncoder().encode(midiMappings) {
            UserDefaults.standard.set(data, forKey: midiStorageKey)
        }
    }
    
    private func loadMappings() {
        let seeded = UserDefaults.standard.bool(forKey: "vs_control_key_mappings_seeded_v3")
        if seeded,
           let data = UserDefaults.standard.data(forKey: keyStorageKey),
           let loaded = try? JSONDecoder().decode([MappableAction: KeyMapping].self, from: data),
           !loaded.isEmpty {
            // Garante que Enter/Return nunca faça parte dos atalhos carregados
            self.keyMappings = loaded.filter { $0.value.keyCode != 36 && $0.value.keyCode != 76 }
        } else {
            // Inicializa com os atalhos nativos padrão do VS Control
            self.keyMappings = Self.defaultKeyMappings
            UserDefaults.standard.set(true, forKey: "vs_control_key_mappings_seeded_v3")
            saveMappings()
        }
        
        if let data = UserDefaults.standard.data(forKey: midiStorageKey),
           let loaded = try? JSONDecoder().decode([MappableAction: MIDIMapping].self, from: data) {
            self.midiMappings = loaded
        } else {
            self.midiMappings = [:]
        }
    }
}

// ==========================================
// 6.1 BADGE NATIVA DE INDICADOR DE ATALHO
// ==========================================

struct MappingBadgeView: View {
    let text: String
    let accentColor: Color
    
    var body: some View {
        HStack(spacing: 2) {
            if text == "Space" || text == "␣" {
                // Ícone nativo de Barra de Espaço do macOS
                Image(systemName: "space")
                    .font(.system(size: 8.5, weight: .black))
            } else {
                Text(badgeText)
                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundColor(Color.white)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .frame(minWidth: 15)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.95))
        .cornerRadius(3.5)
        .overlay(
            RoundedRectangle(cornerRadius: 3.5)
                .stroke(accentColor.opacity(0.90), lineWidth: 1.0)
        )
        .fixedSize()
        .offset(x: 3, y: -3)
        .allowsHitTesting(false)
    }
    
    private var badgeText: String {
        // Encurtamento inteligente para canais e notas MIDI
        if text.contains("Note ") {
            return text.replacingOccurrences(of: "Ch", with: "")
                       .replacingOccurrences(of: " Note ", with: ":N")
        }
        if text.contains("CC ") {
            return text.replacingOccurrences(of: "Ch", with: "")
                       .replacingOccurrences(of: " CC ", with: ":CC")
        }
        return text
    }
}

// ==========================================
// 6.2 MODIFICADOR VISUAL DE BOTÕES MAPEÁVEIS
// ==========================================

extension View {
    @ViewBuilder
    func mappableControl(_ action: MappableAction?, cornerRadius: CGFloat = 8) -> some View {
        if let action = action {
            self.modifier(MappableControlModifier(action: action, cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}

struct MappableControlModifier: ViewModifier {
    let action: MappableAction
    var cornerRadius: CGFloat = 8
    @ObservedObject var mapping = MappingManager.shared
    
    private var isKey: Bool { mapping.mode == .key }
    private var isMidi: Bool { mapping.mode == .midi }
    private var isMappingActive: Bool { mapping.mode != .none }
    
    // Cores fiéis ao estilo DAW / Ableton Live: Âmbar/Laranja no KEY MAP e Roxo/Azulado no MIDI MAP
    private var accentColor: Color {
        isKey ? Color(red: 0.95, green: 0.55, blue: 0.15) : Color(red: 0.60, green: 0.45, blue: 1.0)
    }
    private var isSelected: Bool { mapping.selectedAction == action }
    
    private var mappedText: String? {
        if isKey {
            return mapping.keyMappings[action]?.displayName
        } else if isMidi {
            return mapping.midiMappings[action]?.displayName
        }
        return nil
    }
    
    func body(content: Content) -> some View {
        if !isMappingActive {
            content
        } else {
            content
                .overlay(
                    // 1. Tint característico de mapeamento estilo Ableton Live (âmbar ou roxo)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(isSelected ? accentColor.opacity(0.38) : accentColor.opacity(0.20))
                        .allowsHitTesting(false)
                )
                .overlay(
                    // 2. Contorno sólido nítido (SEM pulsação ou brilho difuso)
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            isSelected ? Color.white : accentColor.opacity(0.40),
                            lineWidth: isSelected ? 2.5 : 1.0
                        )
                        .allowsHitTesting(false)
                )
                .overlay(
                    // 3. Camada transparente cobrindo 100% da área do botão para capturar clique
                    Color.black.opacity(0.001)
                        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .onTapGesture {
                            mapping.selectAction(action)
                        }
                )
                .overlay(
                    // 4. Badge escura com borda no acento do modo e ícone nativo de espaço (SOMENTE se houver atalho!)
                    Group {
                        if let text = mappedText {
                            MappingBadgeView(text: text, accentColor: accentColor)
                        }
                    },
                    alignment: .topTrailing
                )
        }
    }
}

// ==========================================
// 7. CÁPSULA FLUTUANTE DE MAPEAMENTO (MODO EDIT)
// ==========================================

typealias BottomMappingBar = FloatingMappingHUD

struct FloatingMappingHUD: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var mapping = MappingManager.shared
    @State private var showingClearConfirmation: Bool = false
    
    var body: some View {
        HStack(spacing: 3) {
            // Botão Key Mapping
            Button(action: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    mapping.mode = (mapping.mode == .key ? .none : .key)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11, weight: .medium))
                    Text("Key Mapping")
                        .font(.system(size: 11, weight: mapping.mode == .key ? .semibold : .medium))
                }
                .foregroundColor(mapping.mode == .key ? Color(red: 1.0, green: 0.70, blue: 0.20) : .white.opacity(0.60))
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.24) : Color.white.opacity(0.001))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Toggle Key Mapping mode")
            
            // Botão MIDI Mapping
            Button(action: {
                withAnimation(.easeInOut(duration: 0.16)) {
                    mapping.mode = (mapping.mode == .midi ? .none : .midi)
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 11, weight: .medium))
                    Text("MIDI Mapping")
                        .font(.system(size: 11, weight: mapping.mode == .midi ? .semibold : .medium))
                }
                .foregroundColor(mapping.mode == .midi ? Color(red: 0.70, green: 0.55, blue: 1.0) : .white.opacity(0.60))
                .padding(.horizontal, 11)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(mapping.mode == .midi ? Color(red: 0.60, green: 0.45, blue: 1.0).opacity(0.24) : Color.white.opacity(0.001))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(mapping.mode == .midi ? Color(red: 0.60, green: 0.45, blue: 1.0).opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Toggle MIDI Mapping mode")
            
            // Botão Limpar Mapeamento (visível quando algum modo de mapeamento estiver ativo)
            if mapping.mode != .none {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)
                
                Button(action: {
                    showingClearConfirmation = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5))
                        Text(mapping.mode == .key ? "Clear Keys" : "Clear MIDI")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(Color.red.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5.5)
                    .background(Color.red.opacity(0.14))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.35), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(PlainButtonStyle())
                .help(mapping.mode == .key ? "Clear all keyboard mappings" : "Clear all MIDI mappings")
            }
        }
        .padding(3)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.45)
            }
        )
        .cornerRadius(9)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
        .fixedSize(horizontal: true, vertical: true)
        .alert(isPresented: $showingClearConfirmation) {
            Alert(
                title: Text(mapping.mode == .key ? "Limpar Mapeamento de Teclado?" : "Limpar Mapeamento MIDI?"),
                message: Text(mapping.mode == .key ? "Tem certeza de que deseja apagar todos os atalhos de teclado mapeados?" : "Tem certeza de que deseja apagar todos os mapeamentos de comandos e notas MIDI?"),
                primaryButton: .destructive(Text("Limpar Tudo")) {
                    mapping.clearAllCurrentMode()
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
    }
}
