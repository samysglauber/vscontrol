"""
Servidor Principal FastAPI e WebSocket
Conecta o Mac e o smartphone Android com sincronização em tempo real.
"""

import os
import io
import base64
import socket
import asyncio
import time
import threading
import subprocess
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response, FileResponse
from pydantic import BaseModel
import qrcode

from app.audio_engine import LiveAudioEngine
from app.song_library import SongLibrary
from app.metronome_generator import generate_metronome_track, parse_time_signature

from pythonosc import udp_client

app = FastAPI(title="LivePlayback VS Controller")

@app.middleware("http")
async def add_no_cache_header(request, call_next):
    response = await call_next(request)
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        response.headers["Expires"] = "0"
    return response

engine = LiveAudioEngine()
library = SongLibrary()

# Cliente OSC para sincronização automática de BPM e Time Signature com o Ableton Live
osc_client = udp_client.SimpleUDPClient("127.0.0.1", 11000)

def parse_time_signature(ts_str: str) -> tuple[int, int]:
    try:
        parts = str(ts_str).strip().split("/")
        return (int(parts[0]), int(parts[1]))
    except Exception:
        return (4, 4)

def sync_tempo_to_ableton(bpm: float):
    """Envia o novo BPM para o Ableton Live via protocolo OSC."""
    if not bpm or bpm <= 0:
        return
    try:
        osc_client.send_message("/live/song/set/tempo", float(bpm))
    except Exception as e:
        print(f"Erro ao enviar BPM para AbletonOSC: {e}")

# ---------------------------------------------------------------------------
# Leitura de respostas do AbletonOSC (porta 11001) para saber a posição do playhead
# ---------------------------------------------------------------------------
_osc_waiters: dict = {}
_pending_markers: list[dict] = []   # trocas de compasso detectadas durante a gravação/reprodução
_markers_lock = threading.Lock()

def _osc_reply_handler(address, *args):
    w = _osc_waiters.get(address)
    if w is not None:
        w["value"] = args
        w["event"].set()

def start_osc_listener():
    try:
        from pythonosc.dispatcher import Dispatcher
        from pythonosc.osc_server import ThreadingOSCUDPServer
        disp = Dispatcher()
        disp.set_default_handler(_osc_reply_handler)
        server = ThreadingOSCUDPServer(("127.0.0.1", 11001), disp)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print("🎵 Ouvindo respostas do AbletonOSC em 127.0.0.1:11001")
    except Exception as e:
        print(f"⚠️ Não consegui abrir a porta 11001 para ler o playhead do Ableton: {e}")

def osc_query(address: str, timeout: float = 0.4):
    w = {"event": threading.Event(), "value": None}
    _osc_waiters[address] = w
    try:
        osc_client.send_message(address, [])
        return w["value"] if w["event"].wait(timeout) else None
    finally:
        _osc_waiters.pop(address, None)

def ableton_is_playing() -> bool:
    r = osc_query("/live/song/get/is_playing")
    return bool(r and r[0])

def ableton_song_time():
    r = osc_query("/live/song/get/current_song_time")
    return float(r[0]) if r else None

ABLETON_ACTIVATE_LIVE = os.environ.get("ABLETON_ACTIVATE_LIVE", "0") == "1"  # traz o Live p/ frente antes de clicar no menu (rouba o foco!)
_ts_lock = threading.Lock()
_last_ts_insert = {"sig": None, "t": 0.0}

def sync_time_signature_to_ableton(time_sig: str, insert_change: bool = True):
    """Sincroniza o compasso com o Live (em thread, sem travar a requisição).
    - Live PARADO: define o compasso via OSC e insere o marcador no insert marker (comportamento anterior).
    - Live TOCANDO/GRAVANDO: NÃO mexe no compasso global (isso editaria o 1º marcador) e apenas anota
      a posição atual do playhead; os marcadores são criados depois em /api/ableton/apply_markers."""
    if not time_sig:
        return
    def _worker():
        try:
            num, denom = parse_time_signature(time_sig)
            sig = f"{num}/{denom}"
            if ableton_is_playing():
                if insert_change:
                    beat = ableton_song_time()
                    if beat is not None:
                        with _markers_lock:
                            last = _pending_markers[-1] if _pending_markers else None
                            if last and last["sig"] == sig and abs(last["beat"] - beat) < 2.0:
                                return  # chamada duplicada (/api/load + /api/sync_ableton)
                            _pending_markers.append({"beat": beat, "sig": sig})
                        print(f"📝 Ableton gravando: troca para {sig} anotada no beat {beat:.2f} (aplicar ao parar)")
                return
            osc_client.send_message("/live/song/set/signature_numerator", int(num))
            osc_client.send_message("/live/song/set/signature_denominator", int(denom))
            print(f"🎵 AbletonOSC: Time Signature sincronizado para {sig}")
            if insert_change:
                trigger_ableton_time_signature_change(sig)
        except Exception as e:
            print(f"Erro ao enviar Time Signature para AbletonOSC: {e}")
    threading.Thread(target=_worker, daemon=True).start()

def apply_pending_markers() -> dict:
    """Com o Live parado, percorre as trocas anotadas: posiciona o insert marker no ponto exato,
    insere o Time Signature Change e só então define numerador/denominador (editando o marcador novo)."""
    with _markers_lock:
        items = sorted(_pending_markers, key=lambda m: m["beat"])
    if not items:
        return {"applied": 0, "results": [], "note": "nenhuma troca anotada"}
    osc_client.send_message("/live/song/stop_playing", [])
    time.sleep(0.4)
    results = []
    with _ts_lock:
        for m in items:
            num, denom = parse_time_signature(m["sig"])
            osc_client.send_message("/live/song/set/current_song_time", float(m["beat"]))
            time.sleep(0.35)
            r = insert_ableton_time_signature_change_blocking()
            time.sleep(0.3)
            osc_client.send_message("/live/song/set/signature_numerator", int(num))
            osc_client.send_message("/live/song/set/signature_denominator", int(denom))
            time.sleep(0.3)
            results.append({**m, "ok": r["ok"], "reason": r["reason"]})
    ok_ids = {id(m) for m, r in zip(items, results) if r["ok"]}
    with _markers_lock:
        _pending_markers[:] = [m for m in _pending_markers if id(m) not in ok_ids]  # mantém as que falharam
    return {"applied": len(ok_ids), "results": results}

def _build_insert_ts_script() -> str:
    activate = "set frontmost of liveProc to true\n        delay 0.15" if ABLETON_ACTIVATE_LIVE else ""
    return """
    tell application "System Events"
        -- Localiza o Live pelo bundle id (o antigo "name contains Live" podia casar com este próprio app)
        set liveProcs to (every process whose bundle identifier starts with "com.ableton.live")
        if (count of liveProcs) is 0 then return "NO_PROCESS"
        set liveProc to item 1 of liveProcs
        __ACTIVATE__
        tell liveProc
            if (count of menu bars) is 0 then return "NO_MENUBAR"
            set createMenu to menu 1 of menu bar item "Create" of menu bar 1
            set found to missing value
            set allNames to ""
            repeat with mi in (menu items of createMenu)
                set n to missing value
                try
                    set n to name of mi
                end try
                if n is not missing value then
                    set allNames to allNames & n & "; "
                    if (found is missing value) and (n contains "Time Signature") then set found to mi
                end if
            end repeat
            if found is missing value then return "NO_ITEM|" & allNames
            if not (enabled of found) then return "DISABLED|" & (name of found)
            click found
            return "OK|" & (name of found)
        end tell
    end tell
    """.replace("__ACTIVATE__", activate)

def insert_ableton_time_signature_change_blocking() -> dict:
    """Executa o AppleScript e devolve um diagnóstico real (antes um erro era engolido e logado como sucesso)."""
    try:
        res = subprocess.run(["osascript", "-e", _build_insert_ts_script()],
                             capture_output=True, text=True, timeout=8.0)
    except subprocess.TimeoutExpired:
        return {"ok": False, "reason": "TIMEOUT (provável diálogo de permissão aberto no macOS)"}
    except Exception as e:
        return {"ok": False, "reason": f"EXCEPTION {e}"}
    out, err = (res.stdout or "").strip(), (res.stderr or "").strip()
    if res.returncode != 0:
        hint = ""
        if "-1719" in err or "-25211" in err or "assistive" in err.lower():
            hint = " -> Dê permissão em Ajustes > Privacidade e Segurança > Acessibilidade ao app que roda o backend (app Swift / Terminal / Python)."
        elif "-1743" in err:
            hint = " -> Permita a Automação ('System Events') em Privacidade e Segurança > Automação."
        return {"ok": False, "reason": f"osascript erro: {err}{hint}"}
    return {"ok": out.startswith("OK"), "reason": out}

def trigger_ableton_time_signature_change(sig: str = ""):
    """Dispara a inserção do marcador em segundo plano (com debounce para não duplicar marcadores)."""
    def _run():
        # Dá tempo ao Live para aplicar numerador/denominador recebidos via OSC
        time.sleep(0.15)
        with _ts_lock:
            now = time.time()
            if _last_ts_insert["sig"] == sig and now - _last_ts_insert["t"] < 1.5:
                return  # chamada duplicada (ex.: /api/load + /api/sync_ableton)
            result = insert_ableton_time_signature_change_blocking()
            if result["ok"]:
                _last_ts_insert.update(sig=sig, t=time.time())
                print(f"🎵 Ableton: marcador inserido ({sig}) -> {result['reason']}")
            else:
                print(f"⚠️ Ableton: NÃO foi possível inserir o Time Signature Change -> {result['reason']}")
    threading.Thread(target=_run, daemon=True).start()

# Gerenciador de conexões WebSocket para sincronia Mac <-> Android
class ConnectionManager:
    def __init__(self):
        self.active_connections: list[WebSocket] = []

    async def connect(self, websocket: WebSocket):
        await websocket.accept()
        self.active_connections.append(websocket)

    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)

    async def broadcast(self, message: dict):
        for connection in list(self.active_connections):
            try:
                await connection.send_json(message)
            except Exception:
                self.disconnect(connection)

manager = ConnectionManager()
main_loop = None

# Ponte do AudioEngine (Thread de Áudio CoreAudio) para o WebSocket (Asyncio)
def on_engine_event(event_type: str, data: dict):
    if main_loop and main_loop.is_running():
        try:
            asyncio.run_coroutine_threadsafe(
                manager.broadcast({"event": event_type, "data": data}),
                main_loop
            )
        except Exception:
            pass

engine.event_listener = on_engine_event

# Loop de atualização periódica do estado do áudio (~16 FPS)
@app.on_event("startup")
async def startup_event():
    global main_loop
    main_loop = asyncio.get_running_loop()
    start_osc_listener()
    asyncio.create_task(status_broadcaster())

async def status_broadcaster():
    while True:
        if manager.active_connections:
            status = engine.get_status()
            await manager.broadcast({"event": "tick", "data": status})
            sleep_time = 0.06 if engine.is_playing else 0.5
        else:
            sleep_time = 0.5
        await asyncio.sleep(sleep_time)

# ==========================
# Endpoints de Informação de Rede e QR Code para Android
# ==========================

def get_local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = '127.0.0.1'
    finally:
        s.close()
    return ip

@app.get("/api/network_info")
def network_info():
    ip = get_local_ip()
    port = 8080
    url = f"http://{ip}:{port}"
    
    # Gera QR Code vetorial em SVG (100% puro, sem dependência de Pillow)
    import qrcode.image.svg
    qr = qrcode.QRCode(image_factory=qrcode.image.svg.SvgPathImage, box_size=8, border=2)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image()
    
    buf = io.BytesIO()
    img.save(buf)
    svg_str = buf.getvalue().decode("utf-8")
    
    return {
        "ip": ip,
        "port": port,
        "url": url,
        "qr_svg": svg_str
    }

# ==========================
# Endpoints de Músicas e Diretório de Faixas
# ==========================

class TracksFolderRequest(BaseModel):
    path: str

@app.get("/api/tracks/folder")
def get_tracks_folder():
    return {
        "path": library.directory,
        "exists": os.path.isdir(library.directory),
        "songs_count": len(library.get_all_songs())
    }

@app.post("/api/tracks/folder")
def set_tracks_folder(req: TracksFolderRequest):
    expanded_path = os.path.expanduser(req.path.strip())
    if not os.path.isdir(expanded_path):
        return JSONResponse(status_code=400, content={"error": f"Pasta inválida ou não encontrada: {req.path}"})
    library.set_directory(expanded_path)
    return {
        "status": "ok",
        "path": library.directory,
        "exists": os.path.isdir(library.directory),
        "songs_count": len(library.get_all_songs())
    }

@app.post("/api/tracks/refresh")
def refresh_tracks():
    library.refresh()
    songs = library.get_all_songs()
    return {
        "status": "ok",
        "path": library.directory,
        "songs_count": len(songs),
        "songs": songs
    }

@app.get("/api/songs")
def list_songs(ids: str | None = None):
    if ids:
        id_list = [i.strip() for i in ids.split(",") if i.strip()]
        return library.load_setlist_songs(id_list)
    return library.get_all_songs()

class SetlistQuery(BaseModel):
    ids: list[str]

@app.post("/api/songs/setlist")
def setlist_songs(req: SetlistQuery):
    songs = library.load_setlist_songs(req.ids)
    for sid in req.ids:
        if not library.has_cover(sid):
            asyncio.create_task(asyncio.to_thread(library.auto_fetch_cover, sid))
    return songs

@app.get("/api/song/{song_id}")
def get_song(song_id: str):
    song = library.get_song(song_id)
    if not song:
        return JSONResponse(status_code=404, content={"error": "Música não encontrada"})
    return song

# ==========================
# Endpoints de Capas de Álbuns / Músicas (iTunes & Local)
# ==========================

@app.get("/api/covers/search")
def search_covers(q: str):
    """Busca capas de álbuns na Apple iTunes Search API pelo título da música ou artista."""
    import urllib.request
    import urllib.parse
    import json
    if not q or not q.strip():
        return []
    clean_q = q.strip()
    url = f"https://itunes.apple.com/search?term={urllib.parse.quote(clean_q)}&media=music&entity=song&limit=24"
    req = urllib.request.Request(url, headers={"User-Agent": "VSControl/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=7) as res:
            data = json.loads(res.read().decode("utf-8"))
            results = []
            for item in data.get("results", []):
                small_art = item.get("artworkUrl100", "")
                large_art = small_art.replace("/100x100bb.jpg", "/600x600bb.jpg")
                results.append({
                    "id": str(item.get("trackId")),
                    "track_name": item.get("trackName", ""),
                    "artist_name": item.get("artistName", ""),
                    "collection_name": item.get("collectionName", ""),
                    "artwork_url": large_art or small_art,
                    "artwork_url_small": small_art,
                    "year": item.get("releaseDate", "")[:4] if item.get("releaseDate") else ""
                })
            return results
    except Exception as e:
        print(f"Erro ao buscar capas no iTunes: {e}")
        return []

class SelectCoverRequest(BaseModel):
    song_id: str
    artwork_url: str

@app.post("/api/covers/select")
def select_cover(req: SelectCoverRequest):
    """Baixa a capa selecionada pelo usuário e otimiza para 300x300 JPEG (~15-25 KB)."""
    res = library.save_cover_from_url(req.song_id, req.artwork_url)
    return res

class UploadCoverRequest(BaseModel):
    song_id: str
    file_path: str

@app.post("/api/covers/upload")
def upload_cover(req: UploadCoverRequest):
    """Importa e otimiza uma imagem do computador do usuário."""
    res = library.save_cover_from_file(req.song_id, req.file_path)
    return res

class RemoveCoverRequest(BaseModel):
    song_id: str

@app.post("/api/covers/remove")
def remove_cover(req: RemoveCoverRequest):
    """Remove a capa atribuída a uma faixa."""
    success = library.remove_cover(req.song_id)
    return {"success": success}

class AutoCoverRequest(BaseModel):
    song_id: str

@app.post("/api/covers/auto")
def auto_cover(req: AutoCoverRequest):
    """Busca e define automaticamente a melhor capa da música no iTunes se ainda não tiver capa."""
    res = library.auto_fetch_cover(req.song_id)
    if not res:
        return {"status": "not_found", "song_id": req.song_id}
    return res

@app.api_route("/api/covers", methods=["GET", "HEAD"])
def get_cover(id: str):
    """Serve a capa JPEG diretamente do disco com cache HTTP inteligente."""
    path = library.get_cover_path(id)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return JSONResponse(status_code=404, content={"error": "Capa não encontrada"})
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "public, max-age=86400"})

class LoadSongRequest(BaseModel):
    song_id: str
    device_id: int | None = None
    device_name: str | None = None
    crossfade: bool = False
    crossfade_duration: float = 4.0

class PreloadRequest(BaseModel):
    song_id: str

@app.post("/api/preload")
def preload_song(req: PreloadRequest):
    song = library.get_song(req.song_id)
    if song and "path" in song:
        engine.preload(song["path"])
    return {"status": "ok"}

@app.post("/api/load")
def load_song(req: LoadSongRequest):
    if not req.crossfade and (req.device_id is not None or req.device_name is not None):
        if req.device_name and req.device_name.strip().lower() != (engine.output_device_name or "").strip().lower():
            engine.set_output_device(device_id=req.device_id, device_name=req.device_name)
        elif req.device_id is not None and req.device_id != engine.output_device:
            engine.set_output_device(device_id=req.device_id, device_name=req.device_name)

    song = library.get_song(req.song_id)
    if not song:
        return JSONResponse(status_code=404, content={"error": "Música não encontrada"})
    
    ts = parse_time_signature(song.get("time_signature", "4/4"))
    engine.load_song(
        filepath=song["path"],
        bpm=song["bpm"],
        cues=song["cues"],
        time_signature=ts,
        crossfade=req.crossfade,
        crossfade_duration=req.crossfade_duration
    )
    if req.crossfade:
        engine.play()

    tot_dur = engine.total_frames / engine.sample_rate if (engine.total_frames and engine.sample_rate) else 0.0
    song["total_duration"] = tot_dur

    # Se a forma de onda contínua global ainda não estava calculada no cache, calcula e persiste com segurança:
    if engine.audio_data is not None and not song.get("full_waveform"):
        from app.cue_detector import compute_full_waveform
        from app.song_library import load_cues_with_backup, atomic_save_json
        song["full_waveform"] = compute_full_waveform(engine.audio_data, engine.sample_rate, n_peaks=1200)

        cache_path = song["path"] + ".cues.json"
        cached = load_cues_with_backup(cache_path) or {}
        cached["full_waveform"] = song["full_waveform"]
        cached["version"] = 6
        cached["channel"] = "R"
        if "bpm" not in cached and song.get("bpm"):
            cached["bpm"] = song.get("bpm")
        if "time_signature" not in cached and song.get("time_signature"):
            cached["time_signature"] = song.get("time_signature")
        if "cues" not in cached or not cached["cues"]:
            cached["cues"] = song.get("cues", [])
        atomic_save_json(cache_path, cached, backup=True)

    # Sincroniza o BPM e Time Signature automaticamente no Ableton Live
    if song.get("bpm"):
        sync_tempo_to_ableton(song["bpm"])
    if song.get("time_signature"):
        sync_time_signature_to_ableton(song["time_signature"], insert_change=False)

    # Se a música não tiver capa, busca automaticamente em segundo plano
    if not song.get("has_cover"):
        threading.Thread(target=library.auto_fetch_cover, args=(req.song_id,), daemon=True).start()

    return {"status": "loaded", "song": song, "bpm_synced": bool(song.get("bpm"))}

# ==========================
# Endpoints de Transporte e Controle ao Vivo
# ==========================

class PlayRequest(BaseModel):
    device_id: int | None = None
    device_name: str | None = None

@app.post("/api/play")
def play(req: PlayRequest = None):
    if req and (req.device_id is not None or req.device_name is not None):
        if req.device_name and req.device_name.strip().lower() != (engine.output_device_name or "").strip().lower():
            engine.set_output_device(device_id=req.device_id, device_name=req.device_name)
        elif req.device_id is not None and req.device_id != engine.output_device:
            engine.set_output_device(device_id=req.device_id, device_name=req.device_name)
    if engine.audio_data is None:
        songs = library.get_all_songs()
        if songs:
            target = library.get_song(songs[0]["id"])
            if target and "path" in target:
                ts_str = target.get("time_signature", "4/4")
                try:
                    num, den = (int(x) for x in ts_str.split("/"))
                    ts = (num, den)
                except Exception:
                    ts = (4, 4)
                engine.load_song(
                    filepath=target["path"],
                    bpm=target.get("bpm", 120.0),
                    cues=target.get("cues", []),
                    time_signature=ts
                )
    engine.play()
    return {"status": "playing"}

@app.post("/api/pause")
def pause():
    engine.pause()
    return {"status": "paused"}

@app.post("/api/stop")
def stop():
    engine.stop()
    return {"status": "stopped"}

@app.post("/api/quit")
def quit_backend():
    engine._stop_stream()
    def _do_exit():
        time.sleep(0.08)
        os._exit(0)
    threading.Thread(target=_do_exit, daemon=True).start()
    return {"status": "ok"}

class FadeStopRequest(BaseModel):
    duration: float = 3.0
    direction: str = "toggle"

@app.post("/api/fade_stop")
def fade_stop(req: FadeStopRequest = FadeStopRequest()):
    engine.fade_tracks(direction=req.direction, duration_sec=req.duration)
    return {"status": "fade_started", "fade_state": engine.tracks_fade_state}

@app.post("/api/fade_tracks")
def fade_tracks(req: FadeStopRequest = FadeStopRequest()):
    engine.fade_tracks(direction=req.direction, duration_sec=req.duration)
    return {"status": "fade_started", "fade_state": engine.tracks_fade_state}

class SeekRequest(BaseModel):
    seconds: float

@app.post("/api/seek")
def seek(req: SeekRequest):
    engine.seek_seconds(req.seconds)
    return {"status": "seeked", "seconds": req.seconds}

class TriggerCueRequest(BaseModel):
    cue_idx: int
    quantize: bool = True

@app.post("/api/trigger_cue")
def trigger_cue(req: TriggerCueRequest):
    engine.trigger_cue(req.cue_idx, quantize=req.quantize)
    return {"status": "triggered", "cue_idx": req.cue_idx}

class GuideLeadInRequest(BaseModel):
    bars: float = 1.0

@app.post("/api/playback/guide_lead_in")
def set_guide_lead_in(req: GuideLeadInRequest):
    engine.set_guide_lead_in(req.bars)
    return {"status": "ok", "guide_lead_in_bars": engine.guide_lead_in_bars}

class ToggleLoopRequest(BaseModel):
    cue_idx: int | None = None
    infinite: bool | None = False
    mode: str | None = None

@app.post("/api/toggle_loop")
def toggle_loop(req: ToggleLoopRequest = None):
    cue_idx = req.cue_idx if req else None
    infinite = req.infinite if req and req.infinite is not None else False
    mode = req.mode if req else None
    active = engine.toggle_loop(cue_idx=cue_idx, infinite=infinite, mode=mode)
    return {
        "loop_active": active,
        "loop_infinite": engine.loop_infinite,
        "loop_mode": "infinite" if engine.loop_infinite else ("once" if active else "off"),
        "loop_cue_idx": engine.loop_cue_idx
    }

@app.post("/api/toggle_infinite")
def toggle_infinite(req: ToggleLoopRequest = None):
    cue_idx = req.cue_idx if req else None
    active = engine.toggle_loop(cue_idx=cue_idx, infinite=True, mode="infinite")
    return {
        "loop_active": active,
        "loop_infinite": engine.loop_infinite,
        "loop_mode": "infinite" if engine.loop_infinite else ("once" if active else "off"),
        "loop_cue_idx": engine.loop_cue_idx
    }

class PadRequest(BaseModel):
    active: bool
    key: str = "D"
    volume: float = 0.35

@app.post("/api/pad")
def set_pad(req: PadRequest):
    engine.set_pad(active=req.active, key=req.key, volume=req.volume)
    return {"status": "ok"}

class VolumesRequest(BaseModel):
    click_vol: float | None = None
    vs_vol: float | None = None
    click_mute: bool | None = None
    vs_mute: bool | None = None

@app.post("/api/volumes")
def set_volumes(req: VolumesRequest):
    engine.set_volumes(
        click_vol=req.click_vol,
        vs_vol=req.vs_vol,
        click_mute=req.click_mute,
        vs_mute=req.vs_mute
    )
    return {"status": "ok"}

@app.get("/api/devices")
def get_devices():
    return engine.get_output_devices()

class DeviceRequest(BaseModel):
    device_id: int | None = None
    device_name: str | None = None

@app.post("/api/device")
def set_device(req: DeviceRequest):
    engine.set_output_device(device_id=req.device_id, device_name=req.device_name)
    return {"status": "ok", "device_id": engine.output_device, "device_name": engine.output_device_name}

class SaveCuesRequest(BaseModel):
    song_id: str
    cues: list[dict]
    bpm: float | None = None
    time_signature: str | None = None

@app.post("/api/save_cues")
def save_cues(req: SaveCuesRequest):
    song = library.get_song(req.song_id)
    audio_data = None
    sr = None
    if song and engine.filepath and engine.filepath == song.get("path") and engine.audio_data is not None:
        audio_data = engine.audio_data
        sr = engine.sample_rate

    success = library.save_cues(req.song_id, req.cues, bpm=req.bpm, time_signature=req.time_signature, audio_data=audio_data, sr=sr)
    song = library.get_song(req.song_id)
    if song:
        ts = parse_time_signature(req.time_signature or song.get("time_signature", "4/4"))
        if req.bpm:
            engine.bpm = req.bpm
            sync_tempo_to_ableton(req.bpm)
        engine.time_signature = ts
        if req.time_signature or song.get("time_signature"):
            sync_time_signature_to_ableton(req.time_signature or song.get("time_signature"))
        engine.cues = song["cues"]
    return {"success": success, "song": song}

class ReprocessRequest(BaseModel):
    song_id: str
    bpm: float | None = None
    time_signature: str | None = None

@app.post("/api/reprocess")
def reprocess_song(req: ReprocessRequest):
    song = library.reprocess_song(req.song_id, bpm=req.bpm, time_signature=req.time_signature)
    if not song:
        return JSONResponse(status_code=404, content={"error": "Música não encontrada"})
    
    ts = parse_time_signature(song.get("time_signature", "4/4"))
    engine.load_song(
        filepath=song["path"],
        bpm=song["bpm"],
        cues=song["cues"],
        time_signature=ts
    )

    tot_dur = engine.total_frames / engine.sample_rate if (engine.total_frames and engine.sample_rate) else 0.0
    song["total_duration"] = tot_dur
    if song.get("bpm"):
        sync_tempo_to_ableton(song["bpm"])
    if song.get("time_signature"):
        sync_time_signature_to_ableton(song["time_signature"])
        
    return {"status": "reprocessed", "song": song}

class MetronomeGenerateRequest(BaseModel):
    name: str = "Click"
    bpm: float = 120.0
    time_signature: str = "4/4"
    duration_sec: float = 600.0
    subdivide: bool = False
    subdivision: str = "1/4"

class MetronomeUpdateRequest(BaseModel):
    song_id: str
    name: str
    bpm: float
    time_signature: str
    duration_sec: float = 600.0
    subdivide: bool = False
    subdivision: str = "1/4"

@app.post("/api/metronome/generate")
def api_generate_metronome(req: MetronomeGenerateRequest):
    try:
        out_dir = library.directory or get_saved_tracks_dir()
        song = generate_metronome_track(
            name=req.name,
            bpm=req.bpm,
            time_signature=req.time_signature,
            duration_sec=req.duration_sec,
            output_dir=out_dir,
            subdivide=req.subdivide,
            subdivision=req.subdivision
        )
        library.refresh()
        return {"status": "success", "song": song}
    except Exception as e:
        import traceback
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"status": "error", "message": str(e)})

@app.post("/api/metronome/update")
def api_update_metronome(req: MetronomeUpdateRequest):
    try:
        out_dir = library.directory or get_saved_tracks_dir()
        existing_path = os.path.join(out_dir, req.song_id)
        if not os.path.exists(existing_path):
            match = next((s for s in library.get_all_songs() if s["id"] == req.song_id or s["filename"] == req.song_id), None)
            if match and os.path.exists(match.get("path", "")):
                existing_path = match["path"]
            else:
                existing_path = None

        song = generate_metronome_track(
            name=req.name,
            bpm=req.bpm,
            time_signature=req.time_signature,
            duration_sec=req.duration_sec,
            output_dir=out_dir,
            existing_filepath=existing_path,
            subdivide=req.subdivide,
            subdivision=req.subdivision
        )
        library.refresh()

        if engine.filepath and (engine.filepath == song["path"] or os.path.basename(engine.filepath) == song["filename"]):
            ts = parse_time_signature(song.get("time_signature", "4/4"))
            engine.load_song(
                filepath=song["path"],
                bpm=song["bpm"],
                cues=song["cues"],
                time_signature=ts
            )
            if song.get("bpm"):
                sync_tempo_to_ableton(song["bpm"])
            if song.get("time_signature"):
                sync_time_signature_to_ableton(song["time_signature"])

        return {"status": "success", "song": song}
    except Exception as e:
        import traceback
        traceback.print_exc()
        return JSONResponse(status_code=500, content={"status": "error", "message": str(e)})

class AbletonSyncRequest(BaseModel):
    bpm: float | None = None
    time_signature: str | None = None

@app.post("/api/sync_ableton")
def api_sync_ableton(req: AbletonSyncRequest):
    if req.bpm:
        sync_tempo_to_ableton(req.bpm)
    if req.time_signature:
        sync_time_signature_to_ableton(req.time_signature)
    return {"status": "ok", "bpm": req.bpm, "time_signature": req.time_signature}

@app.get("/api/ableton/markers")
def api_ableton_markers():
    """Lista as trocas de compasso anotadas durante a gravação."""
    with _markers_lock:
        return {"pending": list(_pending_markers)}

@app.post("/api/ableton/clear_markers")
def api_ableton_clear_markers():
    with _markers_lock:
        _pending_markers.clear()
    return {"status": "ok"}

@app.post("/api/ableton/apply_markers")
def api_ableton_apply_markers():
    """Chame DEPOIS de parar a gravação: cria os marcadores nos pontos exatos."""
    return apply_pending_markers()

@app.post("/api/ableton/test_marker")
def api_ableton_test_marker():
    """Diagnóstico: tenta inserir o marcador agora e devolve o motivo exato se falhar."""
    return insert_ableton_time_signature_change_blocking()

# ==========================
# WebSocket para baixa latência (Mac <-> Android)
# ==========================

@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await manager.connect(websocket)
    # Envia status inicial imediatamente
    await websocket.send_json({"event": "status", "data": engine.get_status()})
    try:
        while True:
            msg = await websocket.receive_json()
            action = msg.get("action")
            if action == "play":
                engine.play()
            elif action == "pause":
                engine.pause()
            elif action == "stop":
                engine.stop()
            elif action in ["fade_stop", "fade_tracks"]:
                engine.fade_tracks(
                    direction=msg.get("direction", "toggle"),
                    duration_sec=msg.get("duration", 3.0)
                )
            elif action == "trigger_cue":
                engine.trigger_cue(msg.get("cue_idx", 0), quantize=msg.get("quantize", True))
            elif action == "toggle_loop":
                engine.toggle_loop(
                    cue_idx=msg.get("cue_idx"),
                    infinite=msg.get("infinite", False),
                    mode=msg.get("mode")
                )
            elif action == "toggle_infinite":
                engine.toggle_loop(
                    cue_idx=msg.get("cue_idx"),
                    infinite=True,
                    mode="infinite"
                )
            elif action == "set_guide_lead_in":
                engine.set_guide_lead_in(msg.get("bars", 1.0))
            elif action == "set_pad":
                engine.set_pad(
                    active=msg.get("active", False),
                    key=msg.get("key", "D"),
                    volume=msg.get("volume", 0.35)
                )
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception:
        manager.disconnect(websocket)

# Monta arquivos estáticos do Frontend
static_dir = os.path.join(os.path.dirname(__file__), "static")
os.makedirs(static_dir, exist_ok=True)
app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")
