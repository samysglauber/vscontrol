<div align="center">

# 🎛️ VS Control

### Playback de VSs e faixas split ao vivo, nativo para macOS

Estilo **Multitracks Playback / Apple Logic Pro**, com latência zero e sincronização perfeita.

![Plataforma](https://img.shields.io/badge/plataforma-macOS-000000?style=for-the-badge&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white)
![Áudio](https://img.shields.io/badge/áudio-CoreAudio%20%2B%20BlackHole-7B2FF7?style=for-the-badge)
![Remote](https://img.shields.io/badge/remote-WebSocket-00B894?style=for-the-badge)

[Funcionalidades](#-funcionalidades) •
[Como funciona](#-como-funciona) •
[Instalação](#-instalação) •
[Controle remoto](#-controle-remoto-pelo-smartphone) •
[Atalhos](#%EF%B8%8F-atalhos-de-teclado)

<!-- 📸 Adicione aqui um print ou GIF do app:
<img src="docs/screenshot.png" alt="VS Control" width="800">
-->

</div>

---

## 🎚️ Como funciona

O VS Control foi pensado para quem toca ao vivo com VSs em arquivos **split**: cada faixa tem dois canais independentes, que podem ser roteados para destinos diferentes.

| Canal | Conteúdo | Para quem vai |
|:-----:|----------|---------------|
| 🔈 **L** (esquerdo) | Click + voz guia (*"Intro 2, 3, 4"*, *"Verso"*, *"Refrão"*…) | Retorno do músico / in-ear |
| 🔊 **R** (direito) | Mix do VS: bateria, guitarras, synths, backing vocals | P.A. / mesa de som |

---

## ✨ Funcionalidades

| | Recurso | Descrição |
|---|---------|-----------|
| 🧠 | **Mapeamento de seções com detecção IA** | Análise inteligente da forma de onda com blocos proporcionais, cores por tipo de seção e badges resumidos |
| ⏱️ | **Salto quantizado (tempo 1)** | Trocas de seção e disparos sempre quantizados no tempo 1 do próximo compasso |
| ✂️ | **Edição completa de cues** | Ajuste de compassos inteiros e meios compassos (`-1`, `-½`, `+½`, `+1`), split de blocos e tipos customizados |
| ↩️ | **Desfazer / refazer total** | Histórico de até 50 passos, com feedback visual em tempo real e persistência imediata |
| 🖱️ | **Mouse e trackpad** | Navegação horizontal suave por toda a música no espectrograma |
| 📋 | **Setlist dinâmica** | Reorganização por drag & drop, transição automática e seleção de faixas |
| 🌅 | **Fade stop suave** | Fade out de 3 segundos pela tecla `0` ou pelo botão no painel |
| 📱 | **Controle remoto web / mobile** | Conexão com smartphones na mesma rede Wi-Fi via QR Code |

---

## 📦 Instalação

### Abrir o app pronto

1. Dê dois cliques em **`VS Control.app`**, na raiz do projeto.
2. *(Opcional)* Arraste o app para **`/Applications`** ou para o **Dock**.

### Compilar a partir do código-fonte

```bash
./scripts/build.sh
```

Ou manualmente pelo terminal:

```bash
swiftc -O swift_app/main.swift -o swift_app/VSControl -framework SwiftUI -framework AppKit
cp swift_app/VSControl "VS Control.app/Contents/MacOS/VSControl"
```

---

## 🔊 Roteamento de áudio com BlackHole 2ch

Para enviar o áudio do VS Control a outros softwares (como o **Ableton Live**), use o driver virtual **BlackHole 2ch**.

**1. Instale o driver**

```bash
./scripts/install_blackhole.sh
```

**2. Reinicie o serviço de áudio do macOS**

Drivers de áudio do CoreAudio exigem a reinicialização do serviço:

```bash
sudo killall coreaudiod
```

**3. Pronto!** O **BlackHole 2ch** aparecerá automaticamente na lista de saídas de áudio do app e no Ableton Live.

---

## 📱 Controle remoto pelo smartphone

Controle o palco direto do celular, sem cabos.

1. Abra o **VS Control** no Mac.
2. Clique no botão superior direito **`📱 Remote`**.
3. Aponte a câmera do celular para o **QR Code** exibido na tela.
4. O celular abre a interface web responsiva de palco, com botões grandes e resposta instantânea via **WebSocket**.

> 💡 O Mac e o smartphone precisam estar na **mesma rede Wi-Fi**.

---

## ⌨️ Atalhos de teclado

| Atalho | Ação |
|:------:|------|
| `⌘ Z` | Desfazer |
| `⇧ ⌘ Z` | Refazer |
| `0` | Fade stop (3 segundos) |

---

## 🗂️ Estrutura do projeto

```text
vscontrol/
├── VS Control.app/          # Aplicativo nativo pronto para uso
├── swift_app/
│   └── main.swift           # Código-fonte Swift (SwiftUI + AppKit)
└── scripts/
    ├── build.sh             # Compila o app
    └── install_blackhole.sh # Instala o driver BlackHole 2ch
```

---

<div align="center">

Feito com 🎶 para quem toca ao vivo.

</div>
