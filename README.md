<div align="center">

<img src="docs/app-icon-256.png" alt="Ícone do VS Control" width="112" height="112">

# VS Control

**Playback de VSs split (L/R) para o palco. Nativo para macOS.**

Leve, rápido e confiável. Sem multitracks pesadas, sem complicação.

![macOS](https://img.shields.io/badge/macOS-000000?style=flat-square&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-F05138?style=flat-square&logo=swift&logoColor=white)
![WebSocket](https://img.shields.io/badge/Remote-WebSocket-00B894?style=flat-square)

<br>

<img src="docs/screenshot.png" alt="Tela principal do VS Control" width="900">

</div>

<br>

## Conceito

Feito exclusivamente para arquivos **split de dois canais**, o VS Control entrega carregamento instantâneo, troca imediata de repertório e estabilidade absoluta ao vivo.

| Canal | Conteúdo | Destino |
|:-----:|----------|---------|
| **L** | Click + voz guia | Fones / in-ear |
| **R** | Mix do VS | P.A. |

<br>

## Recursos

**Timeline de seções**  
Forma de onda contínua com blocos coloridos (Intro, Verso, Refrão, Ponte, Solo, Ending…), detecção por IA e edição direta em compassos e meios compassos.

**Salto quantizado**  
Repita um refrão, estenda uma ponte ou vá ao final. Todo disparo espera o tempo 1 do próximo compasso.

**Setlists `.vset`**  
Menu rápido na barra de título, troca instantânea, drag & drop e transição `AUTO` ou `STOP` por música. A faixa atual fica em destaque no escuro do palco.

**Fade das tracks**  
Reduz o P.A. em 3 segundos mantendo click e guia nos fones. Um novo clique traz tudo de volta com Fade In suave.

**Controle remoto**  
Escaneie o QR Code com o celular ou tablet e dispare tudo por WebSocket, na mesma rede Wi-Fi.

**Modo de edição protegido**  
Bloqueia alterações acidentais durante a apresentação.

<br>

## Atalhos

| Tecla | Ação |
|:-----:|------|
| `Espaço` | Play / Pause |
| `←` / `→` | Navegar pelas seções |
| `Enter` | Disparar salto quantizado para a seção |
| `Esc` | Cancelar seleção de seção |
| `L` | Ativar / desativar loop da seção |
| `0` | Fade out / fade in das tracks (3s) |
| `1` a `8` | Disparar músicas 1 a 8 da setlist |
| `⌘ Z` | Desfazer (até 50 passos) |
| `⇧ ⌘ Z` | Refazer |
| `⌘ N` | Novo setlist |
| `⌘ O` | Abrir setlist |
| `⌘ S` | Salvar setlist |
| `⇧ ⌘ S` | Salvar setlist como |

<br>

## Instalação e Execução

### Abrir o aplicativo pronto
1. Dê dois cliques em **`VS Control.app`** na raiz do projeto.
2. *(Opcional)* Arraste para a pasta **/Applications** ou adicione ao **Dock**.

### Compilar a partir do código-fonte
```bash
swiftc swift_app/main.swift -o "VS Control.app/Contents/MacOS/VSControl"
```

<br>

## Áudio com BlackHole 2ch

Para rotear o som para outros softwares ou DAWs:

```bash
./scripts/install_blackhole.sh
sudo killall coreaudiod
```

O **BlackHole 2ch** passa a aparecer nas saídas do app.

<br>

<div align="center">

<sub>Feito para quem toca ao vivo.</sub>

</div>
