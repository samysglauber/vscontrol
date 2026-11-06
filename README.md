# 🎛️ VS Control (Nativo para macOS)

Aplicativo nativo para macOS no estilo **Multitracks Playback / Apple Logic Pro**, desenvolvido especialmente para controle de VSs e faixas split ao vivo com latência zero e sincronização perfeita:
- **Canal L (Esquerdo):** Click + Voz Guia (*"Intro 2, 3, 4"*, *"Verso"*, *"Refrão"*, etc.)
- **Canal R (Direito):** Mix do VS (bateria, guitarras, synths, backing vocals)

---

## 🚀 Principais Funcionalidades

- **Mapeamento de Seções com Detecção IA:** Análise inteligente de forma de onda com blocos proporcionais, cores por tipo de seção e badges resumidos.
- **Salto Quantizado (Tempo 1):** Troca de seções e disparos quantizados no tempo 1 do próximo compasso.
- **Edição Completa de Cues:** Ajuste de compassos inteiros e meios compassos (`-1`, `-½`, `+½`, `+1`), split de blocos e tipos customizados.
- **Desfazer / Refazer Total (`⌘Z` / `⇧⌘Z`):** Histórico de até 50 passos com feedback visual em tempo real e persistência imediata.
- **Suporte ao Rolo do Mouse & Trackpad:** Navegação horizontal suave por toda a música no espectrograma.
- **Setlist Dinâmica:** Reorganização por drag & drop, transição automática e seleção de faixas.
- **Fade Stop Suave:** Fade out de 3 segundos disparado pela tecla `0` ou botão no painel.
- **Controle Remoto Web / Mobile:** Conexão com smartphones na mesma rede Wi-Fi via QR Code.

---

## 🍎 Como Abrir o App Nativo

Você pode abrir o aplicativo de qualquer um destes modos:
1. Dê dois cliques em **`VS Control.app`** dentro da raiz do projeto.
2. *(Opcional)* Arraste o **`VS Control.app`** para a sua pasta **`/Applications`** ou para o seu **Dock** do Mac!

---

## 🛠️ Como Compilar o App Swift

Para compilar o binário nativo do macOS:
```bash
./scripts/build.sh
```
Ou manualmente via terminal:
```bash
swiftc -O swift_app/main.swift -o swift_app/VSControl -framework SwiftUI -framework AppKit
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VSControl"
```

---

## 🔊 Status do BlackHole 2ch no seu Mac

O driver oficial **`BlackHole2ch.driver`** pode ser instalado através de:
```bash
./scripts/install_blackhole.sh
```
No macOS, drivers de áudio de sistema do CoreAudio precisam de um reinício do serviço de áudio:
```bash
sudo killall coreaudiod
```
Assim que feito, o **BlackHole 2ch** aparecerá automaticamente na lista de saídas de áudio do app e no Ableton Live.

---

## 📱 Como Conectar o Smartphone

1. Abra o app **VS Control** no Mac.
2. Clique no botão superior direito **`📱 Remote`**.
3. Aponte a câmera do celular para o **QR Code** exibido na tela.
4. O celular abrirá a interface web responsiva de palco móvel com botões grandes e resposta instantânea via WebSocket.
