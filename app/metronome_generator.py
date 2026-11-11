"""
Módulo Gerador de Metrônomo (Click Track)
Gera faixas de metrônomo estéreo (~10 minutos) com:
- Canal L (In-Ear): Click rítmico de estúdio (Downbeat acentuado + Sub-beats)
- Canal R (PA / VS): Silêncio (áudio limpo para palco)
Estruturado com contagem (Count-In de 2 compassos) e seções de 8 compassos para loop quantizado.
"""

import os
import re
import numpy as np
import soundfile as sf
from app.cue_detector import compute_full_waveform, compute_real_waveform_peaks
from app.song_library import atomic_save_json, get_saved_tracks_dir

# Cores vibrantes elegantes para blocos de seções de 8 compassos
SECTION_COLORS = [
    "#38bdf8",  # Ciano suave
    "#3b82f6",  # Azul Royal
    "#8b5cf6",  # Violeta
    "#ec4899",  # Rosa
    "#10b981",  # Esmeralda
    "#f59e0b",  # Âmbar
    "#06b6d4",  # Turquesa
    "#a855f7"   # Roxo
]

_click_cache = {}

def get_click_samples(sample_rate: int = 44100) -> tuple[np.ndarray, np.ndarray]:
    """Carrega e armazena em cache na memória RAM as amostras de click."""
    global _click_cache
    if sample_rate in _click_cache:
        return _click_cache[sample_rate]

    base_dir = os.path.dirname(__file__)
    c1_candidates = [
        os.path.join(base_dir, "resources", "clicks", "Click Track-1.wav"),
        os.path.join(os.path.dirname(base_dir), "Click Track-1.wav"),
        "Click Track-1.wav"
    ]
    c2_candidates = [
        os.path.join(base_dir, "resources", "clicks", "Click Track-2.wav"),
        os.path.join(os.path.dirname(base_dir), "Click Track-2.wav"),
        "Click Track-2.wav"
    ]

    c1_path = next((p for p in c1_candidates if os.path.exists(p)), None)
    c2_path = next((p for p in c2_candidates if os.path.exists(p)), None)

    if not c1_path or not c2_path:
        raise FileNotFoundError(f"Arquivos de som de click não encontrados! c1={c1_path}, c2={c2_path}")

    d1, sr1 = sf.read(c1_path)
    d2, sr2 = sf.read(c2_path)

    # Converte para mono float32
    m1 = (d1[:, 0] if d1.ndim > 1 else d1).astype(np.float32)
    m2 = (d2[:, 0] if d2.ndim > 1 else d2).astype(np.float32)

    # Normaliza
    if np.max(np.abs(m1)) > 0:
        m1 = m1 / (np.max(np.abs(m1)) + 1e-6) * 0.95
    if np.max(np.abs(m2)) > 0:
        m2 = m2 / (np.max(np.abs(m2)) + 1e-6) * 0.98

    _click_cache[sample_rate] = (m1, m2)
    return m1, m2

def parse_time_signature(time_sig: str) -> tuple[int, int]:
    """Converte string de fórmula de compasso (ex: '4/4', '6/8') em (numerador, denominador)."""
    ts = (time_sig or "4/4").strip()
    match = re.match(r'^(\d+)/(\d+)$', ts)
    if match:
        return int(match.group(1)), int(match.group(2))
    return 4, 4

def generate_metronome_track(
    name: str = "Click",
    bpm: float = 120.0,
    time_signature: str = "4/4",
    duration_sec: float = 600.0,
    output_dir: str | None = None,
    existing_filepath: str | None = None
) -> dict:
    """
    Gera ou atualiza uma faixa de metrônomo estéreo (~10 minutos) e seus metadados (.cues.json).
    Retorna o dicionário SongItem com is_metronome=True pronto para uso imediato.
    """
    sr = 44100
    bpm = max(30.0, min(300.0, float(bpm)))
    time_sig = (time_signature or "4/4").strip()
    beats_per_bar, denom = parse_time_signature(time_sig)
    
    # Cálculo temporal
    beat_sec = 60.0 / bpm
    bar_sec = beats_per_bar * beat_sec

    # Estrutura: 2 compassos de Count-In + seções de 8 compassos (~600 segundos no total = 10 minutos)
    count_in_bars = 2
    section_bars = 8
    target_sec = max(180.0, float(duration_sec))
    num_sections = max(2, int(np.ceil((target_sec - (count_in_bars * bar_sec)) / (section_bars * bar_sec))))
    total_bars = count_in_bars + num_sections * section_bars
    total_samples = int(total_bars * bar_sec * sr)
    total_duration = total_samples / sr

    audio = np.zeros((total_samples, 2), dtype=np.float32)

    # 1. Geração do Click no Canal L (In-Ear)
    click_regular, click_accent = get_click_samples(sample_rate=sr)
    for bar in range(total_bars):
        for beat in range(beats_per_bar):
            sample_pos = int((bar * beats_per_bar + beat) * beat_sec * sr)
            click_sample = click_accent if beat == 0 else click_regular
            avail = min(len(click_sample), total_samples - sample_pos)
            if avail > 0:
                audio[sample_pos:sample_pos + avail, 0] = click_sample[:avail]

    # Canal R é mantido como silêncio absoluto (zeros) para uso profissional ao vivo

    # 2. Determinação do Caminho do Arquivo
    out_dir = output_dir or get_saved_tracks_dir()
    os.makedirs(out_dir, exist_ok=True)

    raw_name = (name or "Click").strip()
    raw_name = re.sub(r'\.(wav|mp3|m4a)$', '', raw_name, flags=re.IGNORECASE).strip()
    if not raw_name:
        raw_name = "Click"

    clean_base = re.sub(r'[\\/*?:"<>|]', '_', raw_name)

    if existing_filepath and os.path.exists(existing_filepath):
        filepath = existing_filepath
        filename = os.path.basename(filepath)
    else:
        # Se o nome não contiver o BPM, adiciona para organização clara na pasta
        if not re.search(r'\b\d+\s*bpm\b', clean_base, re.IGNORECASE):
            filename_base = f"{clean_base} ({int(bpm)} BPM)"
        else:
            filename_base = clean_base

        filename = f"{filename_base}.wav"
        filepath = os.path.join(out_dir, filename)

        counter = 1
        while os.path.exists(filepath):
            filename = f"{filename_base} ({counter}).wav"
            filepath = os.path.join(out_dir, filename)
            counter += 1

    # 3. Salva arquivo WAV estéreo 16-bit
    sf.write(filepath, audio, sr, subtype='PCM_16')

    # 4. Geração das Seções / Cues (Count-In + Seções de 8 compassos)
    cues = []
    # Cue 0: Count-In (2 compassos)
    cues.append({
        "id": "cue_0",
        "name": "Count-In",
        "time": 0.0,
        "bar": 1.0,
        "color": "#64748b"  # Slate
    })

    # Seções numeradas de 8 compassos
    for s in range(num_sections):
        start_bar = count_in_bars + 1 + s * section_bars
        time_sec = (start_bar - 1) * bar_sec
        color = SECTION_COLORS[s % len(SECTION_COLORS)]
        cues.append({
            "id": f"cue_{s + 1}",
            "name": f"Section {s + 1}",
            "time": round(float(time_sec), 3),
            "bar": float(start_bar),
            "color": color
        })

    # 5. Cálculo das Formas de Onda (Waveform)
    # Espelha o canal L no canal R virtual para que o renderizador de waveform mostre os pulsos rítmicos do metrônomo
    waveform_audio = audio.copy()
    waveform_audio[:, 1] = waveform_audio[:, 0]

    full_wf = compute_full_waveform(waveform_audio, sr, n_peaks=1200)

    step_r = max(1, len(waveform_audio[:, 1]) // 2000)
    global_r_max = float(np.max(np.abs(waveform_audio[:, 1][::step_r])))
    if global_r_max < 0.01:
        global_r_max = float(np.max(np.abs(waveform_audio[:, 1])))
    if global_r_max < 0.01:
        global_r_max = 1.0

    for i, cue in enumerate(cues):
        start_t = float(cue["time"])
        end_t = float(cues[i + 1]["time"]) if i + 1 < len(cues) else total_duration
        cue["waveform"] = compute_real_waveform_peaks(
            waveform_audio, sr, start_t, end_t, n_peaks=64, global_r_max=global_r_max
        )

    # 6. Salva arquivo .cues.json atômico com flag is_metronome=True
    cues_payload = {
        "version": 6,
        "channel": "L",
        "bpm": bpm,
        "time_signature": time_sig,
        "total_duration": total_duration,
        "cues": cues,
        "full_waveform": full_wf,
        "default_key": "",
        "is_metronome": True
    }
    atomic_save_json(filepath + ".cues.json", cues_payload, backup=True)

    # 7. Retorna SongItem estruturado
    display_title = raw_name
    return {
        "id": filename,
        "filename": filename,
        "name": display_title,
        "path": filepath,
        "bpm": bpm,
        "time_signature": time_sig,
        "has_cached_cues": True,
        "default_key": "",
        "has_cover": False,
        "cover_url": None,
        "search_query": display_title,
        "total_duration": total_duration,
        "full_waveform": full_wf,
        "cues": cues,
        "is_metronome": True
    }

# Compatibilidade retroativa
generate_click_and_pad = generate_metronome_track
