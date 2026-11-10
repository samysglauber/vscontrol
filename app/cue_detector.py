"""
Módulo de Detecção Inteligente de BPM, Cues e Extração de Espectrograma Real
Analisa arquivos de áudio estéreo com:
- Canal L: Click + Voz Guia
- Canal R: VS (Playback / Instrumentos adicionais)
"""

import os
import re
import json
import numpy as np
import soundfile as sf

_vosk_models = {}

def get_vosk_models():
    """Carrega os modelos leves de voz PT e EN uma única vez (cached)."""
    global _vosk_models
    if "pt" not in _vosk_models or "en" not in _vosk_models:
        try:
            import vosk
            vosk.SetLogLevel(-1)
            if "pt" not in _vosk_models:
                _vosk_models["pt"] = vosk.Model(lang="pt")
            if "en" not in _vosk_models:
                _vosk_models["en"] = vosk.Model(lang="en-us")
        except Exception as e:
            pass
    return _vosk_models

def classify_spoken_text(text: str) -> str | None:
    if not text:
        return None
    t = text.lower().strip()
    
    # Pré-refrão / Pre-Chorus
    if any(k in t for k in ["pré", "pre", "pre-chorus", "pré-refrão", "pre chorus"]):
        return "Pre-Chorus"
        
    # Pós-refrão / Post-Chorus
    if any(k in t for k in ["pós", "pos", "post", "post-chorus", "pos-refrão"]):
        return "Post Chorus"
        
    # Refrão / Coro / Chorus
    if any(k in t for k in ["refrão", "refrao", "chorus", "coro", "refra"]):
        return "Chorus"
        
    # Ponte / Bridge
    if any(k in t for k in ["ponte", "bridge"]):
        return "Bridge"
        
    # Instrumental
    if any(k in t for k in ["instrumental", "instru", "instrument"]):
        return "Instrumental"
        
    # Interlúdio / Interlude
    if any(k in t for k in ["interlúdio", "interludio", "interlude", "inter"]):
        return "Interlude"
        
    # Solo
    if any(k in t for k in ["solo"]):
        return "Solo"
        
    # Tag
    if any(k in t for k in ["tag"]):
        return "Tag"
        
    # Outro
    if any(k in t for k in ["outro"]):
        return "Outro"
        
    # Final / Ending / Termina
    if any(k in t for k in ["final", "termina", "fim", "ending", "corta"]):
        return "Ending"
        
    # Verso / Verse com numeração específica
    if any(k in t for k in ["verso um", "verso 1", "primeiro verso", "verse one", "verse 1"]):
        return "Verse 1"
    if any(k in t for k in ["verso dois", "verso 2", "segundo verso", "verse two", "verse 2"]):
        return "Verse 2"
    if any(k in t for k in ["verso três", "verso 3", "terceiro verso", "verse three", "verse 3"]):
        return "Verse 3"
    if any(k in t for k in ["verso quatro", "verso 4", "verse four", "verse 4"]):
        return "Verse 4"
        
    # Verso sem número / Verse (ou berço fonético comum em áudios com ruído)
    if any(k in t for k in ["verso", "verse", "berço", "berco"]):
        return "Verse"
        
    return None

def recognize_voice_burst(audio_left: np.ndarray, sr: int, start_sec: float, end_sec: float) -> str | None:
    """
    Reconhece o comando de voz falado pela voz guia na faixa esquerda (L)
    usando modelos offline leves em Português e Inglês.
    """
    models = get_vosk_models()
    if not models:
        return None
        
    s_f = max(0, int((start_sec - 0.25) * sr))
    e_f = min(len(audio_left), int((end_sec + 0.35) * sr))
    if e_f <= s_f:
        return None
        
    chunk = audio_left[s_f:e_f]
    target_len = int(len(chunk) * 16000 / sr)
    if target_len < 1600:
        return None
        
    resampled = np.interp(np.linspace(0, len(chunk), target_len, endpoint=False), np.arange(len(chunk)), chunk)
    int16_pcm = (np.clip(resampled, -1.0, 1.0) * 32767).astype(np.int16).tobytes()
    
    import vosk
    
    # 1. Tenta reconhecer em Português primeiro (maioria dos VSs)
    if "pt" in models:
        try:
            rec_pt = vosk.KaldiRecognizer(models["pt"], 16000)
            rec_pt.AcceptWaveform(int16_pcm)
            res = json.loads(rec_pt.FinalResult())
            classified = classify_spoken_text(res.get("text", ""))
            if classified:
                return classified
        except Exception:
            pass
            
    # 2. Tenta reconhecer em Inglês
    if "en" in models:
        try:
            rec_en = vosk.KaldiRecognizer(models["en"], 16000)
            rec_en.AcceptWaveform(int16_pcm)
            res = json.loads(rec_en.FinalResult())
            classified = classify_spoken_text(res.get("text", ""))
            if classified:
                return classified
        except Exception:
            pass
            
    return None

def color_for_name(name: str) -> str:
    upper = name.upper()
    if "COUNT" in upper or "CONTAGEM" in upper:
        return "#64748b"
    if "POST" in upper or "PÓS" in upper:
        return "#fb7185"
    if "PRE" in upper or "PRÉ" in upper:
        return "#eab308"
    if "CHORUS" in upper or "REFRÃO" in upper or "CORO" in upper:
        return "#ef4444"
    if "BRIDGE" in upper or "PONTE" in upper:
        return "#f97316"
    if "INTRO" in upper or "INTRODUÇÃO" in upper:
        return "#38bdf8"
    if "INSTRUMENTAL" in upper:
        return "#10b981"
    if "VERSE" in upper or "VERSO" in upper:
        return "#a855f7"
    if "INTERLUDE" in upper or "INTERLÚDIO" in upper:
        return "#06b6d4"
    if "SOLO" in upper:
        return "#06b6d4"
    if "TAG" in upper:
        return "#ec4899"
    if "OUTRO" in upper or "ENDING" in upper or "FINAL" in upper:
        return "#64748b"
    return "#3b82f6"

def extract_bpm_from_filename(filename: str) -> float | None:
    """Extrai o BPM a partir do nome do arquivo."""
    match = re.search(r'\((\d+(?:[.,]\d+)?)\s*bpm\)', filename, re.IGNORECASE)
    if match:
        return float(match.group(1).replace(',', '.'))
    
    match_start = re.search(r'^(\d+(?:[.,]\d+)?)\s*bpm', filename, re.IGNORECASE)
    if match_start:
        return float(match_start.group(1).replace(',', '.'))
        
    match_any = re.search(r'(\d+(?:[.,]\d+)?)\s*bpm', filename, re.IGNORECASE)
    if match_any:
        return float(match_any.group(1).replace(',', '.'))
        
    return None


def detect_click_bpm_from_audio(filepath: str, max_seconds: int = 25) -> float:
    """Fallback: detecta o BPM analisando os transientes de clique no canal L."""
    try:
        data, sr = sf.read(filepath, frames=44100 * max_seconds)
    except Exception:
        data, sr = sf.read(filepath)
        
    left = data[:, 0] if len(data.shape) > 1 else data
    diff = np.abs(np.diff(left))
    thresh = np.percentile(diff, 99.2)
    spikes = np.where(diff > thresh)[0]
    
    if len(spikes) < 8:
        return 120.0
        
    min_dist = int(sr * 0.2)
    filtered = [spikes[0]]
    for s in spikes[1:]:
        if s - filtered[-1] >= min_dist:
            filtered.append(s)
            
    intervals = np.diff(filtered) / sr
    if len(intervals) < 4:
        return 120.0
        
    median_interval = np.median(intervals)
    raw_bpm = 60.0 / median_interval
    
    while raw_bpm < 55:
        raw_bpm *= 2
    while raw_bpm > 190:
        raw_bpm /= 2
        
    return round(raw_bpm, 1)


def compute_real_waveform_peaks(audio_data: np.ndarray, sr: int, start_time: float, end_time: float, n_peaks: int = 64, global_r_max: float | None = None) -> list[float]:
    """
    Extrai a envoltória / picos de áudio REAIS da faixa de áudio para uma seção específica.
    Usa EXCLUSIVAMENTE o Canal R (instrumentos / playback VS), ignorando o clique e contagem da faixa L.
    Calibrado para amplitude visível, robusta e clara, com headroom suave para evitar cortes no teto.
    """
    start_frame = max(0, int(start_time * sr))
    end_frame = min(len(audio_data), int(end_time * sr))
    
    if end_frame <= start_frame:
        return [0.05] * n_peaks

    # Canal R (index 1) = VS / Instrumentos / Playback musical
    # Canal L (index 0) = Click + Voz Guia
    if audio_data.ndim > 1:
        channel_r = audio_data[:, 1]
    else:
        channel_r = audio_data

    chunk = np.abs(channel_r[start_frame:end_frame])

    if global_r_max is None or global_r_max <= 0.001:
        step_sub = max(1, len(channel_r) // 2000)
        global_r_max = float(np.max(np.abs(channel_r[::step_sub])))
        if global_r_max < 0.01:
            global_r_max = float(np.max(np.abs(channel_r)))
        if global_r_max < 0.01:
            global_r_max = 1.0

    step = max(1, len(chunk) // n_peaks)
    peaks = []
    for i in range(n_peaks):
        s = i * step
        e = min(len(chunk), s + step)
        sub = chunk[s:e]
        if len(sub) > 0:
            rms_val = float(np.sqrt(np.mean(sub**2)))
            peak_val = float(np.max(sub))
            # 30% RMS + 70% Peak: mantém transientes bem visíveis e corpo acústico
            val = 0.30 * rms_val + 0.70 * peak_val
        else:
            val = 0.04
        
        # Headroom de 5% e curva dinâmica suave que nunca ceifa em platô horizontal plano
        ratio = val / (global_r_max * 1.05)
        scaled = np.tanh(ratio * 1.5) / np.tanh(1.5) * 0.95
        norm_val = round(max(0.04, min(0.96, float(scaled))), 3)
        peaks.append(norm_val)

    return peaks


def compute_full_waveform(audio_data: np.ndarray, sr: int, n_peaks: int = 1200) -> list[float]:
    """
    Extrai a envoltória contínua da faixa completa do Canal R (instrumentos/VS)
    para visualização em fundo único e contínuo, sem emendas ou cortes.
    """
    if audio_data is None or len(audio_data) == 0:
        return [0.04] * n_peaks

    if audio_data.ndim > 1:
        channel_r = audio_data[:, 1]
    else:
        channel_r = audio_data

    total_len = len(channel_r)
    step_sub = max(1, total_len // 2000)
    global_r_max = float(np.max(np.abs(channel_r[::step_sub])))
    if global_r_max < 0.01:
        global_r_max = float(np.max(np.abs(channel_r)))
    if global_r_max < 0.01:
        global_r_max = 1.0

    step = max(1, total_len // n_peaks)
    peaks = []
    chunk = np.abs(channel_r)
    for i in range(n_peaks):
        s = i * step
        e = min(total_len, s + step)
        sub = chunk[s:e]
        if len(sub) > 0:
            rms_val = float(np.sqrt(np.mean(sub**2)))
            peak_val = float(np.max(sub))
            val = 0.30 * rms_val + 0.70 * peak_val
        else:
            val = 0.04
        ratio = val / (global_r_max * 1.05)
        scaled = np.tanh(ratio * 1.5) / np.tanh(1.5) * 0.95
        norm_val = round(max(0.04, min(0.96, float(scaled))), 3)
        peaks.append(norm_val)

    return peaks


def detect_cues(filepath: str, bpm: float, time_signature: tuple[int, int] = (4, 4), force_reprocess: bool = False) -> list[dict]:
    """
    Analisa a faixa esquerda (Click + Guia) e canal direito (VS) para localizar as 
    transições de seções e gerar espectrogramas / formas de onda reais com IA/DSP.
    Retorna imediatamente se o cache com Canal R já existir.
    """
    cache_path = filepath + ".cues.json"
    
    # 1. Carregamento ultra rápido do Cache (sem ler o arquivo de áudio se já existir)
    if not force_reprocess:
        from app.song_library import load_cues_with_backup
        cached = load_cues_with_backup(cache_path)
        if cached and "cues" in cached and len(cached["cues"]) > 0:
            return cached["cues"]

    # 2. Carrega o áudio apenas quando necessário
    data, sr = sf.read(filepath)
    total_frames = len(data)
    total_seconds = total_frames / sr
    left = data[:, 0] if len(data.shape) > 1 else data
    right = data[:, 1] if len(data.shape) > 1 else data
    
    beats_per_bar = time_signature[0]
    sec_per_beat = 60.0 / bpm
    sec_per_bar = sec_per_beat * beats_per_bar
    total_beats = int(total_seconds / sec_per_beat)

    # Pico calibrado global do Canal R para normalização consistente de todas as seções
    step_r = max(1, len(right) // 2000)
    global_r_max = float(np.max(np.abs(right[::step_r])))
    if global_r_max < 0.01:
        global_r_max = float(np.max(np.abs(right)))
    if global_r_max < 0.01:
        global_r_max = 1.0

    # Se existia um cache versão anterior, apenas recalcula as formas de onda do Canal R com nova calibração
    if not force_reprocess and os.path.exists(cache_path):
        try:
            with open(cache_path, "r", encoding="utf-8") as f:
                old_cached = json.load(f)
                old_cues = old_cached.get("cues") if isinstance(old_cached, dict) else old_cached
                if isinstance(old_cues, list) and len(old_cues) > 0:
                    for i, cue in enumerate(old_cues):
                        end_t = old_cues[i+1]["time"] if i+1 < len(old_cues) else total_seconds
                        cue["waveform"] = compute_real_waveform_peaks(data, sr, cue["time"], end_t, n_peaks=64, global_r_max=global_r_max)
                    
                    # Atualiza o cache para versão 6 com gravação atômica
                    try:
                        from app.song_library import atomic_save_json
                        payload = {
                            "version": 6,
                            "channel": "R",
                            "bpm": bpm,
                            "time_signature": f"{beats_per_bar}/{time_signature[1]}",
                            "cues": old_cues
                        }
                        atomic_save_json(cache_path, payload, backup=True)
                    except Exception:
                        pass
                    return old_cues
        except Exception:
            pass

    # 2. Calcula RMS do Click e da Guia Falada (Janela móvel de ~120ms para capturar voz contínua)
    beat_rms = []
    for b in range(total_beats):
        start = int(b * sec_per_beat * sr)
        end = int((b + 1) * sec_per_beat * sr)
        chunk = left[start:end]
        rms = np.sqrt(np.mean(chunk**2)) if len(chunk) > 0 else 0.0
        beat_rms.append(rms)

    beat_rms = np.array(beat_rms)
    baseline = np.median(beat_rms) if len(beat_rms) > 0 else 0.05
    if baseline <= 1e-5:
        baseline = np.mean(beat_rms) if len(beat_rms) > 0 else 0.05

    # 3. Encontra tempos onde a voz da guia fala
    voice_beats = []
    threshold = baseline * 1.65
    for b, rms in enumerate(beat_rms):
        if rms > threshold:
            time_sec = b * sec_per_beat
            bar = int(b / beats_per_bar) + 1
            beat_in_bar = (b % beats_per_bar) + 1
            voice_beats.append((b, time_sec, bar, beat_in_bar))

    # 4. Agrupa rajadas de fala da voz guia
    bursts = []
    current_burst = []
    for vb in voice_beats:
        if not current_burst or vb[0] <= current_burst[-1][0] + 3:
            current_burst.append(vb)
        else:
            bursts.append(current_burst)
            current_burst = [vb]
    if current_burst:
        bursts.append(current_burst)

    # 5. Determina a duração da contagem inicial (Count-In) e o início da Intro musical
    b1_rms = np.sqrt(np.mean(right[0:int(sec_per_bar * sr)]**2)) if len(right) > 0 else 0.0
    b2_rms = np.sqrt(np.mean(right[int(sec_per_bar * sr):int(sec_per_bar * 2 * sr)]**2)) if len(right) > int(sec_per_bar * sr) else 0.0
    
    # Se o compasso 2 ainda for silencioso no canal VS, o Count-In dura 2 compassos; senão, dura 1 compasso
    count_in_bars = 2 if b2_rms < 0.0005 else 1
    intro_bar = count_in_bars + 1
    intro_time = round((intro_bar - 1) * sec_per_bar, 2)

    cues = []
    # 1. Seção de Pré-Contagem (Count-In)
    cues.append({
        "id": "cue_0",
        "name": "Count-In",
        "time": 0.0,
        "bar": 1,
        "color": "#64748b" # Slate / Chumbo
    })
    # 2. Seção de Introdução Musical Real
    cues.append({
        "id": "cue_1",
        "name": "Intro",
        "time": intro_time,
        "bar": intro_bar,
        "color": "#38bdf8" # Ciano
    })

    last_cue_time = intro_time
    min_section_duration = sec_per_bar * 3

    candidate_bars = []
    for burst in bursts:
        burst_end_bar = burst[-1][2]
        target_bar = burst_end_bar + 1
        target_time = (target_bar - 1) * sec_per_bar
        
        # Ignora tempos que caem dentro do Count-In ou muito no início da Intro
        if target_bar <= intro_bar + 2:
            continue
            
        if target_time - last_cue_time >= min_section_duration and target_time < total_seconds - sec_per_bar:
            burst_start_time = burst[0][1]
            burst_end_time = burst[-1][1] + sec_per_beat
            candidate_bars.append((target_bar, target_time, burst_start_time, burst_end_time))
            last_cue_time = target_time

    if len(candidate_bars) == 0:
        cues = default_cues(total_seconds, bpm, sec_per_bar)
    else:
        # 6. Análise de Energia Musical do Canal VS para Classificar Seções
        # Calcula energia RMS de cada seção no canal R (mix de instrumentos)
        all_section_energies = []
        boundaries = [0.0, intro_time] + [cb[1] for cb in candidate_bars] + [total_seconds]
        for idx in range(len(boundaries) - 1):
            s_f = int(boundaries[idx] * sr)
            e_f = int(boundaries[idx + 1] * sr)
            chunk_vs = right[s_f:e_f]
            rms_vs = np.sqrt(np.mean(chunk_vs**2)) if len(chunk_vs) > 0 else 0.0
            all_section_energies.append(rms_vs)

        med_energy = np.median(all_section_energies) if all_section_energies else 0.05
        
        verse_count = 1
        chorus_count = 0
        has_bridge = False
        
        for i, (target_bar, target_time, burst_start, burst_end) in enumerate(candidate_bars):
            sec_idx = i + 2  # 0 é Count-In, 1 é Intro
            sec_energy = all_section_energies[sec_idx] if sec_idx < len(all_section_energies) else med_energy
            is_last = (i == len(candidate_bars) - 1)
            
            # Reconhecimento inteligente da fala da voz guia (Português e Inglês)
            spoken = recognize_voice_burst(left, sr, burst_start, burst_end)
            
            if spoken:
                name = spoken
                color = color_for_name(name)
                if "Chorus" in name:
                    chorus_count += 1
                elif "Bridge" in name:
                    has_bridge = True
                elif "Verse" in name:
                    verse_count += 1
            elif is_last and target_time > total_seconds - (sec_per_bar * 8):
                name = "Ending"
                color = "#64748b"
            elif sec_energy > med_energy * 1.28:
                # Alta energia -> Refrão ou Solo
                if chorus_count >= 2 and not has_bridge and sec_idx > len(candidate_bars) * 0.5:
                    name = "Bridge"
                    color = "#f97316"
                    has_bridge = True
                else:
                    chorus_count += 1
                    name = "Chorus"
                    color = "#ef4444"
            elif sec_energy > med_energy * 1.05 and (i + 1 < len(candidate_bars)) and all_section_energies[sec_idx + 1] > med_energy * 1.25:
                # Energia subindo logo antes do refrão -> Pré-Refrão
                name = "Pre-Chorus"
                color = "#eab308"
            elif chorus_count >= 1 and not has_bridge and sec_idx > len(candidate_bars) * 0.55:
                name = "Bridge"
                color = "#f97316"
                has_bridge = True
            else:
                name = f"Verse {verse_count}"
                color = "#a855f7"
                verse_count += 1

            cues.append({
                "id": f"cue_{len(cues)}",
                "name": name,
                "time": round(target_time, 2),
                "bar": target_bar,
                "color": color
            })

    # 7. Calcula a forma de onda / espectrograma real de cada seção usando Canal R
    for i, cue in enumerate(cues):
        end_t = cues[i+1]["time"] if i+1 < len(cues) else total_seconds
        cue["waveform"] = compute_real_waveform_peaks(data, sr, cue["time"], end_t, n_peaks=64, global_r_max=global_r_max)

    # 8. Salva no cache com versão 5 (Canal R Calibrado sem platô)
    try:
        from app.song_library import atomic_save_json
        payload = {
            "version": 6,
            "channel": "R",
            "bpm": bpm,
            "time_signature": f"{beats_per_bar}/{time_signature[1]}",
            "cues": cues
        }
        atomic_save_json(cache_path, payload, backup=False)
    except Exception:
        pass

    return cues


def default_cues(total_seconds: float, bpm: float, sec_per_bar: float) -> list[dict]:
    """Cria seções padrão com separação de Count-In e Intro musical."""
    bars = int(total_seconds / sec_per_bar)
    sections = [
        ("Count-In", 1, "#64748b"),
        ("Intro", 3, "#38bdf8"),
        ("Verse 1", max(7, int(bars * 0.12)), "#a855f7"),
        ("Verse 2", max(13, int(bars * 0.25)), "#a855f7"),
        ("Chorus", max(21, int(bars * 0.40)), "#ef4444"),
        ("Instrumental", max(29, int(bars * 0.55)), "#10b981"),
        ("Bridge", max(37, int(bars * 0.70)), "#f97316"),
        ("Chorus", max(45, int(bars * 0.82)), "#ef4444"),
        ("Ending", max(51, int(bars * 0.92)), "#64748b"),
    ]
    cues = []
    for i, (name, bar, color) in enumerate(sections):
        time_sec = round((bar - 1) * sec_per_bar, 2)
        if time_sec < total_seconds - 5:
            cues.append({
                "id": f"cue_{i}",
                "name": name,
                "time": time_sec,
                "bar": bar,
                "color": color
            })
    return cues
