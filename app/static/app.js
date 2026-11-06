// VS Control - Frontend WebSocket Client

let ws = null;
let currentSong = null;
let songsList = [];
let cues = [];
let isPlaying = false;
let loopActive = false;
let padActive = false;
let currentCueIdx = 0;
let queuedCueIdx = null;

// Elementos do DOM
const btnToggleSidebar = document.getElementById("btn-toggle-sidebar");
const appleSidebar = document.getElementById("apple-sidebar");
const abletonSyncPill = document.getElementById("ableton-sync-pill");
const titlebarSongNameEl = document.getElementById("titlebar-song-name");
const songsCountEl = document.getElementById("songs-count");
const bpmValEl = document.getElementById("bpm-val");
const sigValEl = document.getElementById("sig-val");
const barNumberEl = document.getElementById("bar-number");
const beatDots = document.getElementById("beat-dots").querySelectorAll(".dot");
const timeDisplayEl = document.getElementById("time-display");
const timelineTrack = document.getElementById("timeline-track");
const timelineProgress = document.getElementById("timeline-progress");
const timelinePlayhead = document.getElementById("timeline-playhead");
const cuesOverlay = document.getElementById("cues-overlay");
const cuePadsGrid = document.getElementById("cue-pads-grid");
const jumpStatusEl = document.getElementById("jump-status");

// Controles
const btnPlayPause = document.getElementById("btn-play-pause");
const iconPlay = document.getElementById("icon-play");
const iconPause = document.getElementById("icon-pause");
const playText = document.getElementById("play-text");
const btnStop = document.getElementById("btn-stop");
const btnLoop = document.getElementById("btn-loop");
const btnPad = document.getElementById("btn-pad");
const padKeySelect = document.getElementById("pad-key-select");

// Volumes
const volClick = document.getElementById("vol-click");
const clickVal = document.getElementById("click-val");
const btnClickMute = document.getElementById("btn-click-mute");
const volVs = document.getElementById("vol-vs");
const vsVal = document.getElementById("vs-val");
const btnVsMute = document.getElementById("btn-vs-mute");

// Drawer e Modal
const songsDrawer = document.getElementById("songs-drawer");
const btnToggleSongs = document.getElementById("btn-toggle-songs");
const btnCloseDrawer = document.getElementById("btn-close-drawer");
const songsListEl = document.getElementById("songs-list");
const songSearchInput = document.getElementById("song-search-input");
const btnQrModal = document.getElementById("btn-qr-modal");
const qrModal = document.getElementById("qr-modal");
const btnCloseModal = document.getElementById("btn-close-modal");
const qrContainer = document.getElementById("qr-container");
const qrUrlText = document.getElementById("qr-url-text");
const deviceSelect = document.getElementById("device-select");

// Inicialização
document.addEventListener("DOMContentLoaded", () => {
  initWebSocket();
  loadSongs();
  loadDevices();
  loadNetworkInfo();
  setupEventListeners();
  requestWakeLock();
});

// ==========================
// CONEXÃO WEBSOCKET
// ==========================
function initWebSocket() {
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  ws = new WebSocket(`${protocol}//${window.location.host}/ws`);

  ws.onopen = () => {
    console.log("WebSocket conectado com sucesso!");
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      handleServerEvent(msg.event, msg.data);
    } catch (e) {
      console.error("Erro ao processar mensagem do servidor:", e);
    }
  };

  ws.onclose = () => {
    console.warn("WebSocket desconectado. Tentando reconectar em 2s...");
    setTimeout(initWebSocket, 2000);
  };
}

function sendWs(action, payload = {}) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action, ...payload }));
  } else {
    // Fallback REST
    fetch(`/api/${action}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }).catch(console.error);
  }
}

// ==========================
// PROCESSAMENTO DE EVENTOS EM TEMPO REAL
// ==========================
function handleServerEvent(event, data) {
  if (event === "tick" || event === "status") {
    updatePlaybackStatus(data);
  } else if (event === "cue_queued") {
    queuedCueIdx = data.queued_cue_idx;
    jumpStatusEl.textContent = `SALTO PROGRAMADO: COMPASSO ${data.target_bar}`;
    renderPadsState();
  } else if (event === "cue_jumped") {
    currentCueIdx = data.current_cue_idx;
    queuedCueIdx = null;
    jumpStatusEl.textContent = "";
    renderPadsState();
  } else if (event === "play_state") {
    isPlaying = data.is_playing;
    updatePlayPauseButton();
  } else if (event === "loop_state") {
    loopActive = data.loop_active;
    btnLoop.classList.toggle("active", loopActive);
  } else if (event === "pad_state") {
    padActive = data.pad_active;
    btnPad.classList.toggle("active", padActive);
  }
}

function updatePlaybackStatus(status) {
  isPlaying = status.is_playing;
  currentCueIdx = status.current_cue_idx;
  queuedCueIdx = status.queued_cue_idx;
  loopActive = status.loop_active;
  padActive = status.pad_active;

  updatePlayPauseButton();
  btnLoop.classList.toggle("active", loopActive);
  btnPad.classList.toggle("active", padActive);

  // Compasso e Tempo
  barNumberEl.textContent = String(status.bar).padStart(3, "0");
  const beat = status.beat || 1;
  beatDots.forEach((dot, idx) => {
    dot.className = "dot";
    if (idx + 1 === beat) {
      dot.classList.add(beat === 1 ? "downbeat" : "active");
    }
  });

  // Tempo decorrido / total
  timeDisplayEl.textContent = `${formatTime(status.current_seconds)} / ${formatTime(status.total_seconds)}`;

  // Progresso na Timeline
  if (status.total_seconds > 0) {
    const pct = (status.current_seconds / status.total_seconds) * 100;
    timelineProgress.style.width = `${pct}%`;
    timelinePlayhead.style.left = `${pct}%`;
  }

  // Atualiza estado dos Pads se não tiverem sido renderizados ainda
  if (cues.length === 0 && status.cues && status.cues.length > 0) {
    cues = status.cues;
    renderCues();
  } else {
    renderPadsState();
  }
}

function updatePlayPauseButton() {
  if (isPlaying) {
    iconPlay.style.display = "none";
    iconPause.style.display = "block";
    playText.textContent = "PAUSE";
    btnPlayPause.classList.add("playing");
  } else {
    iconPlay.style.display = "block";
    iconPause.style.display = "none";
    playText.textContent = "PLAY";
    btnPlayPause.classList.remove("playing");
  }
}

function formatTime(sec) {
  const m = Math.floor(sec / 60);
  const s = Math.floor(sec % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

// ==========================
// RENDERIZAÇÃO DE CUES E TIMELINE
// ==========================
function renderCues() {
  // 1. Overlay da Timeline
  cuesOverlay.innerHTML = "";
  const totalSec = currentSong?.duration || (cues.length > 0 ? cues[cues.length - 1].time + 30 : 200);

  cues.forEach((c, idx) => {
    const pct = (c.time / totalSec) * 100;
    const marker = document.createElement("div");
    marker.className = "cue-marker";
    marker.style.left = `${pct}%`;
    marker.style.borderColor = c.color;
    marker.style.color = c.color;
    marker.textContent = c.name;
    marker.onclick = (e) => {
      e.stopPropagation();
      triggerCue(idx);
    };
    cuesOverlay.appendChild(marker);
  });

  // 2. Grid de Pads
  cuePadsGrid.innerHTML = "";
  cues.forEach((c, idx) => {
    const pad = document.createElement("div");
    pad.className = "cue-pad";
    pad.id = `cue-pad-${idx}`;
    pad.style.setProperty("--pad-color", c.color);

    pad.innerHTML = `
      <div class="cue-pad-top">
        <span class="cue-pad-bar">COMP. ${c.bar}</span>
        <span class="cue-pad-time">${formatTime(c.time)}</span>
      </div>
      <div class="cue-pad-name">${c.name}</div>
    `;

    pad.addEventListener("click", () => triggerCue(idx));
    cuePadsGrid.appendChild(pad);
  });

  renderPadsState();
}

function renderPadsState() {
  cues.forEach((_, idx) => {
    const pad = document.getElementById(`cue-pad-${idx}`);
    if (!pad) return;

    pad.classList.remove("active", "queued");
    if (idx === currentCueIdx) {
      pad.classList.add("active");
    }
    if (idx === queuedCueIdx) {
      pad.classList.add("queued");
    }
  });
}

function triggerCue(idx) {
  sendWs("trigger_cue", { cue_idx: idx, quantize: true });
}

// ==========================
// MÚSICAS E DISPOSITIVOS
// ==========================
async function loadSongs() {
  try {
    const res = await fetch("/api/songs");
    songsList = await res.json();
    renderSongsList(songsList);

    // Se tiver músicas, carrega a primeira por padrão
    if (songsList.length > 0) {
      loadSong(songsList[0].id);
    }
  } catch (err) {
    console.error("Erro ao carregar lista de músicas:", err);
  }
}

function renderSongsList(list) {
  if (songsCountEl) songsCountEl.textContent = list.length;
  songsListEl.innerHTML = "";
  list.forEach((song) => {
    const item = document.createElement("div");
    item.className = "song-item";
    if (currentSong && currentSong.id === song.id) {
      item.classList.add("active");
    }

    item.innerHTML = `
      <div class="song-item-name">${song.name}</div>
      <div class="song-item-bpm">${song.bpm ? song.bpm + ' BPM' : 'Auto'}</div>
    `;

    item.onclick = () => {
      loadSong(song.id);
      if (songsDrawer) songsDrawer.classList.remove("open");
    };
    songsListEl.appendChild(item);
  });
}

async function loadSong(songId) {
  try {
    const res = await fetch("/api/load", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ song_id: songId })
    });
    const data = await res.json();
    currentSong = data.song;

    songTitleEl.textContent = currentSong.name;
    if (titlebarSongNameEl) titlebarSongNameEl.textContent = currentSong.name;
    bpmValEl.textContent = `${currentSong.bpm || '--'} BPM`;
    cues = currentSong.cues || [];
    renderCues();
    renderSongsList(songsList);

    // Feedback visual de sincronização de BPM com o Ableton Live
    if (abletonSyncPill && currentSong.bpm) {
      abletonSyncPill.classList.add("synced");
      abletonSyncPill.querySelector("span:last-child").textContent = `Ableton: ${currentSong.bpm} BPM`;
      setTimeout(() => abletonSyncPill.classList.remove("synced"), 2500);
    }
  } catch (err) {
    console.error("Erro ao carregar música:", err);
  }
}

async function loadDevices() {
  try {
    const res = await fetch("/api/devices");
    const devices = await res.json();
    if (!deviceSelect) return;
    deviceSelect.innerHTML = "";
    
    let blackholeFound = false;
    devices.forEach((d) => {
      const opt = document.createElement("option");
      opt.value = d.id;
      opt.textContent = `${d.name} (${d.channels} ch)${d.is_blackhole ? ' ⭐ (Ableton Live)' : ''}`;
      if (d.is_blackhole) {
        opt.selected = true;
        blackholeFound = true;
        fetch("/api/device", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ device_id: d.id })
        }).catch(console.error);
      } else if (!blackholeFound && d.is_default) {
        opt.selected = true;
      }
      deviceSelect.appendChild(opt);
    });
  } catch (err) {
    console.error("Erro ao carregar dispositivos de áudio:", err);
  }
}

async function loadNetworkInfo() {
  try {
    const res = await fetch("/api/network_info");
    const info = await res.json();
    if (qrContainer && info.qr_svg) {
      qrContainer.innerHTML = info.qr_svg;
      const svgEl = qrContainer.querySelector("svg");
      if (svgEl) {
        svgEl.setAttribute("width", "190");
        svgEl.setAttribute("height", "190");
      }
    }
    if (qrUrlText) {
      qrUrlText.textContent = info.url;
    }
  } catch (err) {
    console.error("Erro ao obter informações de rede:", err);
  }
}

// ==========================
// EVENT LISTENERS
// ==========================
function setupEventListeners() {
  btnPlayPause.onclick = () => {
    sendWs(isPlaying ? "pause" : "play");
  };

  btnStop.onclick = () => {
    sendWs("stop");
  };

  btnLoop.onclick = () => {
    sendWs("toggle_loop");
  };

  btnPad.onclick = () => {
    sendWs("set_pad", {
      active: !padActive,
      key: padKeySelect.value,
      volume: 0.35
    });
  };

  padKeySelect.onchange = () => {
    if (padActive) {
      sendWs("set_pad", { active: true, key: padKeySelect.value });
    }
  };

  // Volumes
  volClick.oninput = () => {
    clickVal.textContent = `${Math.round(volClick.value * 100)}%`;
    sendVolumes();
  };

  volVs.oninput = () => {
    vsVal.textContent = `${Math.round(volVs.value * 100)}%`;
    sendVolumes();
  };

  btnClickMute.onclick = () => {
    btnClickMute.classList.toggle("muted");
    sendVolumes();
  };

  btnVsMute.onclick = () => {
    btnVsMute.classList.toggle("muted");
    sendVolumes();
  };

  function sendVolumes() {
    fetch("/api/volumes", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        click_vol: parseFloat(volClick.value),
        vs_vol: parseFloat(volVs.value),
        click_mute: btnClickMute.classList.contains("muted"),
        vs_mute: btnVsMute.classList.contains("muted")
      })
    }).catch(console.error);
  }

  // Seek na Timeline
  timelineTrack.onclick = (e) => {
    const rect = timelineTrack.getBoundingClientRect();
    const clickX = e.clientX - rect.left;
    const pct = clickX / rect.width;
    const totalSec = currentSong?.duration || 200;
    fetch("/api/seek", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ seconds: pct * totalSec })
    });
  };

  // Dispositivo de Áudio
  if (deviceSelect) {
    deviceSelect.onchange = () => {
      fetch("/api/device", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ device_id: parseInt(deviceSelect.value) })
      });
    };
  }

  // Sidebar Retrátil (Menu de Músicas)
  if (localStorage.getItem("sidebar_collapsed") === "true" && appleSidebar) {
    appleSidebar.classList.add("collapsed");
  }

  if (btnToggleSidebar && appleSidebar) {
    btnToggleSidebar.onclick = () => {
      const isCollapsed = appleSidebar.classList.toggle("collapsed");
      localStorage.setItem("sidebar_collapsed", isCollapsed ? "true" : "false");
    };
  }
  if (btnToggleSongs && songsDrawer) {
    btnToggleSongs.onclick = () => songsDrawer.classList.toggle("open");
  }
  if (btnCloseDrawer && songsDrawer) {
    btnCloseDrawer.onclick = () => songsDrawer.classList.remove("open");
  }
  if (songSearchInput) {
    songSearchInput.oninput = () => {
      const term = songSearchInput.value.toLowerCase();
      const filtered = songsList.filter(s => s.name.toLowerCase().includes(term) || (s.bpm && String(s.bpm).includes(term)));
      renderSongsList(filtered);
    };
  }

  // Modal QR Code
  if (btnQrModal && qrModal) {
    btnQrModal.onclick = () => qrModal.classList.add("open");
  }
  if (btnCloseModal && qrModal) {
    btnCloseModal.onclick = () => qrModal.classList.remove("open");
  }
  if (qrModal) {
    qrModal.onclick = (e) => {
      if (e.target === qrModal) qrModal.classList.remove("open");
    };
  }

  // Atalhos de Teclado no Mac
  window.addEventListener("keydown", (e) => {
    if (e.target.tagName === "INPUT") return;
    
    // Cmd+B ou B: Ocultar/Exibir Sidebar de músicas
    if ((e.metaKey || e.ctrlKey) && e.code === "KeyB") {
      e.preventDefault();
      if (btnToggleSidebar) btnToggleSidebar.click();
      return;
    }

    if (e.code === "Space") {
      e.preventDefault();
      btnPlayPause.click();
    } else if (e.code === "KeyL") {
      btnLoop.click();
    } else if (e.code === "KeyP") {
      btnPad.click();
    } else if (e.code === "KeyB") {
      if (btnToggleSidebar) btnToggleSidebar.click();
    } else if (e.code === "Escape") {
      btnStop.click();
    }
  });
}

// Mantém a tela do smartphone Android ligada durante o culto/ensaio
function requestWakeLock() {
  if ("wakeLock" in navigator) {
    try {
      navigator.wakeLock.request("screen");
    } catch (e) {
      console.log("WakeLock não suportado ou bloqueado:", e);
    }
  }
}
