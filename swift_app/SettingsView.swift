import SwiftUI
import AppKit
import Foundation
import Combine

// ==========================================
// SETTINGS WINDOW CONTROLLER & VIEW (Cmd + ,)
// 4 Minimalist Tabs: General, MIDI & Sync, Files & Library, Remote
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
        case .files: return "folder"
        case .remote: return "iphone.radiowaves.left.and.right"
        }
    }
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VSControlSettingsWindow")
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.10, alpha: 1.0)
        
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
            // Minimalist Integrated Header (aligned with traffic lights)
            HStack {
                // Left clearance for native macOS traffic lights
                Spacer()
                    .frame(width: 68)
                
                Spacer()
                
                // Minimalist Segmented Tabs
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 11, weight: .medium))
                                Text(tab.rawValue)
                                    .font(.system(size: 11.5, weight: selectedTab == tab ? .semibold : .regular))
                            }
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.42))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTab == tab ? Color.white.opacity(0.12) : Color.clear)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(3)
                .background(Color.white.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
                
                Spacer()
                
                // Right balance spacer
                Spacer()
                    .frame(width: 68)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 11)
            
            Divider()
                .background(Color.white.opacity(0.07))
            
            // Active Tab Content
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
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
        .frame(width: 660, height: 560)
        .background(Color(red: 0.08, green: 0.08, blue: 0.10))
    }
}

// ==========================================
// 1. GENERAL TAB (Audio, Stage, Fade, Timeline)
// ==========================================

struct GeneralSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 16) {
            // Audio & Routing
            SettingsCardView(title: "AUDIO & ROUTING") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Audio Device")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Active CoreAudio output device for playback")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
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
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto Pan (L/R)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("L Channel: Click & Guide | R Channel: Multitrack & VS")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.autoPanStereo)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default Fader Level")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Initial level for volume faders when loading songs")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
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
            
            // Stage & Playback
            SettingsCardView(title: "STAGE & PLAYBACK") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Keep Screen Awake")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Prevents display and system sleep during live performance")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.keepScreenAwake)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Auto-Advance")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Action when reaching the end of each setlist song")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Picker("", selection: $state.autoAdvance) {
                            Text("Stop at End").tag(false)
                            Text("Next Song").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Fade Out Duration")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Smooth attenuation time when fading out tracks")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultFadeDuration, in: 1.0...8.0, step: 0.5)
                                .frame(width: 120)
                            Text(String(format: "%.1fs", state.defaultFadeDuration))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Crossfade Duration")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Overlap transition duration between setlist songs")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultCrossfadeDuration, in: 1.0...10.0, step: 0.5)
                                .frame(width: 120)
                            Text(String(format: "%.1fs", state.defaultCrossfadeDuration))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white)
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }
            }
            
            // Timeline Display
            SettingsCardView(title: "TIMELINE DISPLAY") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Waveform Grid")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Display measure and beat grid lines on the waveform")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.showWaveformGrid)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Default Timeline Zoom")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Initial zoom level applied when loading any song")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
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
// 2. MIDI & SYNC TAB (DAW OSC + MIDI Beat Clock + Shortcuts)
// ==========================================

struct MidiSyncSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 16) {
            // DAW Playback Sync
            SettingsCardView(title: "DAW PLAYBACK SYNC (OSC)") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("DAW Playback Sync")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Send transport commands to start and stop DAW simultaneously")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.enableAbletonPlaySync)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Trigger at Beat 1 (Downbeat)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Wait for the first audible click/downbeat before triggering DAW")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.triggerAtBeat1)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sync Tempo & Time Signature")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Send song tempo and time signature to DAW upon playback start")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.syncTempoToDaw)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("OSC Target Host / Port")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Destination IP address and UDP port for DAW communication")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            TextField("Host", text: $state.oscHost)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(6)
                                .frame(width: 110)
                            Text(":")
                                .foregroundColor(.white.opacity(0.4))
                            TextField("Port", value: $state.oscPort, formatter: NumberFormatter())
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.07))
                                .cornerRadius(6)
                                .frame(width: 65)
                        }
                    }
                }
            }
            
            // MIDI Beat Clock
            SettingsCardView(title: "MIDI BEAT CLOCK") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable MIDI Beat Clock")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Transmit 0xF8 clock pulses at 24 PPQN to sync pedals and hardware")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Toggle("", isOn: $state.enableMidiClock)
                            .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Virtual MIDI Port")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Virtual CoreMIDI port created automatically in the system")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 7, height: 7)
                            Text("VS Control Sync")
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.07))
                        .cornerRadius(6)
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Clock Offset Compensation")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Fine offset compensation in milliseconds for hardware latency")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.midiClockOffsetMs, in: -100.0...100.0, step: 1.0)
                                .frame(width: 110)
                            Text(String(format: "%+.0f ms", state.midiClockOffsetMs))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(state.midiClockOffsetMs == 0 ? .white.opacity(0.45) : .white)
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
            
            // Keyboard Shortcuts
            SettingsCardView(title: "KEYBOARD SHORTCUTS") {
                VStack(spacing: 8) {
                    ShortcutRowView(key: "Space", action: "Play / Pause playback")
                    ShortcutRowView(key: "R", action: "Restart current song from start (0:00)")
                    ShortcutRowView(key: "I", action: "Toggle Infinite Loop on active section")
                    ShortcutRowView(key: "F", action: "Smooth Fade Out / Fade In tracks")
                    ShortcutRowView(key: "→", action: "Advance to next song in setlist")
                    ShortcutRowView(key: "←", action: "Return to previous song in setlist")
                    ShortcutRowView(key: "1 .. 9", action: "Jump directly to corresponding section")
                    ShortcutRowView(key: "Cmd + ,", action: "Open Settings window")
                    ShortcutRowView(key: "Cmd + S", action: "Save current setlist to disk")
                }
            }
        }
    }
}

// ==========================================
// 3. FILES & LIBRARY TAB (Storage & Maintenance)
// ==========================================

struct FilesLibrarySettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var isReindexing: Bool = false
    @State private var reindexMessage: String? = nil
    
    var body: some View {
        VStack(spacing: 16) {
            // Storage Locations
            SettingsCardView(title: "STORAGE LOCATIONS") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tracks Directory (VS)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(NativeSongLibrary.shared.getTracksDirectory().path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: true)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Setlists Directory (.vset)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text(getSetlistsFolderPath())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
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
            
            // Library Maintenance
            SettingsCardView(title: "LIBRARY MAINTENANCE") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reindex Library & Clear Cache")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Rescan tracks folder, rebuild metadata and clear audio caches")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Button(action: {
                            reindexLibrary()
                        }) {
                            HStack(spacing: 6) {
                                if isReindexing {
                                    ProgressView()
                                        .scaleEffect(0.65)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11))
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
                self.reindexMessage = "✅ \(songs.count) songs indexed successfully!"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.reindexMessage = nil
                }
            }
        }
    }
}

// ==========================================
// 4. REMOTE TAB (Server, QR Code & Permissions)
// ==========================================

struct RemoteSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var copied: Bool = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Remote Server
            SettingsCardView(title: "REMOTE CONTROL SERVER") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Remote Control Server")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Enable transport and setlist control via web browser on tablet/mobile")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
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
                    
                    Divider().background(Color.white.opacity(0.05))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Server Port")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("TCP port used for HTTP and WebSocket connections")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        TextField("Port", value: $state.remoteServerPort, formatter: NumberFormatter())
                            .textFieldStyle(PlainTextFieldStyle())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.07))
                            .cornerRadius(6)
                            .frame(width: 80)
                    }
                }
            }
            
            // Device Connection & QR Code
            SettingsCardView(title: "DEVICE CONNECTION") {
                HStack(spacing: 18) {
                    let urlStr = state.serverUrl
                    if let qrImg = generateQRCodeImage(from: urlStr) {
                        Image(nsImage: qrImg)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 105, height: 105)
                            .padding(6)
                            .background(Color.white)
                            .cornerRadius(8)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 105, height: 105)
                            .cornerRadius(8)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan QR code with any mobile device connected to the same Wi-Fi network:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                        
                        Text(state.serverUrl)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
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
                            HStack(spacing: 5) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                Text(copied ? "Copied!" : "Copy Link")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                }
            }
            
            // Access Permissions
            SettingsCardView(title: "ACCESS PERMISSIONS") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Access Permission")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white)
                            Text("Read-Only disables transport and section jump buttons on mobile")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        Spacer()
                        Picker("", selection: $state.remoteReadOnlyMode) {
                            Text("Full Control").tag(false)
                            Text("Read-Only").tag(true)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 200)
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
// REUSABLE MINIMALIST COMPONENTS
// ==========================================

struct SettingsCardView<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.40))
                .padding(.horizontal, 4)
            
            VStack(spacing: 0) {
                content
            }
            .padding(14)
            .background(Color.white.opacity(0.035))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
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
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.09))
                .cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .padding(.vertical, 2)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 4.5)
            .background(configuration.isPressed ? Color.white.opacity(0.14) : Color.white.opacity(0.07))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}
