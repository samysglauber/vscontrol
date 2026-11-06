#!/bin/bash
# Script de compilação do VS Control (Nativo macOS)
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

echo "=========================================="
echo "  🛠️  Compilando VS Control para macOS"
echo "=========================================="

swiftc -O swift_app/main.swift -o swift_app/VSControl -framework SwiftUI -framework AppKit
chmod +x swift_app/VSControl

mkdir -p "VS Control.app/Contents/MacOS"
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VSControl"

echo "✅ Build concluído com sucesso!"
echo "   Binário: $DIR/VS Control.app/Contents/MacOS/VSControl"
