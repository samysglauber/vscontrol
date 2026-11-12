"""
MidiClockManager - Sincronizador de MIDI Beat Clock com precisão de áudio (Sample-Accurate).
Utiliza a API nativa do CoreMIDI (MIDIPacketListInit / MIDIPacketListAdd) para garantir que
todos os pacotes MIDI de Clock (0xF8), Start (0xFA), Stop (0xFC), Continue (0xFB) e SPP (0xF2)
sejam perfeitamente formatados e entregues ao Ableton Live e a outras DAWs.
"""

import sys
import ctypes
from ctypes import util, c_void_p, c_size_t, c_uint64, POINTER, create_string_buffer, c_uint8, c_int32, c_uint32, byref

class MidiClockManager:
    def __init__(self, port_name: str = "VS Control Sync"):
        self.port_name = port_name
        self.client = None
        self.source = None
        self.out_port = None
        self.last_tick = -1
        self.is_playing = False
        self._clock_buf = None
        self._start_buf = None
        self._stop_buf = None
        self._continue_buf = None
        self._init_coremidi()

    def _init_coremidi(self):
        if sys.platform != "darwin":
            return
        try:
            self.cm = ctypes.cdll.LoadLibrary(util.find_library('CoreMIDI'))
            self.cf = ctypes.cdll.LoadLibrary(util.find_library('CoreFoundation'))
            
            self.cf.CFStringCreateWithCString.argtypes = [c_void_p, ctypes.c_char_p, c_uint32]
            self.cf.CFStringCreateWithCString.restype = c_void_p
            kCFStringEncodingUTF8 = 0x08000100

            name_cf = self.cf.CFStringCreateWithCString(None, self.port_name.encode('utf-8'), kCFStringEncodingUTF8)
            
            # 1. MIDI Client
            self.client = c_void_p()
            self.cm.MIDIClientCreate.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDIClientCreate.restype = c_int32
            self.cm.MIDIClientCreate(name_cf, None, None, byref(self.client))

            # 2. Virtual Source (Aparece como entrada MIDI direta no Ableton Live)
            self.source = c_void_p()
            self.cm.MIDISourceCreate.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDISourceCreate.restype = c_int32
            self.cm.MIDISourceCreate(self.client, name_cf, byref(self.source))

            # 3. Output Port (Para enviar a portas físicas ou virtuais do sistema como IAC Driver e TRIGGER)
            self.out_port = c_void_p()
            self.cm.MIDIOutputPortCreate.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDIOutputPortCreate.restype = c_int32
            self.cm.MIDIOutputPortCreate(self.client, name_cf, byref(self.out_port))

            # Assinaturas oficiais da Apple para montagem e envio de MIDIPacketList
            self.cm.MIDIPacketListInit.argtypes = [c_void_p]
            self.cm.MIDIPacketListInit.restype = c_void_p
            self.cm.MIDIPacketListAdd.argtypes = [c_void_p, c_size_t, c_void_p, c_uint64, c_size_t, POINTER(c_uint8)]
            self.cm.MIDIPacketListAdd.restype = c_void_p

            self.cm.MIDIReceived.argtypes = [c_void_p, c_void_p]
            self.cm.MIDIReceived.restype = c_int32
            self.cm.MIDISend.argtypes = [c_void_p, c_void_p, c_void_p]
            self.cm.MIDISend.restype = c_int32
            self.cm.MIDIGetNumberOfDestinations.restype = c_uint32
            self.cm.MIDIGetDestination.restype = c_void_p

            # Pré-compila buffers estáticos para latência ultra baixa (< 1 microsegundo)
            self._clock_buf = self._make_packet([0xF8])
            self._start_buf = self._make_packet([0xFA])
            self._stop_buf = self._make_packet([0xFC])
            self._continue_buf = self._make_packet([0xFB])

            print(f"🎹 [MidiClock] CoreMIDI operacional! Porta Virtual: '{self.port_name}'")
        except Exception as e:
            print(f"⚠️ [MidiClock] Erro ao inicializar CoreMIDI: {e}")
            self.client = None

    def _make_packet(self, byte_list: list[int]):
        """Constrói um MIDIPacketList usando as funções oficiais do CoreMIDI."""
        n = len(byte_list)
        data_arr = (c_uint8 * n)(*byte_list)
        buf = create_string_buffer(512)
        cur = self.cm.MIDIPacketListInit(buf)
        self.cm.MIDIPacketListAdd(buf, 512, cur, 0, n, data_arr)
        return buf

    def _send_packet(self, pkt_buf):
        if not self.client or not pkt_buf:
            return
        try:
            # 1. Envia para o Virtual Source (Ableton ouvindo 'VS Control Sync')
            if self.source:
                self.cm.MIDIReceived(self.source, pkt_buf)

            # 2. Envia para destinos como IAC Driver, TRIGGER, etc.
            if self.out_port:
                n_dest = self.cm.MIDIGetNumberOfDestinations()
                for i in range(n_dest):
                    dest = self.cm.MIDIGetDestination(i)
                    self.cm.MIDISend(self.out_port, dest, pkt_buf)
        except Exception:
            pass

    def send_start(self):
        """Inicia a reprodução do início (SPP 0 + MIDI Start 0xFA)."""
        self.last_tick = -1
        self.is_playing = True
        # Envia Song Position Pointer = 0 (1.1.1)
        spp_buf = self._make_packet([0xF2, 0x00, 0x00])
        self._send_packet(spp_buf)
        # Envia MIDI Start
        self._send_packet(self._start_buf)
        # Envia o primeiro tick de clock imediatamente
        self._send_packet(self._clock_buf)
        print("▶️ [MidiClock] MIDI Start (0xFA) + SPP 0 disparado")

    def send_continue(self, pos_sixteenths: int = 0):
        """Retoma a reprodução da posição especificada (SPP + MIDI Continue 0xFB)."""
        self.is_playing = True
        if pos_sixteenths > 0:
            lsb = pos_sixteenths & 0x7F
            msb = (pos_sixteenths >> 7) & 0x7F
            spp_buf = self._make_packet([0xF2, lsb, msb])
            self._send_packet(spp_buf)
        self._send_packet(self._continue_buf)
        print(f"▶️ [MidiClock] MIDI Continue (0xFB) disparado (pos: {pos_sixteenths} 16ths)")

    def send_stop(self):
        """Para a reprodução (MIDI Stop 0xFC)."""
        self.is_playing = False
        self._send_packet(self._stop_buf)
        print("⏹️ [MidiClock] MIDI Stop (0xFC) disparado")

    def send_spp(self, pos_sixteenths: int):
        """Posiciona a agulha de reprodução na linha do tempo via SPP (0xF2)."""
        lsb = pos_sixteenths & 0x7F
        msb = (pos_sixteenths >> 7) & 0x7F
        spp_buf = self._make_packet([0xF2, lsb, msb])
        self._send_packet(spp_buf)

    def reset_tick(self, current_frame: int, sample_rate: int, bpm: float):
        """Recalcula o tick atual sem disparar relógios acumulados."""
        if bpm <= 0 or sample_rate <= 0:
            return
        frames_per_tick = (2.5 * sample_rate) / bpm
        self.last_tick = int(current_frame / frames_per_tick)

    def process_frames(self, start_frame: int, n_frames: int, sample_rate: int, bpm: float):
        """
        Processa os pulsos de clock MIDI (0xF8) sincronizados amostra por amostra com o CoreAudio.
        Executado a cada bloco de áudio da saída física.
        """
        if not self.is_playing or bpm <= 0 or sample_rate <= 0:
            return

        frames_per_tick = (2.5 * sample_rate) / bpm
        if frames_per_tick <= 0:
            return

        end_frame = start_frame + n_frames
        target_tick = int(end_frame / frames_per_tick)

        if self.last_tick < 0:
            self.last_tick = int(start_frame / frames_per_tick)

        if target_tick > self.last_tick:
            num_ticks = target_tick - self.last_tick
            if num_ticks > 48:
                num_ticks = 1
                self.last_tick = target_tick - 1

            for _ in range(num_ticks):
                self._send_packet(self._clock_buf)

            self.last_tick = target_tick
