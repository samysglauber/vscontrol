"""
Módulo de Geração de Pads Contínuos de Ambiência
Gera drones quentes e suaves de sustentação em qualquer tom (12 tonalidades)
para transição fluida entre músicas ao vivo.
"""

import numpy as np

# Frequências fundamentais das 12 notas (Oitava 2 e 3)
NOTES_FREQ = {
    "C": 65.41,
    "C#": 69.30,
    "Db": 69.30,
    "D": 73.42,
    "D#": 77.78,
    "Eb": 77.78,
    "E": 82.41,
    "F": 87.31,
    "F#": 92.50,
    "Gb": 92.50,
    "G": 98.00,
    "G#": 103.83,
    "Ab": 103.83,
    "A": 110.00,
    "A#": 116.54,
    "Bb": 116.54,
    "B": 123.47
}

class AmbientPadGenerator:
    def __init__(self, sample_rate: int = 44100):
        self.sample_rate = sample_rate
        self.current_key = "D"
        self.is_active = False
        self.volume = 0.35
        self._buffer_cache = {}

    def get_pad_chunk(self, key: str, duration_sec: float = 10.0) -> np.ndarray:
        """Gera um loop contínuo e sem emendas de drone/pad na tonalidade informada."""
        key = key.upper()
        if key not in NOTES_FREQ:
            key = "D"
            
        if key in self._buffer_cache:
            return self._buffer_cache[key]
            
        base_f = NOTES_FREQ[key]
        sr = self.sample_rate
        n_samples = int(sr * duration_sec)
        t = np.linspace(0, duration_sec, n_samples, False)
        
        # Estrutura harmônica rica: Tônica + 5ª Justa + Oitava + 9ª (Acorde Sus2 de adoração)
        f_root_1 = base_f
        f_root_2 = base_f * 2.0
        f_fifth = base_f * 1.5
        f_ninth = base_f * 2.25
        f_oct3 = base_f * 4.0
        
        # Síntese aditiva suave com ligeiro detuning para calor analógico
        drone = (
            0.40 * np.sin(2 * np.pi * f_root_1 * t) +
            0.30 * np.sin(2 * np.pi * (f_root_2 + 0.15) * t) +
            0.25 * np.sin(2 * np.pi * (f_fifth - 0.12) * t) +
            0.15 * np.sin(2 * np.pi * (f_ninth + 0.20) * t) +
            0.08 * np.sin(2 * np.pi * f_oct3 * t)
        )
        
        # Modulação lenta de amplitude (LFO respiratório de 0.1 Hz)
        lfo = 0.85 + 0.15 * np.sin(2 * np.pi * 0.12 * t)
        drone *= lfo
        
        # Filtro passa-baixa simples (suavização)
        kernel = np.ones(15) / 15.0
        drone = np.convolve(drone, kernel, mode='same')
        
        # Fade in e fade out nas pontas para looping perfeito
        fade_len = int(sr * 0.5)
        fade_in = np.linspace(0, 1, fade_len)
        fade_out = np.linspace(1, 0, fade_len)
        
        # Aplica crossfade de borda
        drone[:fade_len] = drone[:fade_len] * fade_in + drone[-fade_len:] * fade_out
        
        # Normaliza e formata em estéreo
        drone = drone / (np.max(np.abs(drone)) + 1e-6)
        stereo_pad = np.column_stack((drone, drone)).astype(np.float32)
        
        self._buffer_cache[key] = stereo_pad
        return stereo_pad
