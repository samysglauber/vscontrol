"""
MidiClockManager - Sincronizador de MIDI Beat Clock com precisão de áudio (Sample-Accurate).
Cria a porta virtual 'VS Control Sync' e envia eventos MIDI Clock (0xF8), Start (0xFA),
Stop (0xFC), Continue (0xFB) e Song Position Pointer (0xF2) para Ableton Live e DAWs.
"""

import sys
import ctypes
from ctypes import util, c_void_p, c_char_p, c_int32, c_uint32, POINTER, byref, Structure, c_uint16, c_uint8, c_uint64

class MIDIPacket(Structure):
    _fields_ = [
        ('timeStamp', c_uint64),
        ('length', c_uint16),
        ('data', c_uint8 * 256)
    ]

class MIDIPacketList(Structure):
    _fields_ = [
        ('numPackets', c_uint32),
        ('packet', MIDIPacket * 1)
    ]

class MidiClockManager:
    def __init__(self, port_name: str = "VS Control Sync"):
        self.port_name = port_name
        self.client = None
        self.source = None
        self.out_port = None
        self.last_tick = -1
        self.is_playing = False
        self._init_coremidi()

    def _init_coremidi(self):
        if sys.platform != "darwin":
            return
        try:
            self.cm = ctypes.cdll.LoadLibrary(util.find_library('CoreMIDI'))
            self.cf = ctypes.cdll.LoadLibrary(util.find_library('CoreFoundation'))
            
            self.cf.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
            self.cf.CFStringCreateWithCString.restype = c_void_p
            kCFStringEncodingUTF8 = 0x08000100

            name_cf = self.cf.CFStringCreateWithCString(None, self.port_name.encode('utf-8'), kCFStringEncodingUTF8)
            
            # 1. MIDI Client
            self.client = c_void_p()
            self.cm.MIDIClientCreate.argtypes = [c_void_p, c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDIClientCreate.restype = c_int32
            self.cm.MIDIClientCreate(name_cf, None, None, byref(self.client))

            # 2. Virtual Source (aparece nas portas de entrada do Ableton Live)
            self.source = c_void_p()
            self.cm.MIDISourceCreate.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDISourceCreate.restype = c_int32
            self.cm.MIDISourceCreate(self.client, name_cf, byref(self.source))

            # 3. Output Port (para transmitir a destinos físicos ou virtuais existentes, como IAC Driver)
            self.out_port = c_void_p()
            self.cm.MIDIOutputPortCreate.argtypes = [c_void_p, c_void_p, POINTER(c_void_p)]
            self.cm.MIDIOutputPortCreate.restype = c_int32
            self.cm.MIDIOutputPortCreate(self.client, name_cf, byref(self.out_port))

            # Assinaturas de envio
            self.cm.MIDIReceived.argtypes = [c_void_p, POINTER(MIDIPacketList)]
            self.cm.MIDIReceived.restype = c_int32
            self.cm.MIDISend.argtypes = [c_void_p, c_void_p, POINTER(MIDIPacketList)]
            self.cm.MIDISend.restype = c_int32
            self.cm.MIDIGetNumberOfDestinations.restype = c_uint32
            self.cm.MIDIGetDestination.restype = c_void_p

            print(f"🎹 [MidiClock] CoreMIDI ativo! Porta Virtual: '{self.port_name}'")
        except Exception as e:
            print(f"⚠️ [MidiClock] Erro ao inicializar CoreMIDI: {e}")
            self.client = None

    def _send_bytes(self, byte_list: list[int]):
        if not self.client:
            return
        try:
            pkt_list = MIDIPacketList()
            pkt_list.numPackets = 1
            pkt_list.packet[0].timeStamp = 0  # 0 = envio imediato
            pkt_list.packet[0].length = len(byte_list)
            for i, b in enumerate(byte_list):
                pkt_list.packet[0].data[i] = b

            # Envia para a porta virtual criada (VS Control Sync)
            if self.source:
                self.cm.MIDIReceived(self.source, byref(pkt_list))

            # Envia também para qualquer porta MIDI de destino presente (IAC Driver, TRIGGER, etc.)
            if self.out_port:
                n_dest = self.cm.MIDIGetNumberOfDestinations()
                for i in range(n_dest):
                    dest = self.cm.MIDIGetDestination(i)
                    self.cm.MIDISend(self.out_port, dest, byref(pkt_list))
        except Exception:
            pass

    def send_start(self):
        """Inicia a reprodução do início (SPP 0 + MIDI Start 0xFA)."""
        self.last_tick = -1
        self.is_playing = True
        self._send_bytes([0xF2, 0x00, 0x00])
        self._send_bytes([0xFA])

    def send_continue(self, pos_sixteenths: int = 0):
        """Retoma a reprodução da posição atual (SPP + MIDI Continue 0xFB)."""
        self.is_playing = True
        if pos_sixteenths > 0:
            lsb = pos_sixteenths & 0x7F
            msb = (pos_sixteenths >> 7) & 0x7F
            self._send_bytes([0xF2, lsb, msb])
        self._send_bytes([0xFB])

    def send_stop(self):
        """Para a reprodução (MIDI Stop 0xFC)."""
        self.is_playing = False
        self._send_bytes([0xFC])

    def send_spp(self, pos_sixteenths: int):
        """Envia Song Position Pointer (0xF2) para alinhar compasso/tempo no Ableton."""
        lsb = pos_sixteenths & 0x7F
        msb = (pos_sixteenths >> 7) & 0x7F
        self._send_bytes([0xF2, lsb, msb])

    def reset_tick(self, current_frame: int, sample_rate: int, bpm: float):
        """Atualiza a referência do último tick sem emitir pulsos acumulados."""
        if bpm <= 0 or sample_rate <= 0:
            return
        frames_per_tick = (2.5 * sample_rate) / bpm
        self.last_tick = int(current_frame / frames_per_tick)

    def process_frames(self, start_frame: int, n_frames: int, sample_rate: int, bpm: float):
        """
        Processa os ticks de MIDI Clock baseado nos frames consumidos pelo áudio.
        Garante sincronia absoluta com a saída de áudio dos fones/caixas.
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
                self._send_bytes([0xF8])

            self.last_tick = target_tick
