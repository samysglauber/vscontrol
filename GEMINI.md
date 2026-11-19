# VS Control - AbletonTracks: Diretrizes e Contexto do Projeto

## 1. Visão Geral do Projeto (Overview)
- **Nome:** VS Control (AbletonTracks)
- **Propósito:** Sistema de alta performance para reprodução ao vivo de Multitracks / Virtual Stage (VS), cliques sincronizados, guias de voz (cues), metrônomo visual/auditivo, setlists dinâmicos e automação MIDI/OSC com Ableton Live para palcos e apresentações ao vivo.
- **Stack & Filosofia:** 100% nativo em Swift / SwiftUI / CoreAudio / AVFoundation / Accelerate / Metal no macOS.
- **Zero Dependências Pesadas:** Não há dependência de Python em tempo de execução. Todo processamento de áudio, detecção de clique e análise é executado nativamente em código Swift compilado.
- **Latência Ultra Baixa:** Resposta instantânea (0.00s de delay perceptual) com interface fluida acelerada por GPU.

---

## 2. Arquitetura de Áudio e Multitrack
- **Estrutura Estéreo dos Arquivos de Áudio:**
  - **Canal Esquerdo (Left / L):** Click track (metrônomo) + Voz Guia (Cues de contagem e seções faladas).
  - **Canal Direito (Right / R):** Áudio musical da banda / Backing Tracks (VS / Multitrack master).
- **Roteamento de Saída:**
  - Mixer Dock inferior permite controle independente de ganho e mudo para Click/Guia (L) e Tracks (R).
  - Seletor de dispositivo de saída de áudio CoreAudio com suporte a saídas estéreo e multi-canal (ex: BlackHole, fones e interfaces USB).
- **Quantização de Salto Musical e Loops (Jump & Loop Quantization):**
  - O clique em qualquer bloco/seção agenda um salto quantizado no **Tempo 1 (Downbeat)** do próximo compasso.
  - **Voz Guia Antecipada (Guide Lead-in):** Quando um salto, transição ou **Loop (1x ou Infinito)** está ativo, a voz guia correspondente é acionada no canal L exatamente ~1 compasso antes da virada/repetição para avisar a banda da mudança ou repetição iminente, enquanto o canal R continua a reprodução musical ininterrupta até o tempo 1.

---

## 3. Mapeamento dos Arquivos do Código (`swift_app/`)

### `swift_app/main.swift`
- Ponto de entrada do aplicativo macOS (`@main struct AbletonTracksApp: App`).
- `AppState`: Gerencia setlists, histórico global e visibilidade de sheets modais.
- `PlaybackState`: Estado central reativo da reprodução (`currentSong`, `isPlaying`, `currentSeconds`, `totalSeconds`, `currentCueIdx`, `currentCues`, `bpm`, `timeSignature`, etc.).
- Componentes visuais principais:
  - `TopBarView`: Metrônomo visual em tempo real, display de BPM e fórmula de compasso, relógio de tempo atual/total, transporte e alternância de loop contínuo/infinito.
  - `SetlistCarouselView`: Carrossel reordenável de músicas via arrastar e soltar (drag & drop), capas de álbum automáticas integradas ao iTunes/Spotify/Deezer.
  - `SpectrogramWaveformView`: Forma de onda desenhada com aceleração Metal, blocos de seções coloridos, playhead vermelho e divisórias verticais.
  - `BottomMixerDock`: Faders e botões Mute dedicados para Click/Guia e Tracks, menu dinâmico de saída de áudio.
  - `SongEditorSheetView`: Modal completo para edição de BPM, fórmula de compasso e seções.

### `swift_app/AudioEngine.swift`
- Motor de áudio de baixa latência baseado em CoreAudio e `AVAudioEngine`.
- Callback de renderização em tempo real (60 fps), gerência de buffers PCM, controle de faders e relógio MIDI Clock.
- `updateCurrentCueIdx()`: Determina qual seção está ativa com base na posição exata de reprodução (`currentSec >= cue.time`).
- Transições de áudio quantizadas no tempo 1 com crossfades suaves.

### `swift_app/CueDetector.swift`
- Análise de áudio nativa no canal L (Click/Guia) sem depender de Python.
- Detecção de picos de clique e transientes para cálculo de BPM quando o arquivo não traz o BPM no nome.
- Detecção de fórmula de compasso (4/4, 6/8, 3/4) via padrões de acentuação rítmica.
- Transcrição local de guias de voz usando o binário embutido Whisper.cpp (`whisper-cli` com modelo de alta fidelidade `ggml-base.bin` de 141 MB e fallback para `ggml-tiny.bin`).

### `swift_app/SongLibrary.swift`
- Varredura de pastas de músicas, extração e salvamento de seções em arquivos `.cues.json`.
- Extração resiliente de metadados do nome do arquivo (BPM fracionado com vírgula ou ponto, Tonalidade, Fórmula de Compasso).
- Cache em memória de durações, formas de onda e capas de disco.

### `swift_app/Database.swift`
- Indexador de metadados em SQLite local (`library.db`).

### `swift_app/RemoteServer.swift`
- Servidor local HTTP e WebSocket (Bonjour/mDNS) para controle remoto em tempo real via iPad, iPhone ou navegador.

### `swift_app/Mapping.swift`
- Gerenciamento de mapeamento de atalhos de teclado (KEY MAP) e controladores MIDI (MIDI MAP).

### `swift_app/Metronome.swift`
- Gerador e sintetizador de metrônomo/click procedural e editor de fórmula de compasso.

### `swift_app/MIDI.swift` & `swift_app/OSC.swift`
- Relógio MIDI Clock nativo (CoreMIDI) e protocolo de sincronização OSC para Ableton Live.

---

## 4. Regras de Ouro e Diretrizes Críticas de Implementação

### 1. Sincronização Estrita entre UI e `AudioEngine`
- **Regra Fundamental:** Toda e qualquer alteração de seções (`currentCues`), BPM (`bpm`) ou fórmula de compasso (`timeSignature`) na interface **DEVE ser enviada imediatamente para o `AudioEngine.shared`**.
- O motor de áudio calcula o bloco ativo (`currentCueIdx`) a cada buffer de áudio. Se a lista `audioEngine.cues` estiver desatualizada em relação a `state.currentCues`, o playhead vermelho e a seleção verde na tela ficarão descolados e dessincronizados.

### 2. Cálculo de Duração de Compasso (`secPerBar`)
- Fórmula padrão: `secPerBar = (60.0 / bpm) * (numerador * (4.0 / denominador))`.
- **Atenção:** 1 compasso em 6/8 dura menos tempo que 1 compasso em 4/4 no mesmo BPM!
  - 4/4 a 77 BPM: `(60 / 77) * 4 = ~3,12s`.
  - 6/8 a 77 BPM: `(60 / 77) * 3 = ~2,34s`.
- Toda conversão de compassos para segundos deve respeitar a fórmula correta do compasso ativo.

### 3. Ajuste de Compassos Seguro (`adjustSectionDuration`)
- A lista de seções DEVE manter monotonicidade cronológica estrita:
  $$\text{cues}[i].\text{time} < \text{cues}[i+1].\text{time} \quad \text{e} \quad \text{cues}[i].\text{bar} < \text{cues}[i+1].\text{bar}$$
- Ao ajustar `+1` ou `-1` compasso em um bloco:
  - Nunca permitir que o bloco vizinho seja reduzido a menos de 1 compasso (ou menos de 0.5s).
  - Nunca permitir que o início de um bloco colida ou ultrapasse o bloco subsequente (`index + 2`).
  - Se um bloco colapsar para largura negativa/zero, a interface une os blocos de forma desastrosa e desenha linhas presas no interior do bloco anterior.

### 4. Suporte a BPM Fracionado
- Músicas frequentemente usam BPMs com casas decimais (ex: `77,5 bpm`, `62,5bpm`, `68,5 bpm`).
- Nunca usar funções de arredondamento truncado como `round()` nos controles de ajuste fino de BPM.
- Sempre aceitar tanto vírgula `,` quanto ponto `.` na leitura e formatação (`formatBpm`).

### 5. Regras Musicais para Guia de Voz e Criação de Blocos
- **Isolamento Estrito do Canal L para IA/Whisper:**
  - O Whisper e o motor de detecção de voz operam **exclusivamente sobre o canal L** (`left`, Click + Guia). O canal R (banda/playback) NUNCA é enviado para transcrição.
  - O motivo de o Whisper ocasionalmente transcrever `[MÚSICA]` ou `♪` decorre exclusivamente dos cliques percussivos do metrônomo no canal L durante silêncios da voz guia (alucinação comum do Whisper com sons percussivos repetitivos), e **NÃO por vazamento da banda**.
- **Criação Exclusiva por Song Sections (Sem Divisões Arbitrárias por Tempo):**
  - Os cortes de blocos na música devem ser criados **EXCLUSIVAMENTE** a partir de anúncios explícitos de *Song Sections* (*Intro, Verso/Verse, Refrão/Chorus, Pré-Refrão/Pre-Chorus, Ponte/Bridge, Instrumental, Solo, Tag/Ministração, Ending/Final*).
  - A separação dos blocos baseia-se unicamente nas seções faladas e **NUNCA** em tempo decorrido, janelas fixas ou "fusão inteligente por duração".
- **Proibição de Criação Fictícia por Volume (RMS):** NUNCA inventar blocos com base na energia ou volume da banda (RMS) quando a voz guia não anunciou uma Song Section.
- **Ignorar Dinâmicas, Contagens e Ruídos:**
  - Palavras de dinâmica de arranjo (*"cresce"*, *"sobe"*, *"pausa"*, *"segura"*, *"suave"*, *"forte"*, *"corta"*, *"com palmas"*) **NÃO** geram cortes de seção.
  - Contagens rítmicas (*"1, 2, 3, 4"*), conversas espontâneas, respirações e marcadores automáticos do Whisper como `[MÚSICA]` devem ser **estritamente ignorados**.
- **Posição de Corte:** A voz guia antecede o trecho musical. O bloco musical correspondente deve começar cerca de **1 compasso após o anúncio da guia**, exatamente no Downbeat (tempo 1) onde os instrumentos entram.
- **Prioridade Absoluta de Song Sections sobre Dinâmica:** Frases como *"Refrão, toda banda!"* ou *"Refrão, cresce!"* contêm uma Song Section legítima acompanhada de dinamismo. A verificação estrutural (`mapLabel`) deve SEMPRE preceder a checagem de dinâmica, garantindo que a seção não seja descartada por conter uma palavra dinâmica auxiliar.
- **Biasing Contextual com `--prompt` no Whisper:** Devido às guias de áudio serem fatias curtas (~0.5s), o Whisper Tiny DEVE ser executado com `--prompt` contendo o vocabulário de palco (*"Guia de voz: 1, 2, 3, 4, Intro, Verso, Verso 1, Verso 2, Verso 3, Refrão, Pré-Refrão, Ponte, Instrumental, Solo, Final, Tag, Suave, Cresce, Segura, Toda banda."*). Sem prompt, o modelo alucina termos fonéticos distantes.
- **Mapeamento Fonético Resiliente (`mapLabel`):** Devido ao "R" aspirado em português (/h/) e nasalização de *"Refrão"*, o Whisper Tiny transcreve foneticamente variações como *efram*, *ifrao*, *hitfram*, *hitfrem*, *grafram*, *fram*, e *"Verso"* como *perço*. O `mapLabel` mapeia essas variações para garantir 100% de reconhecimento mesmo em gravações com ruído percussivo.
- **Autoridade Estrita do BPM Explícito (`hasHint`):** Em músicas com andamento lento (ex: `62,5 bpm`), é comum o metrônomo clicar em colcheias (subdivisão de 8ª a 125 cliques/min). Se o BPM está informado no arquivo ou pelo usuário, a duração do compasso DEVE ser calculada obrigatoriamente a partir de `bpmHint` (`bar = (60.0 / bpmHint) * beats`), NUNCA permitindo que a subdivisão do clique dobre ou altere o BPM da música para 125.
- **Diferenciação Robusta entre Pré-Refrão e Refrão:** A sílaba inicial *"Pré-"* é átona e tem volume menor que *"Refrão"*. Para evitar que ela seja decepada no corte, o pre-roll da fatia de áudio foi ampliado para 0.38s antes do início da fala detectada. Além disso, termos como *"prepara"* ou *"pressão"* (ex: *"Prepara pro refrão"*) não ativam mais o Pré-Refrão indevidamente, classificando a seção corretamente como Refrão.
- **Fidelidade Estrita aos Anúncios da Guia (Zero Numeração Artificial):** NUNCA numerar automaticamente seções como Verso 1, Verso 2, Verso 3... ou Refrão 1, Refrão 2, Refrão 3... quando a voz guia tiver anunciado apenas *"Verso"* ou *"Refrão"*. O nome da seção DEVE refletir estritamente o que foi falado. Um número só deve ser incluído quando a voz guia falar explicitamente o número (ex: *"Verso 2"*, *"Refrão 2"*, *"Segundo verso"*). Contagens antecedentes (ex: *"1, 2, 3, 4, Refrão"*) NUNCA devem ser interpretadas como número da seção.

### 6. Integridade da Forma de Onda e Badges Visuais
- **Preservação Contínua da Onda Sonora:** Ao reprocessar com IA (`reprocessWithAI`), o array de picos do Canal R (`fullWaveform`) deve ser sempre recalculado, salvo no SQLite/`.cues.json` e repassado para `state.fullWaveform`. A forma de onda nunca deve ficar vazia ou plana.
- **Badges Numéricos Dinâmicos:** A sigla de exibição nos blocos (`shortBadgeName`) deve extrair números de forma dinâmica por expressão regular (ex: `C5`, `C6`, `C7`, `V7`, `V8`), sem hardcode restrito a 4 ou 6 que reduza títulos legítimos a siglas soltas como `C` ou `V`.

### 7. Padrões de Interface (UI / UX)
- **Overlay de Análise ("Analyzing..."):** Quando a música estiver sendo processada por IA (ao importar ou clicar em "Reprocess with AI"), a área dos blocos/espectrograma deve exibir um efeito de desfoque escuro (*blur overlay*) com o texto centralizado `"Analyzing..."`. O cabeçalho deve permanecer limpo.
- **Undo / Redo:** Toda ação de edição de bloco, corte, divisão ou ajuste de compasso deve registrar snapshot na pilha de histórico (`pushUndoSnapshot`).
- **Zerar Divisões de Seções ("Clear Divisions"):** No modal `SongEditorSheetView` ("Edit Song"), há um card dedicado para gerenciamento de seções com badge dinâmico da contagem de seções e botão `"Clear Divisions"` (com confirmação e suporte total a `Cmd+Z` para desfazer). Ao acionar, redefine as divisões para uma única seção unificada contínua (0:00 até o final da música), persistindo imediatamente em SQLite/`.cues.json`/UserDefaults e sincronizando com o `AudioEngine`.
- **Aproximação de Zoom Ancorada no Ponteiro Vermelho (Playhead Zoom Centering):** Qualquer operação de zoom (botões Fit / 1x / 2x, gesto de pinça no trackpad ou Option/Command + scrollwheel) DEVE sempre aproximar ou afastar em direção a onde estiver o ponteiro vermelho de reprodução (`currentSeconds`), mantendo o cursor centralizado na viewport. O `TimelineZoomAnimator` interpola frame-a-frame a 60fps com curva ease-out cubic sincronizando escala e `bounds.origin` no mesmo frame, garantindo animação concêntrica 100% fluida sem saltos ou defasagem. Durante a reprodução com zoom, a timeline acompanha o ponteiro para que ele nunca saia da visão.

---

## 5. Compilação e Build
- **Script oficial:** `./scripts/build.sh`
- Compila todos os arquivos Swift com otimização `-O`, gera o binário em `swift_app/VSControl` e atualiza o pacote macOS em `VS Control.app`.
