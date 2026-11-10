"""
Motor de Áudio em Tempo Real para Reprodução de VS e Click
Execução de alta fidelidade e latência zero via sounddevice (CoreAudio no Mac).
Endereçamento:
  - Canal L (Saída 1): CLICK + GUIA (vai para canal CLICK do Ableton)
  - Canal R (Saída 2): VS INSTRUMENTOS (vai para canal VS do Ableton)
Recursos:
  - Salto quantizado de seções (Seamless Jump no próximo compasso)
  - Loop infinito de seção
  - Pad contínuo de ambiência (12 tons)
  - Controle independente de volume, mute e solo
"""

import os
import json
import time
import threading
import sounddevice as sd
import soundfile as sf
import numpy as np
from app.pad_generator import AmbientPadGenerator

class LiveAudioEngine:
    def __init__(self):
        self.stream = None
        self.lock = threading.Lock()
        
        # Estado do áudio
        self.audio_data = None      # np.ndarray shape (N, 2)
        self.filepath = None
        self.sample_rate = 44100
        self.total_frames = 0
        self.pos_frame = 0
        self.is_playing = False
        
        # Métricas musicais
        self.bpm = 120.0
        self.time_signature = (4, 4)
        self.cues = []
        self.current_cue_idx = 0
        self.queued_cue_idx = None
        self.queued_jump = None
        self.guide_lead_in = None   # Lead-in exclusivo do Canal L (Click + Guia)
        self.guide_lead_in_bars = 1.0 # 1.0 compasso de preparação para ouvir a voz guia do trecho escolhido
        self.loop_active = False
        self.loop_cue_idx = None
        
        # Crossfade rápido nas trocas de seção (30ms para evitar cortes bruscos e cliques)
        self.xfade_tail = None
        self.xfade_in_pos = 0
        self.xfade_in_total = 0
        self.xfade_duration_sec = 0.030 # 30ms

        # Fade Stop & Tracks Fade (Fade Out / Fade In suave sem pausar a música e mantendo o Click)
        self.fade_stop_active = False
        self.tracks_fade_gain = 1.0  # 1.0 = normal, 0.0 = totalmente atenuado
        self.tracks_fade_state = "normal"  # "normal", "fading_out", "faded_out", "fading_in"
        self.tracks_fade_frames_left = 0
        self.tracks_fade_total_frames = 0
        self.tracks_fade_start_gain = 1.0
        self.tracks_fade_target_gain = 0.0

        # Volumes e Controles
        self.click_vol = 1.0        # Canal L
        self.vs_vol = 1.0           # Canal R
        self.click_mute = False
        self.vs_mute = False
        
        # Pad Contínuo
        self.pad_gen = AmbientPadGenerator(sample_rate=self.sample_rate)
        self.pad_active = False
        self.pad_key = "D"
        self.pad_vol = 0.35
        self.pad_buffer = None
        self.pad_pos = 0
        
        # Dispositivo de Saída (carrega preferência salva ou prioriza BlackHole)
        self.output_device = None
        config_path = os.path.join(os.path.dirname(__file__), "device_config.json")
        saved_name = None
        if os.path.exists(config_path):
            try:
                with open(config_path, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
                    saved_name = cfg.get("output_device_name")
            except Exception:
                pass

        try:
            devices = sd.query_devices()
            # 1. Tenta restaurar dispositivo pelo nome salvo
            if saved_name:
                for i, d in enumerate(devices):
                    if d.get("max_output_channels", 0) > 0 and d["name"] == saved_name:
                        self.output_device = i
                        break
            
            # 2. Se não encontrou salvo, tenta BlackHole
            if self.output_device is None:
                for i, d in enumerate(devices):
                    if d.get("max_output_channels", 0) > 0 and "blackhole" in d["name"].lower():
                        self.output_device = i
                        break
        except Exception:
            pass
        
        # Callback de notificação de eventos (WebSockets)
        self.event_listener = None

    def get_output_devices(self) -> list[dict]:
        """Lista os dispositivos de saída disponíveis no macOS."""
        devices = sd.query_devices()
        out_devs = []
        for i, d in enumerate(devices):
            if d.get("max_output_channels", 0) > 0:
                is_blackhole = "blackhole" in d["name"].lower()
                out_devs.append({
                    "id": i,
                    "name": d["name"],
                    "channels": d["max_output_channels"],
                    "is_default": i == sd.default.device[1],
                    "is_blackhole": is_blackhole
                })
        return out_devs

    def set_output_device(self, device_id: int):
        """Troca o dispositivo de saída e salva a preferência em arquivo para persistência."""
        with self.lock:
            try:
                devices = sd.query_devices()
                if 0 <= device_id < len(devices) and devices[device_id].get("max_output_channels", 0) > 0:
                    was_playing = self.is_playing
                    self._stop_stream()
                    self.output_device = device_id
                    dev_name = devices[device_id].get("name", "")
                    config_path = os.path.join(os.path.dirname(__file__), "device_config.json")
                    with open(config_path, "w", encoding="utf-8") as f:
                        json.dump({"output_device_id": device_id, "output_device_name": dev_name}, f, indent=2)
                    if was_playing:
                        self._start_stream()
                    return True
                else:
                    print(f"Dispositivo {device_id} inválido para saída de áudio.")
                    return False
            except Exception as e:
                print(f"Erro ao configurar dispositivo {device_id}: {e}")
                return False

    def load_song(self, filepath: str, bpm: float, cues: list[dict], time_signature: tuple[int, int] = (4, 4)):
        """Carrega uma música na memória e prepara o grid de compassos."""
        with self.lock:
            self.is_playing = False
            self._stop_stream()
            self.filepath = filepath
            
            raw_data, sr = sf.read(filepath)
            self.sample_rate = sr
            
            # Garante que os dados estejam em float32 estéreo
            if len(raw_data.shape) == 1:
                # Se for mono, duplica em L e R
                self.audio_data = np.column_stack((raw_data, raw_data)).astype(np.float32)
            else:
                self.audio_data = raw_data[:, :2].astype(np.float32)
                
            self.total_frames = len(self.audio_data)
            self.pos_frame = 0
            self.bpm = bpm if bpm and bpm > 30 else 120.0
            self.time_signature = time_signature
            self.cues = cues or []
            self.current_cue_idx = 0
            self.queued_cue_idx = None
            self.queued_jump = None
            self.guide_lead_in = None
            self.loop_active = False
            self.loop_cue_idx = None
            self.xfade_tail = None
            self.fade_stop_active = False
            self.tracks_fade_gain = 1.0
            self.tracks_fade_state = "normal"
            self.tracks_fade_frames_left = 0
            
            # Prepara buffer do Pad na tonalidade
            self.pad_buffer = self.pad_gen.get_pad_chunk(self.pad_key, duration_sec=10.0)
            self.pad_pos = 0

    def play(self):
        """Inicia a reprodução."""
        with self.lock:
            if self.audio_data is None:
                return
            self.fade_stop_active = False
            self.tracks_fade_gain = 1.0
            self.tracks_fade_state = "normal"
            self.tracks_fade_frames_left = 0
            if not self.is_playing:
                self.is_playing = True
                self._start_stream()
        self._notify_event("play_state", {"is_playing": True})

    def pause(self):
        """Pausa a reprodução mantendo a posição."""
        with self.lock:
            self.is_playing = False
            self.fade_stop_active = False
            self.tracks_fade_gain = 1.0
            self.tracks_fade_state = "normal"
            self.tracks_fade_frames_left = 0
            self.xfade_tail = None
            self.queued_cue_idx = None
            self.queued_jump = None
            self.guide_lead_in = None
            self._stop_stream()
        self._notify_event("play_state", {"is_playing": False})
        self._notify_event("cue_queued", {"queued_cue_idx": None})

    def stop(self):
        """Para e volta ao início."""
        with self.lock:
            self.is_playing = False
            self.pos_frame = 0
            self.current_cue_idx = 0
            self.queued_cue_idx = None
            self.queued_jump = None
            self.guide_lead_in = None
            self.xfade_tail = None
            self.fade_stop_active = False
            self.tracks_fade_gain = 1.0
            self.tracks_fade_state = "normal"
            self.tracks_fade_frames_left = 0
            self._stop_stream()
        self._notify_event("play_state", {"is_playing": False, "pos_frame": 0})
        self._notify_event("cue_queued", {"queued_cue_idx": None})

    def fade_tracks(self, direction: str = "toggle", duration_sec: float = 3.0):
        """Alterna ou define Fade Out / Fade In dos VS Tracks, mantendo o Click e o playback ativos."""
        with self.lock:
            if not self.is_playing:
                return
            tot = int(max(0.5, float(duration_sec)) * self.sample_rate)
            self.tracks_fade_total_frames = tot
            self.tracks_fade_frames_left = tot
            self.tracks_fade_start_gain = self.tracks_fade_gain
            
            if direction == "in":
                self.tracks_fade_target_gain = 1.0
                self.tracks_fade_state = "fading_in"
            elif direction == "out":
                self.tracks_fade_target_gain = 0.0
                self.tracks_fade_state = "fading_out"
            else: # toggle
                if self.tracks_fade_gain < 0.5 or self.tracks_fade_state in ["faded_out", "fading_out"]:
                    self.tracks_fade_target_gain = 1.0
                    self.tracks_fade_state = "fading_in"
                else:
                    self.tracks_fade_target_gain = 0.0
                    self.tracks_fade_state = "fading_out"
            
            self.fade_stop_active = (self.tracks_fade_state != "normal")
                
        self._notify_event("fade_tracks_started", {
            "state": self.tracks_fade_state,
            "target_gain": self.tracks_fade_target_gain,
            "duration_sec": duration_sec
        })

    def fade_stop(self, duration_sec: float = 3.0):
        """Compatibilidade para fade_stop: agora alterna Fade Out / Fade In das tracks mantendo o playback."""
        self.fade_tracks(direction="toggle", duration_sec=duration_sec)

    def seek_seconds(self, seconds: float):
        """Posiciona a reprodução no segundo especificado."""
        with self.lock:
            self.pos_frame = max(0, min(int(seconds * self.sample_rate), self.total_frames - 1))
            self.queued_cue_idx = None
            self.queued_jump = None
            self.guide_lead_in = None
            self.xfade_tail = None
            self.fade_stop_active = False
            self.tracks_fade_gain = 1.0
            self.tracks_fade_state = "normal"
            self.tracks_fade_frames_left = 0
            self._update_current_cue_idx()
        self._notify_event("seek", {"pos_frame": self.pos_frame, "seconds": seconds})
        self._notify_event("cue_queued", {"queued_cue_idx": None})

    def get_sec_per_bar(self) -> float:
        """Calcula a duração em segundos de 1 compasso inteiro."""
        bpm = self.bpm if self.bpm and self.bpm > 20 else 120.0
        beats_per_bar = 4.0
        try:
            if isinstance(self.time_signature, (tuple, list)):
                beats_per_bar = float(self.time_signature[0])
            elif isinstance(self.time_signature, str):
                beats_per_bar = float(self.time_signature.split("/")[0])
        except Exception:
            beats_per_bar = 4.0
        return (60.0 / bpm) * beats_per_bar

    def set_guide_lead_in(self, bars: float):
        """Define quantos compassos de antecedência tocar a voz guia na troca de seção."""
        with self.lock:
            self.guide_lead_in_bars = max(0.0, min(4.0, float(bars)))
        self._notify_event("guide_lead_in_state", {"guide_lead_in_bars": self.guide_lead_in_bars})

    def trigger_cue(self, cue_index: int, quantize: bool = True):
        """
        Dispara o salto para uma seção.
        Se quantize=True, aguarda o trecho atual em reprodução alcançar o compasso de transição.
        No compasso de preparação, apenas o Canal L (Click + Guia) toca a chamada do trecho escolhido,
        enquanto o Canal R (VS / Instrumental) continua tocando normalmente o trecho atual até o tempo 1!
        """
        with self.lock:
            if not (0 <= cue_index < len(self.cues)):
                return
                
            target_cue = self.cues[cue_index]
            target_time = target_cue["time"]
            target_frame = int(target_time * self.sample_rate)
            
            if not self.is_playing or not quantize:
                # Salto imediato (quando pausado ou sem quantização)
                self.pos_frame = target_frame
                self.current_cue_idx = cue_index
                self.queued_cue_idx = None
                self.queued_jump = None
                self.guide_lead_in = None
                self._notify_event("cue_jumped", {"current_cue_idx": cue_index})
                self._notify_event("cue_queued", {"queued_cue_idx": None})
                return

            # Se o usuário clicar novamente na mesma seção já enfileirada, cancela o salto agendado
            if self.queued_cue_idx == cue_index:
                self.queued_cue_idx = None
                self.queued_jump = None
                self.guide_lead_in = None
                self._notify_event("cue_queued", {"queued_cue_idx": None})
                return

            # Localiza com precisão o trecho em reprodução atual
            curr_sec = self.pos_frame / self.sample_rate
            active_idx = self.current_cue_idx
            for i in range(len(self.cues) - 1, -1, -1):
                if curr_sec >= self.cues[i]["time"] - 0.15:
                    active_idx = i
                    break

            # Se o usuário clicar na seção atualmente em reprodução:
            # NÃO agenda repetição/loop. O loop só deve ser ativado pelos botões dedicados de loop (toggle_loop).
            # Se houver algum salto para outra seção enfileirado, cancela o salto para continuar tocando naturalmente.
            if cue_index == active_idx or cue_index == self.current_cue_idx:
                if self.queued_cue_idx is not None or self.queued_jump is not None or self.guide_lead_in is not None:
                    self.queued_cue_idx = None
                    self.queued_jump = None
                    self.guide_lead_in = None
                    self._notify_event("cue_queued", {"queued_cue_idx": None})
                return

            # Fim do trecho atual: início do próximo trecho ou fim total da música
            if active_idx + 1 < len(self.cues):
                end_sec = self.cues[active_idx + 1]["time"]
            else:
                end_sec = self.total_frames / self.sample_rate

            sec_per_bar = self.get_sec_per_bar()
            lead_in_bars = self.guide_lead_in_bars if self.guide_lead_in_bars > 0 else 0.0

            # Se a seção escolhida for a próxima natural na timeline (active_idx + 1),
            # a gravação original já conduz perfeitamente com a guia no canal L.
            # Se for qualquer outro salto, usamos o lead-in exclusivo no Canal L!
            if cue_index == active_idx + 1:
                lead_in_sec = 0.0
            else:
                max_avail = max(0.0, target_time)
                desired_lead_in = min(lead_in_bars * sec_per_bar, max_avail)
                active_start = self.cues[active_idx]["time"]
                active_duration = max(0.0, end_sec - active_start)
                lead_in_sec = min(desired_lead_in, active_duration * 0.5) if active_duration > 0 else 0.0

            transition_sec = end_sec - lead_in_sec
            to_sec = target_time - lead_in_sec

            time_left = end_sec - curr_sec
            if time_left <= 0.25:
                # Muito perto do final (<250ms): salta direto no tempo 1
                self.pos_frame = target_frame
                self.current_cue_idx = cue_index
                self.queued_cue_idx = None
                self.queued_jump = None
                self.guide_lead_in = None
                self._notify_event("cue_jumped", {"current_cue_idx": cue_index})
                self._notify_event("cue_queued", {"queued_cue_idx": None})
                return
            elif curr_sec >= transition_sec and lead_in_sec > 0.0:
                # Já estamos no compasso final: ativa a voz guia no Canal L imediatamente
                # enquanto o Canal R continua tocando normalmente o trecho atual!
                lead_in_start = target_frame - int(time_left * self.sample_rate)
                if lead_in_start >= 0:
                    self.guide_lead_in = {
                        "pos_frame": lead_in_start,
                        "end_frame": target_frame,
                        "target_downbeat_frame": target_frame,
                        "cue_idx": cue_index,
                        "is_loop": False
                    }
                    self.queued_cue_idx = cue_index
                    self.queued_jump = None
                    self._notify_event("cue_queued", {"queued_cue_idx": cue_index})
                    return

            self.queued_cue_idx = cue_index
            self.guide_lead_in = None
            self.queued_jump = {
                "lead_in_at_frame": int(transition_sec * self.sample_rate),
                "lead_in_start_frame": int(to_sec * self.sample_rate),
                "target_downbeat_frame": target_frame,
                "end_frame": int(end_sec * self.sample_rate),
                "cue_idx": cue_index
            }
            
        self._notify_event("cue_queued", {"queued_cue_idx": cue_index})

    def toggle_loop(self, cue_idx: int | None = None) -> bool:
        """Ativa/desativa a repetição infinita da seção especificada ou atual."""
        with self.lock:
            if cue_idx is not None:
                if self.loop_active and self.loop_cue_idx == cue_idx:
                    self.loop_active = False
                    self.loop_cue_idx = None
                else:
                    self.loop_active = True
                    self.loop_cue_idx = cue_idx
            else:
                self.loop_active = not self.loop_active
                self.loop_cue_idx = self.current_cue_idx if self.loop_active else None
            
            # Se desativou o loop ou alterou a seção de loop, cancela lead-in de repetição anterior
            if self.guide_lead_in and self.guide_lead_in.get("is_loop"):
                if not self.loop_active or self.loop_cue_idx != self.guide_lead_in.get("cue_idx"):
                    self.guide_lead_in = None

            status = self.loop_active
            target_idx = self.loop_cue_idx
        self._notify_event("loop_state", {"loop_active": status, "loop_cue_idx": target_idx})
        return status

    def set_pad(self, active: bool, key: str | None = None, volume: float | None = None):
        """Liga/desliga ou altera o tom do Pad contínuo de sustentação."""
        with self.lock:
            self.pad_active = active
            if key:
                self.pad_key = key.upper()
                self.pad_buffer = self.pad_gen.get_pad_chunk(self.pad_key, duration_sec=10.0)
            if volume is not None:
                self.pad_vol = max(0.0, min(1.0, volume))
        self._notify_event("pad_state", {
            "pad_active": self.pad_active,
            "pad_key": self.pad_key,
            "pad_vol": self.pad_vol
        })

    def set_volumes(self, click_vol: float = None, vs_vol: float = None, click_mute: bool = None, vs_mute: bool = None):
        """Ajusta os volumes independentes de Click e VS."""
        with self.lock:
            if click_vol is not None:
                self.click_vol = max(0.0, min(1.5, click_vol))
            if vs_vol is not None:
                self.vs_vol = max(0.0, min(1.5, vs_vol))
            if click_mute is not None:
                self.click_mute = click_mute
            if vs_mute is not None:
                self.vs_mute = vs_mute
        self._notify_event("volume_state", {
            "click_vol": self.click_vol,
            "vs_vol": self.vs_vol,
            "click_mute": self.click_mute,
            "vs_mute": self.vs_mute
        })

    def get_status(self) -> dict:
        """Retorna o estado completo da reprodução para o frontend."""
        with self.lock:
            current_sec = self.pos_frame / self.sample_rate if self.sample_rate else 0.0
            total_sec = self.total_frames / self.sample_rate if self.sample_rate else 0.0
            
            sec_per_beat = 60.0 / self.bpm if self.bpm > 0 else 0.5
            beats_per_bar = self.time_signature[0]
            current_beat = current_sec / sec_per_beat
            bar_number = int(current_beat / beats_per_bar) + 1
            beat_in_bar = int(current_beat % beats_per_bar) + 1

            return {
                "is_playing": self.is_playing,
                "current_seconds": round(current_sec, 2),
                "total_seconds": round(total_sec, 2),
                "pos_frame": self.pos_frame,
                "total_frames": self.total_frames,
                "bar": bar_number,
                "beat": beat_in_bar,
                "bpm": self.bpm,
                "time_signature": f"{self.time_signature[0]}/{self.time_signature[1]}",
                "current_cue_idx": self.current_cue_idx,
                "queued_cue_idx": self.queued_cue_idx,
                "loop_active": self.loop_active,
                "loop_cue_idx": self.loop_cue_idx,
                "guide_lead_in_bars": self.guide_lead_in_bars,
                "click_vol": self.click_vol,
                "vs_vol": self.vs_vol,
                "click_mute": self.click_mute,
                "vs_mute": self.vs_mute,
                "output_device_id": self.output_device,
                "fade_stop_active": self.tracks_fade_state != "normal",
                "tracks_fade_state": self.tracks_fade_state,
                "tracks_fade_gain": self.tracks_fade_gain,
                "is_faded_out": self.tracks_fade_state == "faded_out",
                "pad_active": self.pad_active,
                "pad_key": self.pad_key,
                "pad_vol": self.pad_vol,
                "cues": self.cues
            }

    # ==========================
    # Áudio Callback em Baixo Nível (CoreAudio)
    # ==========================

    def _schedule_crossfade(self, exit_pos: int):
        """Prepara um crossfade equal-power de 30ms da saída anterior com a nova entrada."""
        if self.sample_rate <= 0 or self.audio_data is None:
            return
        xfade_r = int(self.xfade_duration_sec * self.sample_rate) # ~1323 frames (30ms)
        xfade_l = int(0.005 * self.sample_rate)                   # ~220 frames (5ms)
        if xfade_r <= 0:
            return

        tail = self._read_slice(exit_pos, xfade_r).copy()
        
        # Canal R: Equal-power fade-out (cos)
        t_r = np.linspace(0.0, np.pi / 2, xfade_r, dtype=np.float32)
        tail[:, 1] *= np.cos(t_r)

        # Canal L: Fade-out rápido de 5ms para manter ataque nítido do click/guia
        if xfade_l > 0:
            t_l = np.linspace(0.0, np.pi / 2, xfade_l, dtype=np.float32)
            tail[:xfade_l, 0] *= np.cos(t_l)
            tail[xfade_l:, 0] = 0.0
        else:
            tail[:, 0] = 0.0

        if self.xfade_tail is not None and len(self.xfade_tail) > 0:
            min_len = min(len(self.xfade_tail), len(tail))
            tail[:min_len] += self.xfade_tail[:min_len]

        self.xfade_tail = tail
        self.xfade_in_pos = 0
        self.xfade_in_total = xfade_r

    def _apply_crossfade(self, chunk: np.ndarray) -> np.ndarray:
        """Aplica a curva de fade-in no novo áudio e soma o fade-out do áudio anterior."""
        if self.xfade_tail is None or len(self.xfade_tail) == 0 or len(chunk) == 0:
            return chunk
        n = min(len(chunk), len(self.xfade_tail))
        p0 = self.xfade_in_pos
        p1 = p0 + n
        tot = max(1, self.xfade_in_total)
        xfade_l = int(0.005 * self.sample_rate)

        # Canal R: Equal-power fade-in (sin)
        t_r = np.linspace(p0 / tot, p1 / tot, n, dtype=np.float32) * (np.pi / 2)
        w_in_r = np.sin(t_r)

        # Canal L: Fade-in rápido de 5ms
        w_in_l = np.ones(n, dtype=np.float32)
        for i in range(n):
            global_frame = p0 + i
            if global_frame < xfade_l:
                w_in_l[i] = np.sin((global_frame / max(1, xfade_l)) * (np.pi / 2))

        chunk_mod = chunk.copy()
        chunk_mod[:n, 0] = chunk_mod[:n, 0] * w_in_l + self.xfade_tail[:n, 0]
        chunk_mod[:n, 1] = chunk_mod[:n, 1] * w_in_r + self.xfade_tail[:n, 1]

        self.xfade_tail = self.xfade_tail[n:] if len(self.xfade_tail) > n else None
        self.xfade_in_pos = p1
        if self.xfade_tail is None:
            self.xfade_in_pos = 0
            self.xfade_in_total = 0

        return chunk_mod

    def _start_stream(self):
        self._stop_stream()
        
        # 1. Valida se o dispositivo atual existe e possui canais de saída
        target_device = self.output_device
        try:
            devs = sd.query_devices()
            if target_device is not None:
                if target_device < 0 or target_device >= len(devs) or devs[target_device].get("max_output_channels", 0) <= 0:
                    target_device = None
                    # Tenta encontrar pelo nome salvo
                    config_path = os.path.join(os.path.dirname(__file__), "device_config.json")
                    if os.path.exists(config_path):
                        with open(config_path, "r", encoding="utf-8") as f:
                            saved_name = json.load(f).get("output_device_name")
                            if saved_name:
                                for i, d in enumerate(devs):
                                    if d.get("max_output_channels", 0) > 0 and d["name"] == saved_name:
                                        target_device = i
                                        break
        except Exception as e:
            print(f"Erro ao consultar dispositivos de áudio: {e}")
            target_device = None

        # 2. Tenta abrir com o dispositivo alvo
        try:
            self.stream = sd.OutputStream(
                samplerate=self.sample_rate,
                channels=2,
                dtype='float32',
                device=target_device,
                callback=self._audio_callback,
                blocksize=512
            )
            self.stream.start()
            self.output_device = target_device
            return
        except Exception as e:
            print(f"Erro ao iniciar OutputStream com dispositivo {target_device}: {e}. Tentando fallback...")

        # 3. Fallback automático para o dispositivo de saída padrão do sistema
        try:
            self.stream = sd.OutputStream(
                samplerate=self.sample_rate,
                channels=2,
                dtype='float32',
                device=None,
                callback=self._audio_callback,
                blocksize=512
            )
            self.stream.start()
            default_out = sd.default.device[1] if sd.default.device[1] >= 0 else None
            self.output_device = default_out
            print(f"Áudio iniciado com sucesso usando dispositivo padrão do sistema (ID: {default_out})")
        except Exception as e2:
            print(f"Falha ao iniciar áudio no dispositivo padrão: {e2}")

    def _stop_stream(self):
        if self.stream:
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass
            self.stream = None

    def _audio_callback(self, outdata, frames, time_info, status):
        """Callback executado pela thread de tempo real do CoreAudio a cada ~11ms."""
        if not self.is_playing or self.audio_data is None:
            # Se a música estiver parada mas o Pad estiver ativo, gera apenas o Pad
            if self.pad_active and self.pad_buffer is not None:
                self._render_pad_only(outdata, frames)
            else:
                outdata.fill(0)
            return

        with self.lock:
            # 1. Ativação de salto agendado (se alcançou o ponto de transição)
            if self.queued_jump:
                lead_in_at = self.queued_jump["lead_in_at_frame"]
                if self.pos_frame + frames >= lead_in_at:
                    lead_in_start = self.queued_jump["lead_in_start_frame"]
                    target_downbeat = self.queued_jump["target_downbeat_frame"]
                    target_cue_idx = self.queued_jump["cue_idx"]

                    if lead_in_start < target_downbeat - 512:
                        # Ativa o lead-in exclusivo no Canal L (Click + Voz Guia)
                        # Canal R continua tocando normalmente o trecho atual até o tempo 1
                        frames_before = max(0, lead_in_at - self.pos_frame)
                        frames_after = frames - frames_before

                        l1 = self._read_slice(self.pos_frame, frames_before)[:, 0]
                        l2 = self._read_slice(lead_in_start, frames_after)[:, 0]
                        slice_l = np.concatenate((l1, l2)) if frames_before > 0 else l2

                        slice_r = self._read_slice(self.pos_frame, frames)[:, 1]

                        self.guide_lead_in = {
                            "pos_frame": lead_in_start + frames_after,
                            "end_frame": target_downbeat,
                            "target_downbeat_frame": target_downbeat,
                            "cue_idx": target_cue_idx,
                            "is_loop": False
                        }
                        self.pos_frame += frames
                        self.queued_jump = None

                        chunk = np.column_stack((slice_l, slice_r))
                        self._apply_volumes_and_pad(chunk, outdata, frames)
                        self._update_current_cue_idx()
                        return
                    else:
                        # Salto direto sem lead-in no tempo 1
                        frames_before = max(0, lead_in_at - self.pos_frame)
                        frames_after = frames - frames_before

                        out1 = self._read_slice(self.pos_frame, frames_before)
                        self._schedule_crossfade(lead_in_at)
                        out2 = self._read_slice(target_downbeat, frames_after)
                        out2 = self._apply_crossfade(out2)
                        self.pos_frame = target_downbeat + frames_after
                        self.current_cue_idx = target_cue_idx
                        self.queued_cue_idx = None
                        self.queued_jump = None
                        self._notify_event("cue_jumped", {"current_cue_idx": target_cue_idx})
                        self._notify_event("cue_queued", {"queued_cue_idx": None})

                        chunk = np.vstack((out1, out2)) if frames_before > 0 else out2
                        self._apply_volumes_and_pad(chunk, outdata, frames)
                        self._update_current_cue_idx()
                        return

            # 2. Processamento do Lead-In do Canal L (Voz Guia nos fones / Canal R no PA)
            if self.guide_lead_in:
                l_pos = self.guide_lead_in["pos_frame"]
                l_end = self.guide_lead_in["end_frame"]
                target_downbeat = self.guide_lead_in["target_downbeat_frame"]
                target_cue_idx = self.guide_lead_in["cue_idx"]

                if l_pos + frames >= l_end:
                    # Chegamos ao Tempo 1 (Downbeat): ambos os canais entram juntos no trecho alvo com crossfade suave!
                    frames_before = max(0, l_end - l_pos)
                    frames_after = frames - frames_before

                    l1 = self._read_slice(l_pos, frames_before)[:, 0]
                    l2 = self._read_slice(target_downbeat, frames_after)[:, 0]

                    r1 = self._read_slice(self.pos_frame, frames_before)[:, 1]
                    self._schedule_crossfade(self.pos_frame + frames_before)
                    r2 = self._read_slice(target_downbeat, frames_after)[:, 1]

                    if frames_after > 0:
                        after_stereo = np.column_stack((l2, r2))
                        after_stereo = self._apply_crossfade(after_stereo)
                        l2 = after_stereo[:, 0]
                        r2 = after_stereo[:, 1]

                    slice_l = np.concatenate((l1, l2)) if frames_before > 0 else l2
                    slice_r = np.concatenate((r1, r2)) if frames_before > 0 else r2

                    self.pos_frame = target_downbeat + frames_after
                    self.guide_lead_in = None
                    self.current_cue_idx = target_cue_idx
                    self.queued_cue_idx = None
                    self._notify_event("cue_jumped", {"current_cue_idx": target_cue_idx})
                    self._notify_event("cue_queued", {"queued_cue_idx": None})
                else:
                    # Continua tocando: Canal L lê voz guia, Canal R lê instrumental atual
                    slice_l = self._read_slice(l_pos, frames)[:, 0]
                    slice_r = self._read_slice(self.pos_frame, frames)[:, 1]
                    self.guide_lead_in["pos_frame"] += frames
                    self.pos_frame += frames

            # 3. Checa repetição infinita de seção (Loop Infinito) se não houver salto agendado
            elif self.loop_active:
                target_loop_idx = self.loop_cue_idx if self.loop_cue_idx is not None else self.current_cue_idx
                if 0 <= target_loop_idx < len(self.cues):
                    curr_cue = self.cues[target_loop_idx]
                    curr_start = int(curr_cue["time"] * self.sample_rate)
                    curr_end = int(self.cues[target_loop_idx + 1]["time"] * self.sample_rate) if target_loop_idx + 1 < len(self.cues) else self.total_frames
                    
                    # O loop SÓ é executado se a reprodução estiver efetivamente dentro desta seção!
                    # Se estiver tocando outra seção (anterior ou posterior), continua tocando normalmente sem saltar.
                    if curr_start <= self.pos_frame < curr_end:
                        sec_per_bar = self.get_sec_per_bar()
                        lead_in_bars = self.guide_lead_in_bars if self.guide_lead_in_bars > 0 else 0.0
                        lead_in_frames = int(min(lead_in_bars * sec_per_bar, curr_cue["time"]) * self.sample_rate)
                        loop_at_frame = curr_end - lead_in_frames

                        frames_left = max(0, curr_end - self.pos_frame)
                        eff_lead_in = min(lead_in_frames, frames_left)
                        eff_start = curr_start - eff_lead_in

                        if eff_lead_in > 512 and eff_start >= 0 and self.pos_frame + frames >= loop_at_frame:
                            frames_before = max(0, loop_at_frame - self.pos_frame)
                            frames_after = frames - frames_before

                            l1 = self._read_slice(self.pos_frame, frames_before)[:, 0]
                            l2 = self._read_slice(eff_start, frames_after)[:, 0]
                            slice_l = np.concatenate((l1, l2)) if frames_before > 0 else l2

                            slice_r = self._read_slice(self.pos_frame, frames)[:, 1]

                            self.guide_lead_in = {
                                "pos_frame": eff_start + frames_after,
                                "end_frame": curr_start,
                                "target_downbeat_frame": curr_start,
                                "cue_idx": target_loop_idx,
                                "is_loop": True
                            }
                            self.pos_frame += frames
                        elif self.pos_frame + frames >= curr_end:
                            # Repetição sem lead-in no final da seção com crossfade
                            frames_before = max(0, curr_end - self.pos_frame)
                            frames_after = frames - frames_before

                            out1 = self._read_slice(self.pos_frame, frames_before)
                            self._schedule_crossfade(curr_end)
                            out2 = self._read_slice(curr_start, frames_after)
                            out2 = self._apply_crossfade(out2)
                            self.pos_frame = curr_start + frames_after

                            chunk_stereo = np.vstack((out1, out2)) if frames_before > 0 else out2
                            slice_l = chunk_stereo[:, 0]
                            slice_r = chunk_stereo[:, 1]
                        else:
                            chunk_stereo = self._read_slice(self.pos_frame, frames)
                            chunk_stereo = self._apply_crossfade(chunk_stereo)
                            slice_l = chunk_stereo[:, 0]
                            slice_r = chunk_stereo[:, 1]
                            self.pos_frame += frames
                    else:
                        # Fora da seção em loop: toca normalmente a música no ponto atual
                        chunk_stereo = self._read_slice(self.pos_frame, frames)
                        chunk_stereo = self._apply_crossfade(chunk_stereo)
                        slice_l = chunk_stereo[:, 0]
                        slice_r = chunk_stereo[:, 1]
                        self.pos_frame += frames
                else:
                    chunk_stereo = self._read_slice(self.pos_frame, frames)
                    chunk_stereo = self._apply_crossfade(chunk_stereo)
                    slice_l = chunk_stereo[:, 0]
                    slice_r = chunk_stereo[:, 1]
                    self.pos_frame += frames

            # 4. Leitura normal (sem lead-in e sem loop iminente)
            else:
                chunk_stereo = self._read_slice(self.pos_frame, frames)
                chunk_stereo = self._apply_crossfade(chunk_stereo)
                slice_l = chunk_stereo[:, 0]
                slice_r = chunk_stereo[:, 1]
                self.pos_frame += frames

            # Fim da música
            if self.pos_frame >= self.total_frames:
                self.is_playing = False
                self.pos_frame = 0
                self.current_cue_idx = 0
                self.guide_lead_in = None
                self._notify_event("song_ended", {"song_path": self.filepath or ""})

            chunk = np.column_stack((slice_l, slice_r))
            self._apply_volumes_and_pad(chunk, outdata, frames)
            self._update_current_cue_idx()

    def _read_slice(self, start_frame: int, n_frames: int) -> np.ndarray:
        """Lê fatias do buffer garantindo preenchimento de zeros caso chegue ao fim."""
        if n_frames <= 0:
            return np.zeros((0, 2), dtype=np.float32)
        end_frame = start_frame + n_frames
        if start_frame >= self.total_frames:
            return np.zeros((n_frames, 2), dtype=np.float32)
        if end_frame > self.total_frames:
            avail = self.total_frames - start_frame
            slice_data = self.audio_data[start_frame:self.total_frames]
            pad_zeros = np.zeros((n_frames - avail, 2), dtype=np.float32)
            return np.vstack((slice_data, pad_zeros))
        return self.audio_data[start_frame:end_frame]

    def _apply_volumes_and_pad(self, chunk: np.ndarray, outdata: np.ndarray, frames: int):
        """Aplica ganhos nos canais L e R e soma o Pad contínuo."""
        # Canal L (Click + Guia) - MANTIDO TOTALMENTE AUDÍVEL
        l_mult = 0.0 if self.click_mute else self.click_vol
        outdata[:, 0] = chunk[:, 0] * l_mult
        
        # Canal R (VS Instrumentos / Tracks) - FADE SUAVE DAS TRACKS
        r_base = 0.0 if self.vs_mute else self.vs_vol
        
        if self.tracks_fade_frames_left > 0:
            n = min(frames, self.tracks_fade_frames_left)
            p_start = 1.0 - (self.tracks_fade_frames_left / max(1, self.tracks_fade_total_frames))
            self.tracks_fade_frames_left -= n
            p_end = 1.0 - (self.tracks_fade_frames_left / max(1, self.tracks_fade_total_frames))
            
            g_start = self.tracks_fade_start_gain + (self.tracks_fade_target_gain - self.tracks_fade_start_gain) * p_start
            g_end = self.tracks_fade_start_gain + (self.tracks_fade_target_gain - self.tracks_fade_start_gain) * p_end
            
            ramp = np.linspace(g_start, g_end, frames, dtype=np.float32)
            outdata[:, 1] = chunk[:, 1] * (r_base * ramp)
            
            self.tracks_fade_gain = float(g_end)
            if self.tracks_fade_frames_left <= 0:
                self.tracks_fade_gain = float(self.tracks_fade_target_gain)
                self.tracks_fade_state = "faded_out" if self.tracks_fade_gain < 0.01 else "normal"
                self.fade_stop_active = (self.tracks_fade_state == "faded_out")
                self._notify_event("fade_tracks_ended", {
                    "state": self.tracks_fade_state,
                    "gain": self.tracks_fade_gain
                })
        else:
            outdata[:, 1] = chunk[:, 1] * (r_base * self.tracks_fade_gain)

        # Adiciona o Pad no Canal R (Mix dos instrumentos/PA)
        if self.pad_active and self.pad_buffer is not None:
            buf_len = len(self.pad_buffer)
            pad_slice = np.zeros((frames, 2), dtype=np.float32)
            for i in range(frames):
                pad_slice[i] = self.pad_buffer[self.pad_pos]
                self.pad_pos = (self.pad_pos + 1) % buf_len
            outdata[:, 1] += pad_slice[:, 1] * self.pad_vol

    def _render_pad_only(self, outdata: np.ndarray, frames: int):
        """Toca apenas o Pad contínuo com a música parada."""
        buf_len = len(self.pad_buffer)
        for i in range(frames):
            outdata[i, 0] = 0.0
            outdata[i, 1] = self.pad_buffer[self.pad_pos, 1] * self.pad_vol
            self.pad_pos = (self.pad_pos + 1) % buf_len

    def _update_current_cue_idx(self):
        """Atualiza o índice da seção corrente com base no tempo de reprodução."""
        if not self.cues or self.guide_lead_in:
            return
        curr_sec = self.pos_frame / self.sample_rate
        for i in range(len(self.cues) - 1, -1, -1):
            if curr_sec >= self.cues[i]["time"] - 0.15:
                if self.current_cue_idx != i:
                    self.current_cue_idx = i
                break

    def _notify_event(self, event_type: str, data: dict):
        if self.event_listener:
            try:
                self.event_listener(event_type, data)
            except Exception:
                pass
