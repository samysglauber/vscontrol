#!/bin/bash
# Script de compilação 100% Nativo em Swift do VS Control para macOS
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "=========================================="
echo "  🚀 Compilando VS Control (100% Native Swift)"
echo "=========================================="

swiftc -O \
    swift_app/OSC.swift \
    swift_app/MIDI.swift \
    swift_app/Mapping.swift \
    swift_app/AudioEngine.swift \
    swift_app/Database.swift \
    swift_app/CueDetector.swift \
    swift_app/SongLibrary.swift \
    swift_app/Metronome.swift \
    swift_app/RemoteServer.swift \
    swift_app/SettingsView.swift \
    swift_app/main.swift \
    -o swift_app/VSControl \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreMIDI \
    -framework Accelerate \
    -framework Network \
    -framework Speech \
    -lsqlite3

chmod +x swift_app/VSControl

mkdir -p "VS Control.app/Contents/MacOS"
mkdir -p "VS Control.app/Contents/Resources/models"
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VSControl"
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VS Control"

if [ -f "swift_app/whisper/whisper-cli" ]; then
    cp "swift_app/whisper/whisper-cli" "VS Control.app/Contents/Resources/whisper-cli"
    chmod +x "VS Control.app/Contents/Resources/whisper-cli"
fi

if [ -f "swift_app/whisper/models/ggml-base.bin" ]; then
    cp "swift_app/whisper/models/ggml-base.bin" "VS Control.app/Contents/Resources/models/ggml-base.bin"
fi

if [ -f "swift_app/whisper/models/ggml-tiny.bin" ]; then
    cp "swift_app/whisper/models/ggml-tiny.bin" "VS Control.app/Contents/Resources/models/ggml-tiny.bin"
fi

echo "✅ Build nativo concluído com sucesso!"
echo "   Binário: $DIR/VS Control.app/Contents/MacOS/VS Control"
