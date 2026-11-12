#!/bin/bash
# Script de compilação 100% Nativo em Swift do VS Control para macOS
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "=========================================="
echo "  🚀 Compilando VS Control (100% Native Swift)"
echo "=========================================="

swiftc -O \
    swift_app/NativeOSC.swift \
    swift_app/NativeMIDI.swift \
    swift_app/NativePadGenerator.swift \
    swift_app/NativeAudioEngine.swift \
    swift_app/NativeSongLibrary.swift \
    swift_app/NativeMetronome.swift \
    swift_app/NativeRemoteServer.swift \
    swift_app/main.swift \
    -o swift_app/VSControl \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework AudioToolbox \
    -framework CoreAudio \
    -framework CoreMIDI \
    -framework Accelerate \
    -framework Network

chmod +x swift_app/VSControl

mkdir -p "VS Control.app/Contents/MacOS"
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VSControl"
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VS Control"

echo "✅ Build nativo concluído com sucesso!"
echo "   Binário: $DIR/VS Control.app/Contents/MacOS/VS Control"
