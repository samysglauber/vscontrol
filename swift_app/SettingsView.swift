import SwiftUI
import AppKit
import Foundation
import Combine

// ==========================================
// SOBER / RAYCAST-STYLE FLOATING HUD SETTINGS (680 × 350)
// Centered over Main App Window • True Borderless HUD • No Traffic Lights
// Flat List (Generous Row Spacing) • Toggles on Left • No Footer • Esc to Close
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

final class SoberHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    
    override func cancelOperation(_ sender: Any?) {
        self.close()
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    
    convenience init() {
        let window = SoberHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 350),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        
        let settingsView = SettingsView()
        window.contentView = NSHostingView(rootView: settingsView)
        
        self.init(window: window)
        window.delegate = self
    }
    
    func show() {
        guard let w = window else { return }
        
        // Centraliza com relação à janela principal do app
        if let mainWindow = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 != w }) {
            let mFrame = mainWindow.frame
            let targetW: CGFloat = 680
            let targetH: CGFloat = 350
            let x = mFrame.origin.x + (mFrame.width - targetW) / 2.0
            let y = mFrame.origin.y + (mFrame.height - targetH) / 2.0
            w.setFrame(NSRect(x: x, y: y, width: targetW, height: targetH), display: true)
        } else {
            w.center()
        }
        
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var state: PlaybackState = PlaybackState.shared
    @State private var selectedTab: SettingsTab = .general
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar (Close Button + Settings Title + Segmented Tabs)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: {
                        SettingsWindowController.shared.window?.close()
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.50))
                            .frame(width: 20, height: 20)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Text("Settings")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
                
                Spacer()
                
                // Segmented Tabs Pill
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
                                    .fill(selectedTab == tab ? Color.white.opacity(0.14) : Color.clear)
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
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 13)
            .padding(.bottom, 11)
            
            Divider()
                .background(Color.white.opacity(0.06))
            
            // Tab Content (Flat List com espaçamento confortável entre linhas)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
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
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 680, height: 350)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.137, green: 0.137, blue: 0.145))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .background(
            Button("") {
                SettingsWindowController.shared.window?.close()
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }
}

// ==========================================
// 1. GENERAL TAB (Spacious Rows, Toggles on Left)
// ==========================================

struct GeneralSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Audio & Routing
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "AUDIO & ROUTING")
                
                VStack(spacing: 8) {
                    // Audio Device
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.emeraldOrGreen)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Audio Device")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Active CoreAudio output device for playback")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
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
                    .padding(.vertical, 5)
                    
                    // Auto Pan (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.autoPanStereo)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Auto Pan (L/R)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Send Click & Guide to left and tracks to right")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        Text("Stereo L/R")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .padding(.vertical, 5)
                    
                    // Default Fader Level
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Default Fader Level")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Initial volume fader levels when loading songs")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("100% (0 dB)", 1.0), ("80% (-2 dB)", 0.8)],
                            selection: $state.faderDefaultLevel
                        )
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // Stage & Playback
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "STAGE & PLAYBACK")
                
                VStack(spacing: 8) {
                    // Keep Screen Awake (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.keepScreenAwake)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Keep Screen Awake")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Prevent Mac display and system sleep during performance")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Auto-Advance
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Auto-Advance")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Action when reaching the end of each setlist song")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Stop at End", false), ("Next Song", true)],
                            selection: $state.autoAdvance
                        )
                    }
                    .padding(.vertical, 5)
                    
                    // Fade Out Duration
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Fade Out Duration")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Smooth track attenuation time when fading out")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultFadeDuration, in: 1.0...8.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultFadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 5)
                    
                    // Crossfade Duration
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Crossfade Duration")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Overlap transition duration between setlist songs")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Slider(value: $state.defaultCrossfadeDuration, in: 1.0...10.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultCrossfadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // Timeline Display
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "TIMELINE DISPLAY")
                
                VStack(spacing: 8) {
                    // Waveform Grid (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.showWaveformGrid)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Waveform Grid")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Display measure and beat grid lines on the waveform")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Default Timeline Zoom
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Default Timeline Zoom")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Initial zoom level applied when loading any song")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Fit", "fit"), ("1x", "1x"), ("2x", "2x")],
                            selection: $state.defaultTimelineZoom
                        )
                    }
                    .padding(.vertical, 5)
                }
            }
        }
    }
}

// ==========================================
// 2. MIDI & SYNC TAB (Spacious Rows, Toggles on Left)
// ==========================================

struct MidiSyncSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // DAW Playback Sync
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "DAW PLAYBACK SYNC (OSC)")
                
                VStack(spacing: 8) {
                    // DAW Playback Sync (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.enableAbletonPlaySync)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("DAW Playback Sync")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Send transport commands to start and stop DAW simultaneously")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Trigger at Beat 1 (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.triggerAtBeat1)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Trigger at Beat 1 (Downbeat)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Wait for first audible click/downbeat before triggering DAW")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Sync Tempo (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.syncTempoToDaw)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Sync Tempo & Time Signature")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Send song tempo and time signature to DAW upon playback start")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // OSC Host & Port
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("OSC Target Host / Port")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Destination IP address and UDP port for DAW communication")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            TextField("Host", text: $state.oscHost)
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5.5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5.5)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                                .frame(width: 105)
                            Text(":")
                                .foregroundColor(.white.opacity(0.35))
                            TextField("Port", value: $state.oscPort, formatter: NumberFormatter())
                                .textFieldStyle(PlainTextFieldStyle())
                                .font(.system(size: 11.5, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(5.5)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5.5)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                                .frame(width: 60)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // MIDI Beat Clock
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "MIDI BEAT CLOCK")
                
                VStack(spacing: 8) {
                    // Enable Clock (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.enableMidiClock)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Enable MIDI Beat Clock")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Transmit 0xF8 clock pulses at 24 PPQN to sync pedals and hardware")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Virtual MIDI Port
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Virtual MIDI Port")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Virtual CoreMIDI port created automatically in the system")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
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
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                    .padding(.vertical, 5)
                    
                    // Clock Offset Compensation
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Clock Offset Compensation")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Fine offset compensation in milliseconds for hardware latency")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
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
                                .foregroundColor(.white.opacity(0.70))
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // Keyboard Shortcuts
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "KEYBOARD SHORTCUTS")
                
                VStack(spacing: 5) {
                    SoberShortcutRow(key: "Space", action: "Play / Pause playback")
                    SoberShortcutRow(key: "R", action: "Restart current song from start (0:00)")
                    SoberShortcutRow(key: "I", action: "Toggle Infinite Loop on active section")
                    SoberShortcutRow(key: "F", action: "Smooth Fade Out / Fade In tracks")
                    SoberShortcutRow(key: "→", action: "Advance to next song in setlist")
                    SoberShortcutRow(key: "←", action: "Return to previous song in setlist")
                    SoberShortcutRow(key: "1 .. 9", action: "Jump directly to corresponding section")
                    SoberShortcutRow(key: "Cmd + ,", action: "Open Settings")
                    SoberShortcutRow(key: "Cmd + S", action: "Save current setlist to disk")
                }
            }
        }
    }
}

// ==========================================
// 3. FILES & LIBRARY TAB (Spacious Rows)
// ==========================================

struct FilesLibrarySettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var isReindexing: Bool = false
    @State private var reindexMessage: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Storage Locations
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "STORAGE LOCATIONS")
                
                VStack(spacing: 8) {
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
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
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: true)
                        }
                        .buttonStyle(SoberPillButtonStyle())
                    }
                    .padding(.vertical, 5)
                    
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
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
                        }
                        Spacer()
                        Button("Choose Folder...") {
                            chooseFolder(forTracks: false)
                        }
                        .buttonStyle(SoberPillButtonStyle())
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // Library Maintenance
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "LIBRARY MAINTENANCE")
                
                VStack(spacing: 8) {
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Reindex Library & Clear Cache")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Rescan tracks folder, rebuild metadata and clear audio caches")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
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
                    .padding(.vertical, 5)
                    
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
// 4. REMOTE TAB (Spacious Rows)
// ==========================================

struct RemoteSettingsTabView: View {
    @ObservedObject var state: PlaybackState
    @State private var copied: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Remote Server
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "REMOTE CONTROL SERVER")
                
                VStack(spacing: 8) {
                    // Server Toggle (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
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
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Remote Control Server")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Enable transport and setlist control via web browser on tablet/mobile")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    
                    // Server Port
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Server Port")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("TCP port used for HTTP and WebSocket connections")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        TextField("Port", value: $state.remoteServerPort, formatter: NumberFormatter())
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(5.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                            .frame(width: 75)
                    }
                    .padding(.vertical, 5)
                }
            }
            
            // Device Connection & QR Code
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "DEVICE CONNECTION")
                
                HStack(spacing: 16) {
                    let urlStr = state.serverUrl
                    if let qrImg = generateQRCodeImage(from: urlStr) {
                        Image(nsImage: qrImg)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 85, height: 85)
                            .padding(5)
                            .background(Color.white)
                            .cornerRadius(7)
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))
                            .frame(width: 85, height: 85)
                            .cornerRadius(7)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
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
                .padding(.vertical, 6)
            }
            
            // Access Permissions
            VStack(alignment: .leading, spacing: 7) {
                SoberSectionHeader(title: "ACCESS PERMISSIONS")
                
                HStack {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.white.opacity(0.20))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text("Access Permission")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(.white)
                            Text("Read-Only disables transport and section jump buttons on mobile")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.40))
                        }
                    }
                    Spacer()
                    SoberSegmentedPicker(
                        items: [("Full Control", false), ("Read-Only", true)],
                        selection: $state.remoteReadOnlyMode
                    )
                }
                .padding(.vertical, 5)
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
// REUSABLE SOBER RAYCAST COMPONENTS
// ==========================================

struct SoberSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.35))
            .padding(.horizontal, 2)
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
                                .fill(selection == item.value ? Color.white.opacity(0.14) : Color.clear)
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
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
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
                    .fill(isOn ? Color.white.opacity(0.32) : Color.white.opacity(0.12))
                    .frame(width: 32, height: 18)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.25), radius: 1, x: 0, y: 0.5)
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
        .padding(.vertical, 3.5)
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

extension Color {
    static let emeraldOrGreen = Color(red: 0.20, green: 0.78, blue: 0.55)
}
