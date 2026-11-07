"""
Gerenciador da Biblioteca de Canções (Songs / Setlists)
Varre o diretório /Users/samysglauber/Documents/Vs de forma inteligente e sob demanda.
"""

import os
import json
from app.cue_detector import extract_bpm_from_filename, detect_cues, detect_click_bpm_from_audio, compute_real_waveform_peaks
import soundfile as sf
import numpy as np

DEFAULT_VS_DIR = "/Users/samysglauber/Documents/Vs"
CONFIG_FILE = os.path.join(os.path.dirname(__file__), "tracks_config.json")

def get_saved_tracks_dir() -> str:
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                p = data.get("tracks_folder")
                if p and os.path.isdir(p):
                    return p
        except Exception as e:
            print(f"Erro ao ler tracks_config.json: {e}")
    return DEFAULT_VS_DIR

def save_tracks_dir(path: str):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump({"tracks_folder": path}, f, indent=2)
    except Exception as e:
        print(f"Erro ao salvar tracks_config.json: {e}")

def resample_cues_waveforms(filepath: str, cues: list[dict], audio_data: np.ndarray = None, sr: int = None) -> list[dict]:
    """
    Re-amostra as formas de onda reais do Canal R (instrumentos/VS) com precisão cirúrgica
    para cada seção, usando os tempos atuais (start_time e end_time de cada bloco).
    """
    if not cues or not filepath:
        return cues
    
    try:
        if audio_data is None or sr is None:
            if not os.path.exists(filepath):
                return cues
            audio_data, sr = sf.read(filepath)

        total_frames = len(audio_data)
        total_seconds = total_frames / sr

        # Extrai canal R para cálculo da normalização global consistente
        if audio_data.ndim > 1:
            right = audio_data[:, 1]
        else:
            right = audio_data

        step_r = max(1, len(right) // 2000)
        global_r_max = float(np.max(np.abs(right[::step_r])))
        if global_r_max < 0.01:
            global_r_max = float(np.max(np.abs(right)))
        if global_r_max < 0.01:
            global_r_max = 1.0

        for i in range(len(cues)):
            start_t = max(0.0, float(cues[i].get("time", 0.0)))
            end_t = float(cues[i + 1]["time"]) if (i + 1 < len(cues) and "time" in cues[i + 1]) else total_seconds
            if end_t <= start_t:
                end_t = start_t + 1.0
            
            cues[i]["waveform"] = compute_real_waveform_peaks(
                audio_data, sr, start_t, end_t, n_peaks=64, global_r_max=global_r_max
            )
    except Exception as e:
        print(f"Erro ao reamostrar waveforms: {e}")

    return cues


class SongLibrary:
    def __init__(self, directory: str | None = None):
        self.directory = directory or get_saved_tracks_dir()
        self._songs_cache = {}  # id -> song dict
        self._all_songs = None

    def set_directory(self, new_dir: str) -> bool:
        """Define e persiste um novo diretório de tracks e atualiza a biblioteca."""
        if not new_dir:
            return False
        self.directory = os.path.abspath(new_dir)
        save_tracks_dir(self.directory)
        self.refresh()
        return True

    @property
    def songs(self):
        """Retorna todas as músicas (ou realiza varredura sob demanda)."""
        return self.get_all_songs()

    def _index_file(self, entry: str) -> dict | None:
        """Indexa um arquivo específico instantaneamente sem ler áudio."""
        if entry in self._songs_cache:
            return self._songs_cache[entry]

        supported_exts = (".wav", ".mp3", ".m4a", ".aif", ".aiff")
        lower = entry.lower()
        if not any(lower.endswith(ext) for ext in supported_exts) or entry.endswith(".asd"):
            return None

        full_path = os.path.join(self.directory, entry)
        if not os.path.exists(full_path):
            return None

        bpm = extract_bpm_from_filename(entry)
        
        # Nome amigável limpo
        clean_name = entry
        for ext in supported_exts:
            if clean_name.lower().endswith(ext):
                clean_name = clean_name[:-len(ext)]
                break
        clean_name = clean_name.replace(" - vs", "").replace("- vs", "").strip()

        has_cached_cues = os.path.exists(full_path + ".cues.json")
        time_sig = "4/4"
        if has_cached_cues:
            try:
                with open(full_path + ".cues.json", "r", encoding="utf-8") as f:
                    cdata = json.load(f)
                    if isinstance(cdata, dict):
                        if cdata.get("bpm"):
                            bpm = cdata["bpm"]
                        if cdata.get("time_signature"):
                            time_sig = cdata["time_signature"]
            except Exception:
                pass

        item = {
            "id": entry,
            "filename": entry,
            "name": clean_name,
            "path": full_path,
            "bpm": bpm,
            "time_signature": time_sig,
            "has_cached_cues": has_cached_cues,
            "default_key": "D"
        }
        self._songs_cache[entry] = item
        return item

    def load_setlist_songs(self, song_ids: list[str]) -> list[dict]:
        """Carrega e indexa apenas as músicas necessárias para a Setlist (ultra rápido)."""
        result = []
        for sid in song_ids:
            s = self._index_file(sid)
            if s:
                result.append(s)
        return result

    def get_all_songs(self) -> list[dict]:
        """Varre o diretório completo sob demanda (quando o usuário abre o Add Song)."""
        if self._all_songs is not None:
            return self._all_songs
        
        self.refresh()
        return self._all_songs or []

    def refresh(self):
        """Varre o diretório completo e indexa todas as faixas disponíveis."""
        songs_list = []
        self._songs_cache.clear()
        if not os.path.exists(self.directory):
            self._all_songs = []
            return

        supported_exts = (".wav", ".mp3", ".m4a", ".aif", ".aiff")
        try:
            entries = sorted(os.listdir(self.directory))
        except Exception as e:
            print(f"Erro ao ler diretório de tracks ({self.directory}): {e}")
            self._all_songs = []
            return

        for entry in entries:
            lower = entry.lower()
            if any(lower.endswith(ext) for ext in supported_exts) and not entry.endswith(".asd"):
                item = self._index_file(entry)
                if item:
                    songs_list.append(item)
                    
        self._all_songs = songs_list

    def get_song(self, song_id: str) -> dict | None:
        """Retorna os dados completos de uma música com suas Cues analisadas."""
        s = self._index_file(song_id)
        if not s:
            return None

        # Carrega cues direto do cache JSON se existir
        cache_path = s["path"] + ".cues.json"
        if os.path.exists(cache_path):
            try:
                with open(cache_path, "r", encoding="utf-8") as f:
                    saved = json.load(f)
                    if isinstance(saved, dict) and "cues" in saved and len(saved["cues"]) > 0:
                        if saved.get("bpm"):
                            s["bpm"] = saved["bpm"]
                        if saved.get("time_signature"):
                            s["time_signature"] = saved["time_signature"]
                        s["cues"] = saved["cues"]
                        return s
            except Exception:
                pass

        bpm = s.get("bpm")
        if bpm is None:
            bpm = detect_click_bpm_from_audio(s["path"])
            s["bpm"] = bpm
        
        ts_str = s.get("time_signature", "4/4")
        ts_parts = ts_str.split("/")
        ts = (int(ts_parts[0]), int(ts_parts[1])) if len(ts_parts) == 2 else (4, 4)
        
        cues = detect_cues(s["path"], bpm, time_signature=ts)
        s["cues"] = cues
        s["time_signature"] = f"{ts[0]}/{ts[1]}"
        return s

    def save_cues(self, song_id: str, cues: list[dict], bpm: float = None, time_signature: str = None, audio_data: np.ndarray = None, sr: int = None) -> bool:
        """Salva as alterações manuais do usuário (Cues, BPM, Compasso) e re-amostra o áudio em tempo real."""
        s = self.get_song(song_id)
        if s:
            if bpm is not None:
                s["bpm"] = bpm
            if time_signature:
                s["time_signature"] = time_signature

            # 1. Re-amostragem em tempo real do Canal R para as novas coordenadas de cada bloco
            cues = resample_cues_waveforms(s["path"], cues, audio_data=audio_data, sr=sr)
            s["cues"] = cues

            # 2. Persistência em cache (.cues.json)
            cache_path = s["path"] + ".cues.json"
            payload = {
                "version": 5,
                "channel": "R",
                "bpm": s.get("bpm"),
                "time_signature": s.get("time_signature", "4/4"),
                "cues": cues
            }
            with open(cache_path, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=2, ensure_ascii=False)
            return True
        return False

    def reprocess_song(self, song_id: str, bpm: float = None, time_signature: str = None) -> dict | None:
        """Re-analisa o áudio com IA e DSP profundo para redefinir as cues e dinâmica."""
        s = self.get_song(song_id)
        if s:
            if bpm is not None:
                s["bpm"] = bpm
            if time_signature:
                s["time_signature"] = time_signature
            
            current_bpm = s.get("bpm") or detect_click_bpm_from_audio(s["path"])
            s["bpm"] = current_bpm
            
            ts_str = s.get("time_signature", "4/4")
            ts_parts = ts_str.split("/")
            ts = (int(ts_parts[0]), int(ts_parts[1])) if len(ts_parts) == 2 else (4, 4)
            
            cues = detect_cues(s["path"], current_bpm, time_signature=ts, force_reprocess=True)
            s["cues"] = cues
            s["time_signature"] = f"{ts[0]}/{ts[1]}"
            return s
        return None
