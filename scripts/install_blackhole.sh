#!/bin/bash
# Script auxiliar para baixar e instalar o BlackHole 2ch no macOS
echo "=== Instalador do BlackHole 2ch ==="
echo ""
echo "O BlackHole é um driver virtual gratuito e de código aberto para macOS"
echo "que permite enviar o áudio deste aplicativo diretamente para o Ableton Live."
echo ""

# Verifica se o Homebrew existe
if command -v brew &> /dev/null; then
    echo "Homebrew detectado! Instalando BlackHole 2ch..."
    brew install blackhole-2ch
    echo "Instalação concluída!"
else
    echo "Homebrew não encontrado."
    echo "Abrindo a página oficial do BlackHole para download gratuito do instalador .pkg:"
    echo "👉 https://existential.audio/blackhole/"
    open "https://existential.audio/blackhole/"
fi
