import SwiftUI
import AppKit
import Foundation
import Combine

// ==========================================
// JANELA DE CONFIGURAÇÕES (SETTINGS / Cmd + ,)
// 4 Abas: General, MIDI & Sync, Files & Library, Remote
// ==========================================

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case midiSync = "MIDI & Sync"
    case files = "Files & Library"
    case remote = "Remote"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .midiSync: return "cable.connector"
        case .files: return "folder.fill"
        case .remote: return "iphone.radiowaves.left.and.right"
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 570),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VSControlSettingsWindow")
        window.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        
        let settingsView = SettingsView()
        window.contentView = NSHostingView(rootView: settingsView)
        
        self.init(window: window)
    }
    
    func show() {
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var state: PlaybackState = PlaybackState.shared
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        VStack(spacing: 0) {
            // Header: Barra de Abas Nativa e Moderna no Topo
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTab = tab
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(selectedTab == tab ? .white : Color.gray)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                if selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.14))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                        )
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.white.opacity(0.03))
                                }
                            }
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
                .background(Color.white.opacity(0.08))
            
            // Conteúdo da Aba Ativa
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsTabView(state: state)
                    case .midiSync:
                        MidiSyncSettingsTabView(state: state)
                    case .files:
                        FilesLibrarySettingsTabView(state: state)
                    case .remote:
                        RemoteSettingsTabView(state: state)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 680, height: 570)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
    }
}

// ==========================================
// 1. ABA GENERAL (Áudio, Palco, Fade, Timeline)
// ==========================================

struct GeneralSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 18) {
            // Card 1: Áudio & Roteamento
            SettingsCardView(title: "ÁUDIO & ROTEAMENTO") {
                VStack(spacing: 12) {
                    // Dispositivo de Saída de Áudio
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Audio Device")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Dispositivo de saída CoreAudio ativo para reprodução")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { state.selectedDeviceId },
                            set: { state.selectOutputDevice(id: $0) }
                        )) {
                            ForEach(state.availableDevices) { dev in
                                Text(dev.name).tag(dev.id)
                            }
                        }
                        .frame(width: 210)
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Auto Pan Estéreo L/R
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto Pan (L/R)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Canal L: Click & Guia | Canal R: Multitrack/VS")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.autoPanStereo)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Fader Default Level
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fader Default Level")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Nível inicial padrão dos volumes ao carregar uma nova música")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Picker("", selection: $state.faderDefaultLevel) {
                            Text("100% (0 dB)").tag(1.0)
                            Text("80% (-2 dB)").tag(0.8)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 170)
                    }
                }
            }
            
            // Card 2: Palco & Reprodução
            SettingsCardView(title: "PALCO & REPRODUÇÃO") {
                VStack(spacing: 12) {
                    // Prevenir Suspensão do Mac
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep Screen Awake")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Impede que a tela e o Mac durmam durante o ensaio ou apresentação")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.keepScreenAwake)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Avanço Automático (Auto-Advance)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto-Advance")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Comportamento ao atingir o final de cada música da setlist")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Picker("", selection: $state.autoAdvance) {
                            Text("Parar no Fim").tag(false)
                            Text("Avançar / Seguir").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 210)
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Default Fade Out Duration
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default Fade Out Duration")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Tempo de atenuação suave ao pausar as tracks com fade")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultFadeDuration, in: 1.0...8.0, step: 0.5)
                                .frame(width: 120)
                            Text(String(format: "%.1fs", state.defaultFadeDuration))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Default Crossfade Duration
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default Crossfade Duration")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Tempo de sobreposição suave de transição entre músicas")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultCrossfadeDuration, in: 1.0...10.0, step: 0.5)
                                .frame(width: 120)
                            Text(String(format: "%.1fs", state.defaultCrossfadeDuration))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
            }
            
            // Card 3: Visual da Timeline
            SettingsCardView(title: "VISUAL DA TIMELINE") {
                VStack(spacing: 12) {
                    // Waveform Grid
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Waveform Grid")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Exibir divisórias verticais de compasso e tempos sobre a forma de onda")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.showWaveformGrid)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Default Timeline Zoom
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default Timeline Zoom")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Nível inicial de zoom aplicado ao abrir qualquer música")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Picker("", selection: $state.defaultTimelineZoom) {
                            Text("Fit").tag("fit")
                            Text("1x").tag("1x")
                            Text("2x").tag("2x")
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 170)
                    }
                }
            }
        }
    }
}

// ==========================================
// 2. ABA MIDI & SYNC (DAW OSC + MIDI Clock + Shortcuts)
// ==========================================

struct MidiSyncSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 18) {
            // Card 1: Sincronização com DAW (OSC)
            SettingsCardView(title: "SINCRONIZAÇÃO COM DAW (OSC)") {
                VStack(spacing: 12) {
                    // DAW Playback Sync
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DAW Playback Sync")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Envia comandos de transporte para iniciar e pausar a DAW simultaneamente")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.enableAbletonPlaySync)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Disparo no Tempo 1
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trigger at Beat 1 (Downbeat)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Aguarda o primeiro clique audível da contagem para disparar a DAW")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.triggerAtBeat1)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Envio de BPM e Fórmula de Compasso
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sync Tempo & Time Signature")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Atualiza o BPM e a fórmula de compasso da DAW no momento do disparo")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.syncTempoToDaw)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Configuração de Rede OSC
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("OSC Target Host / Port")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Endereço IP e porta UDP de comunicação com a DAW")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            TextField("IP", text: $state.oscHost)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(6)
                                .frame(width: 110)
                            Text(":")
                                .foregroundColor(.gray)
                            TextField("Port", value: $state.oscPort, formatter: NumberFormatter())
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(6)
                                .frame(width: 65)
                        }
                    }
                }
            }
            
            // Card 2: MIDI Beat Clock
            SettingsCardView(title: "MIDI BEAT CLOCK") {
                VStack(spacing: 12) {
                    // Enable MIDI Clock
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable MIDI Beat Clock")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Transmite pulsos 0xF8 a 24 PPQN para sincronizar metrônomos e pedais")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: $state.enableMidiClock)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Porta Virtual do Sistema
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Virtual MIDI Port")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Nome da porta criada automaticamente no CoreMIDI")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("VS Control Sync")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(6)
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Clock Offset Compensation
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Clock Offset Compensation")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Compensação fina em milissegundos para latência de hardware")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.midiClockOffsetMs, in: -100.0...100.0, step: 1.0)
                                .frame(width: 110)
                            Text(String(format: "%+.0f ms", state.midiClockOffsetMs))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(state.midiClockOffsetMs == 0 ? .gray : .white)
                                .frame(width: 58, alignment: .trailing)
                            if state.midiClockOffsetMs != 0 {
                                Button("Reset") {
                                    state.midiClockOffsetMs = 0
                                }
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            
            // Card 3: Atalhos do Teclado (Shortcuts)
            SettingsCardView(title: "ATALHOS DO TECLADO (SHORTCUTS)") {
                VStack(spacing: 8) {
                    ShortcutRowView(key: "Espaço", action: "Play / Pause da reprodução")
                    ShortcutRowView(key: "R", action: "Reiniciar música atual do início (0:00)")
                    ShortcutRowView(key: "I", action: "Alternar Loop Infinito da seção ativa")
                    ShortcutRowView(key: "F", action: "Fade Out / Fade In suave das tracks")
                    ShortcutRowView(key: "→", action: "Avançar para a próxima música da setlist")
                    ShortcutRowView(key: "←", action: "Voltar para a música anterior da setlist")
                    ShortcutRowView(key: "1 .. 9", action: "Pular instantaneamente para a seção correspondente")
                    ShortcutRowView(key: "Cmd + ,", action: "Abrir janela de Configurações (Settings)")
                    ShortcutRowView(key: "Cmd + S", action: "Salvar setlist atual no disco")
                }
            }
        }
    }
}

// ==========================================
// 3. ABA FILES & LIBRARY (Pastas e Manutenção)
// ==========================================

struct FilesLibrarySettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var isReindexing: Bool = false
    @State private var reindexMessage: String? = nil
    
    var body: some View {
        VStack(spacing: 18) {
            // Card 1: Pastas de Armazenamento
            SettingsCardView(title: "PASTAS DE ARMAZENAMENTO") {
                VStack(spacing: 12) {
                    // Pasta das Músicas (VS)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tracks Directory (VS)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text(NativeSongLibrary.shared.getTracksDirectory().path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: true)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    // Pasta dos Setlists
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Setlists Directory (.vset)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text(getSetlistsFolderPath())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: false)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            
            // Card 2: Manutenção da Biblioteca
            SettingsCardView(title: "MANUTENÇÃO DA BIBLIOTECA") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reindex Library & Clear Cache")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Recarrega todas as músicas, reprocessa metadados e limpa caches corrompidos")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button(action: {
                            reindexLibrary()
                        }) {
                            HStack(spacing: 6) {
                                if isReindexing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(isReindexing ? "Indexing..." : "Reindex Now")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isReindexing)
                    }
                    
                    if let msg = reindexMessage {
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    
    private func getSetlistsFolderPath() -> String {
        if let custom = UserDefaults.standard.string(forKey: "saved_setlists_dir") {
            return custom
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("AbletonTracks/Setlists").path ?? "/Users/samysglauber/Documents/AbletonTracks/Setlists"
    }
    
    private func chooseFolder(forTracks: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = forTracks ? "Select Tracks Directory (VS)" : "Select Setlists Directory"
        
        if panel.runModal() == .OK, let url = panel.url {
            if forTracks {
                _ = NativeSongLibrary.shared.setTracksDirectory(url.path)
            } else {
                UserDefaults.standard.set(url.path, forKey: "saved_setlists_dir")
            }
        }
    }
    
    private func reindexLibrary() {
        isReindexing = true
        reindexMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let songs = NativeSongLibrary.shared.getAllSongs()
            DispatchQueue.main.async {
                self.isReindexing = false
                self.reindexMessage = "✅ \(songs.count) músicas indexadas com sucesso!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.reindexMessage = nil
                }
            }
        }
    }
}

// ==========================================
// 4. ABA REMOTE (Servidor, QR Code e Permissões)
// ==========================================

struct RemoteSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var copied: Bool = false
    
    var body: some View {
        VStack(spacing: 18) {
            // Card 1: Servidor Web
            SettingsCardView(title: "SERVIDOR REMOTO (WI-FI)") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Remote Control Server")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Habilita o controle de transporte e setlist via navegador no smartphone/tablet")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { NativeRemoteServer.shared.isRunning },
                            set: { enable in
                                if enable {
                                    NativeRemoteServer.shared.start(port: UInt16(state.remoteServerPort))
                                } else {
                                    NativeRemoteServer.shared.stop()
                                }
                            }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.06))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Server Port")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Porta TCP utilizada pelo servidor HTTP e WebSocket")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        TextField("Port", value: $state.remoteServerPort, formatter: NumberFormatter())
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(6)
                            .frame(width: 80)
                    }
                }
            }
            
            // Card 2: Conexão e QR Code
            SettingsCardView(title: "CONEXÃO DE DISPOSITIVOS") {
                HStack(spacing: 20) {
                    // QR Code Preview
                    let urlStr = state.serverUrl
                    if let qrImg = generateQRCodeImage(from: urlStr) {
                        Image(nsImage: qrImg)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 110, height: 110)
                            .padding(6)
                            .background(Color.white)
                            .cornerRadius(8)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 110, height: 110)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Abra a câmera do celular conectado ao mesmo Wi-Fi para acessar o controle remoto:")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .lineLimit(2)
                        
                        Text(state.serverUrl)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                        
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(state.serverUrl, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                copied = false
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied!" : "Copy Link")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                }
            }
            
            // Card 3: Nível de Permissão
            SettingsCardView(title: "NÍVEL DE PERMISSÃO") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Access Permission")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                            Text("Apenas Visualização bloqueia botões de Play/Stop no celular para evitar acidentes")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Picker("", selection: $state.remoteReadOnlyMode) {
                            Text("Controle Total").tag(false)
                            Text("Apenas Visualização").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 210)
                    }
                }
            }
        }
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
// COMPONENTES VISUAIS REUTILIZÁVEIS
// ==========================================

struct SettingsCardView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal, 4)
            
            VStack(spacing: 0) {
                content
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

struct ShortcutRowView: View {
    let key: String
    let action: String
    
    var body: some View {
        HStack {
            Text(action)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
            Spacer()
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.12))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        }
        .padding(.vertical, 2)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}
