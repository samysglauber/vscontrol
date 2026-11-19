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

final class NativeMIDIReceiver {
    static let shared = NativeMIDIReceiver()
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
                        NativeMappingManager.shared.handleMIDITrigger(channel: channel, number: d1, isCC: false)
                    }
                }
                // Control Change (CC) com valor > 0
                else if msgType == 0xB0 && d2 > 0 {
                    DispatchQueue.main.async {
                        NativeMappingManager.shared.handleMIDITrigger(channel: channel, number: d1, isCC: true)
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

final class NativeMappingManager: ObservableObject {
    static let shared = NativeMappingManager()
    
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
    
    private init() {
        loadMappings()
        _ = NativeMIDIReceiver.shared // Inicializa escuta CoreMIDI nativa
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
        // 1. Se estiver no modo de Mapeamento de Teclado:
        if mode == .key {
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
            // Qualquer outra tecla: mapeia para a ação selecionada
            if let action = selectedAction {
                let name = keyDisplayName(for: event)
                assignKey(action: action, keyCode: event.keyCode, name: name)
                return true
            }
            return false
        }
        
        // 2. Se estiver em modo de execução normal (mode == .none):
        if mode == .none {
            // Procura se a tecla pressionada possui ação mapeada
            for (action, mapping) in keyMappings where mapping.keyCode == event.keyCode {
                executeAction(action)
                return true
            }
        }
        
        return false
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
            NativeAudioEngine.shared.stop()
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
                let nextIdx = min(state.currentCues.count - 1, state.currentCueIdx + 1)
                state.triggerCue(idx: nextIdx, quantize: true)
            }
        case .prevSection:
            if !state.currentCues.isEmpty {
                let prevIdx = max(0, state.currentCueIdx - 1)
                state.triggerCue(idx: prevIdx, quantize: true)
            }
        case .toggleLoop:
            state.toggleLoop()
        case .toggleInfinite:
            state.toggleInfinite()
        case .muteClick:
            state.toggleClickMute()
        case .muteTracks:
            state.toggleVsMute()
        case .fadeTracks:
            state.toggleFadeTracks()
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
        if let data = UserDefaults.standard.data(forKey: keyStorageKey),
           let loaded = try? JSONDecoder().decode([MappableAction: KeyMapping].self, from: data) {
            self.keyMappings = loaded
        }
        if let data = UserDefaults.standard.data(forKey: midiStorageKey),
           let loaded = try? JSONDecoder().decode([MappableAction: MIDIMapping].self, from: data) {
            self.midiMappings = loaded
        }
    }
}

// ==========================================
// 6. MODIFICADOR VISUAL DE BOTÕES MAPEÁVEIS
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
    @ObservedObject var mapping = NativeMappingManager.shared
    
    private var isKey: Bool { mapping.mode == .key }
    private var accentColor: Color {
        isKey ? Color(red: 1.0, green: 0.65, blue: 0.15) : Color(red: 0.60, green: 0.45, blue: 1.0)
    }
    private var isSelected: Bool { mapping.selectedAction == action }
    
    private var mappedText: String? {
        if isKey {
            return mapping.keyMappings[action]?.displayName
        } else {
            return mapping.midiMappings[action]?.displayName
        }
    }
    
    func body(content: Content) -> some View {
        if mapping.mode == .none {
            content
        } else {
            ZStack(alignment: .topTrailing) {
                content
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            // Foco de Aprendizado: Contorno sólido nítido bem definido sem pulsação/brilho
                            .stroke(
                                isSelected ? accentColor : accentColor.opacity(0.35),
                                lineWidth: isSelected ? 2.2 : 1.0
                            )
                    )
                
                // Badge com a tecla ou MIDI mapeado
                if let text = mappedText {
                    Text(text)
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(3.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5)
                                .stroke(accentColor, lineWidth: 0.8)
                        )
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                } else {
                    Text("+")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(accentColor.opacity(0.8))
                        .frame(width: 13, height: 13)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(accentColor.opacity(0.4), lineWidth: 0.6)
                        )
                        .offset(x: 3, y: -3)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                mapping.selectAction(action)
            }
        }
    }
}

// ==========================================
// 7. BARRA INFERIOR DE MAPEAMENTO NO MODO EDIT
// ==========================================

struct BottomMappingBar: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject var mapping = NativeMappingManager.shared
    
    var body: some View {
        HStack(spacing: 12) {
            // Seletor de Modo: Mixer vs KEY MAP vs MIDI MAP
            HStack(spacing: 4) {
                // Modo Mixer
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapping.mode = .none
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.vertical.3")
                            .font(.system(size: 11))
                        Text("Mixer")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(mapping.mode == .none ? .white : .white.opacity(0.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(mapping.mode == .none ? Color.white.opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                
                // Modo KEY MAP
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapping.mode = (mapping.mode == .key ? .none : .key)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 11))
                        Text("KEY MAP")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15) : .white.opacity(0.6))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.20) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                // Modo MIDI MAP
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mapping.mode = (mapping.mode == .midi ? .none : .midi)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 11))
                        Text("MIDI MAP")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(mapping.mode == .midi ? Color(red: 0.65, green: 0.50, blue: 1.0) : .white.opacity(0.6))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(mapping.mode == .midi ? Color(red: 0.60, green: 0.45, blue: 1.0).opacity(0.20) : Color.clear)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(mapping.mode == .midi ? Color(red: 0.60, green: 0.45, blue: 1.0).opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(2.5)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
            
            // Divisor
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1, height: 18)
            
            // Texto de Instrução Dinâmico
            if mapping.mode != .none {
                HStack(spacing: 6) {
                    if let selected = mapping.selectedAction {
                        Text("Mapeando:")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.5))
                        Text(selected.displayName)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(mapping.mode == .key ? Color(red: 1.0, green: 0.65, blue: 0.15) : Color(red: 0.65, green: 0.50, blue: 1.0))
                        
                        Text(mapping.mode == .key ? "➔ Aperte a tecla física (Delete para limpar)" : "➔ Pise no pedal / envie MIDI (Delete para limpar)")
                            .font(.system(size: 10.5))
                            .foregroundColor(.white.opacity(0.65))
                    } else {
                        Text(mapping.mode == .key ? "Clique em qualquer botão marcado na tela para associar uma tecla" : "Clique em qualquer botão marcado na tela para associar um comando MIDI")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
                
                Spacer()
                
                // Botão de Limpeza do Botão Selecionado
                if mapping.selectedAction != nil {
                    Button(action: { mapping.clearSelectedMapping() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "delete.left")
                                .font(.system(size: 10))
                            Text("Clear")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.red.opacity(0.20))
                        .cornerRadius(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.red.opacity(0.4), lineWidth: 0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Clear mapping for selected button (or press Delete)")
                }
                
                // Botão de Limpar Tudo
                Button(action: { mapping.clearAllCurrentMode() }) {
                    Text("Clear All")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Clear all mappings for current mode")
            } else {
                Text("Selecione KEY MAP ou MIDI MAP para vincular atalhos e pedaleiras aos botões do app")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 38)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
    }
}
