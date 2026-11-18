import SwiftUI
import AppKit
import Foundation
import Combine

// ==========================================
// SOBER / RAYCAST-STYLE SETTINGS WINDOW
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
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
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
        // Sober dark graphite matte surface (Raycast / Linear style)
        window.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.14, alpha: 1.0)
        
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
            // Header Bar (Breadcrumb + Segmented Tab Selector)
            HStack(spacing: 12) {
                // Left clearance for macOS traffic lights
                Spacer()
                    .frame(width: 64)
                
                // Breadcrumb (Raycast / Linear style)
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.40))
                    Text("Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                    Text("→")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.30))
                    Text(selectedTab.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
                
                Spacer()
                
                // Sober Segmented Tabs Switcher
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.12)) {
                                selectedTab = tab
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: tab.iconName)
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                            }
                            .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.45))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(selectedTab == tab ? Color.white.opacity(0.13) : Color.clear)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(2.5)
                .background(Color.white.opacity(0.04))
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 11)
            
            Divider()
                .background(Color.white.opacity(0.06))
            
            // Tab Content Body
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 14) {
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
                .padding(.vertical, 16)
            }
            
            Divider()
                .background(Color.white.opacity(0.06))
            
            // Sober Footer Bar (Raycast-style keyboard action hints)
            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Text("Tabs")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    KeyCapBadge(text: "⌘ 1")
                    KeyCapBadge(text: "⌘ 2")
                    KeyCapBadge(text: "⌘ 3")
                    KeyCapBadge(text: "⌘ 4")
                }
                
                Spacer()
                
                HStack(spacing: 5) {
                    Text("Close")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.35))
                    KeyCapBadge(text: "Esc")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8.5)
            .background(Color.white.opacity(0.015))
        }
        .frame(width: 700, height: 580)
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        // Keyboard Shortcuts (Tabs 1..4 & Close on Esc)
        .background(
            Group {
                Button("") { selectedTab = .general }.keyboardShortcut("1", modifiers: .command)
                Button("") { selectedTab = .midiSync }.keyboardShortcut("2", modifiers: .command)
                Button("") { selectedTab = .files }.keyboardShortcut("3", modifiers: .command)
                Button("") { selectedTab = .remote }.keyboardShortcut("4", modifiers: .command)
                Button("") { SettingsWindowController.shared.window?.close() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }
}

// ==========================================
// 1. GENERAL TAB (Audio, Stage, Fade, Timeline)
// ==========================================

struct GeneralSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(spacing: 14) {
            // Audio & Routing
            SoberSectionCard(title: "AUDIO & ROUTING") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Audio Device")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Active CoreAudio output device for playback")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        
                        Menu {
                            ForEach(state.availableDevices) { dev in
                                Button(action: {
                                    state.selectOutputDevice(id: dev.id)
                                }) {
                                    if dev.id == state.selectedDeviceId {
                                        Label(dev.name, systemImage: "checkmark")
                                    } else {
                                        Text(dev.name)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(state.devices.first(where: { $0.id == state.selectedDeviceId })?.name ?? "Select Device...")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .menuStyle(BorderlessButtonMenuStyle())
                        .frame(width: 200)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Auto Pan (L/R)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("L Channel: Click & Guide | R Channel: Multitrack & VS")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.autoPanStereo)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Default Fader Level")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Initial level for volume faders when loading songs")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("100% (0 dB)", 1.0), ("80% (-2 dB)", 0.8)],
                            selection: $state.faderDefaultLevel
                        )
                    }
                }
            }
            
            // Stage & Playback
            SoberSectionCard(title: "STAGE & PLAYBACK") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Keep Screen Awake")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Prevents display and system sleep during live performance")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.keepScreenAwake)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Auto-Advance")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Action when reaching the end of each setlist song")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Stop at End", false), ("Next Song", true)],
                            selection: $state.autoAdvance
                        )
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Fade Out Duration")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Smooth attenuation time when fading out tracks")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultFadeDuration, in: 1.0...8.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultFadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Crossfade Duration")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Overlap transition duration between setlist songs")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultCrossfadeDuration, in: 1.0...10.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultCrossfadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }
            
            // Timeline Display
            SoberSectionCard(title: "TIMELINE DISPLAY") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Waveform Grid")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Display measure and beat grid lines on the waveform")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.showWaveformGrid)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Default Timeline Zoom")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Initial zoom level applied when loading any song")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Fit", "fit"), ("1x", "1x"), ("2x", "2x")],
                            selection: $state.defaultTimelineZoom
                        )
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
        VStack(spacing: 14) {
            // DAW Playback Sync
            SoberSectionCard(title: "DAW PLAYBACK SYNC (OSC)") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("DAW Playback Sync")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Send transport commands to start and stop DAW simultaneously")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.enableAbletonPlaySync)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Trigger at Beat 1 (Downbeat)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Wait for the first audible click/downbeat before triggering DAW")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.triggerAtBeat1)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Sync Tempo & Time Signature")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Send song tempo and time signature to DAW upon playback start")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.syncTempoToDaw)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("OSC Target Host / Port")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Destination IP address and UDP port for DAW communication")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            TextField("Host", text: $state.oscHost)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                )
                                .frame(width: 105)
                            Text(":")
                                .foregroundColor(.white.opacity(0.35))
                            TextField("Port", value: $state.oscPort, formatter: NumberFormatter())
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4.5)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                                )
                                .frame(width: 60)
                        }
                    }
                }
            }
            
            // MIDI Beat Clock
            SoberSectionCard(title: "MIDI BEAT CLOCK") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Enable MIDI Beat Clock")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Transmit 0xF8 clock pulses at 24 PPQN to sync pedals and hardware")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: $state.enableMidiClock)
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Virtual MIDI Port")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Virtual CoreMIDI port created automatically in the system")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6.5, height: 6.5)
                            Text("VS Control Sync")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        )
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Clock Offset Compensation")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Fine offset compensation in milliseconds for hardware latency")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.midiClockOffsetMs, in: -100.0...100.0, step: 1.0)
                                .frame(width: 105)
                            Text(String(format: "%+.0f ms", state.midiClockOffsetMs))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(state.midiClockOffsetMs == 0 ? .white.opacity(0.40) : .white)
                                .frame(width: 54, alignment: .trailing)
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
            SoberSectionCard(title: "KEYBOARD SHORTCUTS") {
                VStack(spacing: 6.5) {
                    SoberShortcutRow(key: "Space", action: "Play / Pause playback")
                    SoberShortcutRow(key: "R", action: "Restart current song from start (0:00)")
                    SoberShortcutRow(key: "I", action: "Toggle Infinite Loop on active section")
                    SoberShortcutRow(key: "F", action: "Smooth Fade Out / Fade In tracks")
                    SoberShortcutRow(key: "→", action: "Advance to next song in setlist")
                    SoberShortcutRow(key: "←", action: "Return to previous song in setlist")
                    SoberShortcutRow(key: "1 .. 9", action: "Jump directly to corresponding section")
                    SoberShortcutRow(key: "Cmd + ,", action: "Open Settings window")
                    SoberShortcutRow(key: "Cmd + S", action: "Save current setlist to disk")
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
        VStack(spacing: 14) {
            // Storage Locations
            SoberSectionCard(title: "STORAGE LOCATIONS") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Tracks Directory (VS)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text(NativeSongLibrary.shared.getTracksDirectory().path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.40))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: true)
                        }
                        .buttonStyle(SoberPillButtonStyle())
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Setlists Directory (.vset)")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text(getSetlistsFolderPath())
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.40))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: false)
                        }
                        .buttonStyle(SoberPillButtonStyle())
                    }
                }
            }
            
            // Library Maintenance
            SoberSectionCard(title: "LIBRARY MAINTENANCE") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Reindex Library & Clear Cache")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Rescan tracks folder, rebuild metadata and clear audio caches")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        Button(action: {
                            reindexLibrary()
                        }) {
                            HStack(spacing: 6) {
                                if isReindexing {
                                    ProgressView()
                                        .scaleEffect(0.60)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10.5))
                                }
                                Text(isReindexing ? "Indexing..." : "Reindex Now")
                            }
                        }
                        .buttonStyle(SoberPillButtonStyle())
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
        VStack(spacing: 14) {
            // Remote Server
            SoberSectionCard(title: "REMOTE CONTROL SERVER") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Remote Control Server")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Enable transport and setlist control via web browser on tablet/mobile")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberToggle(isOn: Binding(
                            get: { NativeRemoteServer.shared.isRunning },
                            set: { enable in
                                if enable {
                                    NativeRemoteServer.shared.start(port: UInt16(state.remoteServerPort))
                                } else {
                                    NativeRemoteServer.shared.stop()
                                }
                            }
                        ))
                    }
                    
                    Divider().background(Color.white.opacity(0.04))
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Server Port")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("TCP port used for HTTP and WebSocket connections")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        TextField("Port", value: $state.remoteServerPort, formatter: NumberFormatter())
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                            )
                            .frame(width: 75)
                    }
                }
            }
            
            // Device Connection & QR Code
            SoberSectionCard(title: "DEVICE CONNECTION") {
                HStack(spacing: 16) {
                    let urlStr = state.serverUrl
                    if let qrImg = generateQRCodeImage(from: urlStr) {
                        Image(nsImage: qrImg)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 95, height: 95)
                            .padding(5)
                            .background(Color.white)
                            .cornerRadius(7)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 95, height: 95)
                            .cornerRadius(7)
                    }
                    
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Scan QR code with any mobile device connected to the same Wi-Fi network:")
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.50))
                            .lineLimit(2)
                        
                        Text(state.serverUrl)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.90))
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
                                    .font(.system(size: 10.5))
                                Text(copied ? "Copied!" : "Copy Link")
                            }
                        }
                        .buttonStyle(SoberPillButtonStyle())
                    }
                    Spacer()
                }
            }
            
            // Access Permissions
            SoberSectionCard(title: "ACCESS PERMISSIONS") {
                VStack(spacing: 11) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Access Permission")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Read-Only disables transport and section jump buttons on mobile")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Full Control", false), ("Read-Only", true)],
                            selection: $state.remoteReadOnlyMode
                        )
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
// SOBER / RAYCAST REUSABLE COMPONENTS
// ==========================================

struct SoberSectionCard<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
                .padding(.horizontal, 3)
            
            VStack(spacing: 0) {
                content
            }
            .padding(13)
            .background(Color.white.opacity(0.025))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

struct SoberSegmentedPicker<T: Hashable>: View {
    let items: [(title: String, value: T)]
    @Binding var selection: T
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        selection = item.value
                    }
                }) {
                    Text(item.title)
                        .font(.system(size: 11, weight: selection == item.value ? .medium : .regular))
                        .foregroundColor(selection == item.value ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selection == item.value ? Color.white.opacity(0.13) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(2.5)
        .background(Color.white.opacity(0.04))
        .cornerRadius(6.5)
        .overlay(
            RoundedRectangle(cornerRadius: 6.5)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}

struct SoberToggle: View {
    @Binding var isOn: Bool
    
    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.14)) {
                isOn.toggle()
            }
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isOn ? Color(red: 0.28, green: 0.48, blue: 0.85) : Color.white.opacity(0.12))
                    .frame(width: 32, height: 18)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.20), radius: 1, x: 0, y: 0.5)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct KeyCapBadge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.06))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

struct SoberShortcutRow: View {
    let key: String
    let action: String
    
    var body: some View {
        HStack {
            Text(action)
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.80))
            Spacer()
            KeyCapBadge(text: key)
        }
        .padding(.vertical, 1.5)
    }
}

struct SoberPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(configuration.isPressed ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
            .cornerRadius(5.5)
            .overlay(
                RoundedRectangle(cornerRadius: 5.5)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
