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
        window.isMovableByWindowBackground = false
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
                                if tab == .remote {
                                    Text("SOON")
                                        .font(.system(size: 7.5, weight: .bold))
                                        .foregroundColor(selectedTab == tab ? .white.opacity(0.9) : .white.opacity(0.40))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(3)
                                }
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
            .background(WindowDragArea())
            
            Divider()
                .background(Color.white.opacity(0.06))
            
            // Tab Content (Flat List com visual leve, espaçamento arejado e respiro)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
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
                .padding(.top, 16)
                .padding(.bottom, 22)
            }
        }
        .frame(width: 680, height: 350)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 0.10, green: 0.10, blue: 0.12).opacity(0.68)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 24) {
            // Audio & Routing
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "AUDIO & ROUTING")
                
                VStack(spacing: 6) {
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
                            
                            Divider()
                            
                            Button(action: {
                                state.fetchDevices()
                            }) {
                                Label("Rescan Audio Devices", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.70))
                                
                                Text(state.devices.first(where: { $0.id == state.selectedDeviceId })?.name ?? "Select Device...")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(6.5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6.5)
                                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                            )
                        }
                        .menuStyle(BorderlessButtonMenuStyle())
                    }
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                }
            }
            
            // Stage & Playback
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "STAGE & PLAYBACK")
                
                VStack(spacing: 6) {
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
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                    
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
                            SoberSlider(value: $state.defaultFadeDuration, in: 1.0...8.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultFadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 8)
                    
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
                            SoberSlider(value: $state.defaultCrossfadeDuration, in: 1.0...10.0, step: 0.5)
                                .frame(width: 110)
                            Text(String(format: "%.1fs", state.defaultCrossfadeDuration))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            
            // Timeline Display
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "TIMELINE DISPLAY")
                
                VStack(spacing: 6) {
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
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 24) {
            // DAW Playback Sync
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "DAW PLAYBACK SYNC (OSC)")
                
                VStack(spacing: 6) {
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
                    .padding(.vertical, 8)
                    
                    // DAW Scene Trigger (Toggle on LEFT)
                    HStack {
                        HStack(spacing: 12) {
                            SoberToggle(isOn: $state.enableAbletonSceneSync)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("DAW Scene Trigger")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Fire corresponding Ableton Live session scene upon playback start")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    
                    // DAW Trigger Alignment (Segmented Picker)
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("DAW Trigger Alignment")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Trigger DAW at track start or wait for the first audible beat")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        SoberSegmentedPicker(
                            items: [("Track Start", false), ("Beat 1 (Downbeat)", true)],
                            selection: $state.triggerAtBeat1
                        )
                    }
                    .padding(.vertical, 8)
                    
                    // Trigger Offset Compensation (Offset do Disparo em ms)
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Trigger Offset Compensation")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Fine millisecond offset to eliminate latency or silence (e.g. +50 ms for MP3)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            SoberSlider(value: $state.abletonTriggerOffsetMs, in: -100.0...100.0, step: 1.0)
                                .frame(width: 105)
                            Text(String(format: "%+.0f ms", state.abletonTriggerOffsetMs))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(state.abletonTriggerOffsetMs == 0 ? .white.opacity(0.40) : .white)
                                .frame(width: 54, alignment: .trailing)
                            Button("Reset") {
                                state.abletonTriggerOffsetMs = 0
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(state.abletonTriggerOffsetMs == 0 ? 0.03 : 0.07))
                            .foregroundColor(state.abletonTriggerOffsetMs == 0 ? .white.opacity(0.25) : .white.opacity(0.85))
                            .cornerRadius(5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.white.opacity(state.abletonTriggerOffsetMs == 0 ? 0.04 : 0.09), lineWidth: 1)
                            )
                            .buttonStyle(PlainButtonStyle())
                            .disabled(state.abletonTriggerOffsetMs == 0)
                        }
                    }
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                    
                    // Sync Setlist Scenes to Ableton
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Ableton Live Scenes")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text("Create and populate session scenes with setlist song names, tempo and meter")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.40))
                            }
                        }
                        Spacer()
                        Button(action: {
                            state.syncScenesToAbleton()
                        }) {
                            HStack(spacing: 6) {
                                if state.isSyncingAbleton {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.6)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(state.isSyncingAbleton ? "Syncing..." : "Sync Scenes Now")
                            }
                        }
                        .buttonStyle(SoberPillButtonStyle())
                        .disabled(state.isSyncingAbleton)
                    }
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                }
            }
            
            // MIDI Beat Clock
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "MIDI BEAT CLOCK")
                
                VStack(spacing: 6) {
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
                    .padding(.vertical, 8)
                    
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
                    .padding(.vertical, 8)
                    
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
                            SoberSlider(value: $state.midiClockOffsetMs, in: -100.0...100.0, step: 1.0)
                                .frame(width: 105)
                            Text(String(format: "%+.0f ms", state.midiClockOffsetMs))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundColor(state.midiClockOffsetMs == 0 ? .white.opacity(0.40) : .white)
                                .frame(width: 54, alignment: .trailing)
                            Button("Reset") {
                                state.midiClockOffsetMs = 0
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(state.midiClockOffsetMs == 0 ? 0.03 : 0.07))
                            .foregroundColor(state.midiClockOffsetMs == 0 ? .white.opacity(0.25) : .white.opacity(0.85))
                            .cornerRadius(5)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.white.opacity(state.midiClockOffsetMs == 0 ? 0.04 : 0.09), lineWidth: 1)
                            )
                            .buttonStyle(PlainButtonStyle())
                            .disabled(state.midiClockOffsetMs == 0)
                        }
                    }
                    .padding(.vertical, 8)
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
    @State private var tracksPath: String = ""
    @State private var setlistsPath: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Storage Locations
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "STORAGE LOCATIONS")
                
                VStack(spacing: 6) {
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Tracks Directory (VS)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text(tracksPath.isEmpty ? SongLibrary.shared.getTracksDirectory().path : tracksPath)
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
                    .padding(.vertical, 8)
                    
                    HStack {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.20))
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 2.5) {
                                Text("Setlists Directory (.vset)")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(.white)
                                Text(setlistsPath.isEmpty ? getSetlistsFolderPath() : setlistsPath)
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
                    .padding(.vertical, 8)
                }
            }
            
            // Library Maintenance
            VStack(alignment: .leading, spacing: 9) {
                SoberSectionHeader(title: "LIBRARY MAINTENANCE")
                
                VStack(spacing: 6) {
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
                    .padding(.vertical, 8)
                    
                    if let msg = reindexMessage {
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear {
            tracksPath = SongLibrary.shared.getTracksDirectory().path
            setlistsPath = getSetlistsFolderPath()
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
                _ = SongLibrary.shared.setTracksDirectory(url.path)
                tracksPath = url.path
                state.tracksFolderPath = url.path
                state.fetchAllLibrarySongs()
            } else {
                UserDefaults.standard.set(url.path, forKey: "saved_setlists_dir")
                setlistsPath = url.path
            }
        }
    }
    
    private func reindexLibrary() {
        isReindexing = true
        reindexMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            SongLibrary.shared.clearCache()
            let songs = SongLibrary.shared.getAllSongs()
            DispatchQueue.main.async {
                self.state.librarySongs = songs
                self.state.songs = songs
                self.isReindexing = false
                self.reindexMessage = "✅ \(songs.count) songs indexed & cache cleared!"
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SoberSectionHeader(title: "REMOTE CONTROL")
            
            VStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 56, height: 56)
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.75))
                }
                
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Mobile Remote Control")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text("COMING SOON")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(4)
                    }
                    
                    Text("The remote control experience is being redesigned for live performance.\nStay tuned for upcoming updates!")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 440)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
            .padding(.horizontal, 24)
            .background(Color.white.opacity(0.025))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

// ==========================================
// REUSABLE SOBER RAYCAST COMPONENTS
// ==========================================

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

final class WindowDragAreaNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragAreaNSView {
        WindowDragAreaNSView()
    }
    func updateNSView(_ nsView: WindowDragAreaNSView, context: Context) {}
}

final class SoberSliderNSView: NSView {
    var value: Double = 0.0 {
        didSet {
            if abs(value - oldValue) > 0.0001 {
                needsDisplay = true
            }
        }
    }
    var range: ClosedRange<Double> = 0.0...1.0
    var step: Double = 1.0
    var onValueChanged: ((Double) -> Void)?
    
    private var isDragging: Bool = false
    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?
    
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    
    override var intrinsicContentSize: NSSize {
        NSSize(width: 110, height: 18)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        self.trackingArea = ta
    }
    
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }
    
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
    
    private func updateValue(from event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let thumbRadius: CGFloat = 6.5
        let usableWidth = max(1.0, bounds.width - thumbRadius * 2.0)
        let clampedX = min(max(0.0, loc.x - thumbRadius), usableWidth)
        let fraction = clampedX / usableWidth
        var newVal = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
        if step > 0 {
            newVal = (newVal / step).rounded() * step
        }
        newVal = min(max(newVal, range.lowerBound), range.upperBound)
        if abs(newVal - value) > 0.0001 {
            value = newVal
            onValueChanged?(newVal)
            needsDisplay = true
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        updateValue(from: event)
    }
    
    override func mouseDragged(with event: NSEvent) {
        updateValue(from: event)
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        
        let thumbRadius: CGFloat = 6.5
        let usableWidth = max(1.0, bounds.width - thumbRadius * 2.0)
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let fraction = (range.upperBound > range.lowerBound) ? CGFloat((clamped - range.lowerBound) / (range.upperBound - range.lowerBound)) : 0.0
        let thumbX = thumbRadius + fraction * usableWidth
        let centerY = bounds.midY
        let trackHeight: CGFloat = 4.0
        
        // Background Track (Dark Gray / Translucent)
        let bgTrackRect = CGRect(x: thumbRadius, y: centerY - trackHeight / 2.0, width: usableWidth, height: trackHeight)
        let bgTrackPath = CGPath(roundedRect: bgTrackRect, cornerWidth: trackHeight / 2.0, cornerHeight: trackHeight / 2.0, transform: nil)
        ctx.addPath(bgTrackPath)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.12))
        ctx.fillPath()
        
        // Active Track (White)
        let activeWidth = max(0.0, thumbX - thumbRadius)
        if activeWidth > 0 {
            let activeTrackRect = CGRect(x: thumbRadius, y: centerY - trackHeight / 2.0, width: activeWidth, height: trackHeight)
            let activeTrackPath = CGPath(roundedRect: activeTrackRect, cornerWidth: trackHeight / 2.0, cornerHeight: trackHeight / 2.0, transform: nil)
            ctx.addPath(activeTrackPath)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.85))
            ctx.fillPath()
        }
        
        // Thumb (White circle with subtle shadow)
        let currentRadius: CGFloat = isDragging ? 7.5 : (isHovered ? 7.0 : 6.5)
        let thumbRect = CGRect(x: thumbX - currentRadius, y: centerY - currentRadius, width: currentRadius * 2.0, height: currentRadius * 2.0)
        
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: CGColor(gray: 0.0, alpha: 0.40))
        ctx.addEllipse(in: thumbRect)
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }
}

struct SoberSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double = 1.0) {
        self._value = value
        self.range = range
        self.step = step
    }
    
    func makeNSView(context: Context) -> SoberSliderNSView {
        let view = SoberSliderNSView()
        view.range = range
        view.step = step
        view.value = value
        view.onValueChanged = { newVal in
            DispatchQueue.main.async {
                self.value = newVal
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: SoberSliderNSView, context: Context) {
        nsView.range = range
        nsView.step = step
        if abs(nsView.value - value) > 0.0001 {
            nsView.value = value
        }
        nsView.onValueChanged = { newVal in
            DispatchQueue.main.async {
                self.value = newVal
            }
        }
    }
}

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
