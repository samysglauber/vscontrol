"""
Servidor Principal FastAPI e WebSocket
Conecta o Mac e o smartphone Android com sincronização em tempo real.
"""

import os
import io
import base64
import socket
import asyncio
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from fastapi.responses import JSONResponse, Response, FileResponse
from pydantic import BaseModel
import qrcode

from app.audio_engine import LiveAudioEngine
from app.song_library import SongLibrary

from pythonosc import udp_client

app = FastAPI(title="LivePlayback VS Controller")
engine = LiveAudioEngine()
library = SongLibrary()

# Cliente OSC para sincronização automática de BPM com o Ableton Live
osc_client = udp_client.SimpleUDPClient("127.0.0.1", 11000)

def sync_tempo_to_ableton(bpm: float):
    """Envia o novo BPM para o Ableton Live via protocolo OSC."""
    if not bpm or bpm <= 0:
        return
    try:
        osc_client.send_message("/live/song/set/tempo", float(bpm))
    except Exception as e:
        print(f"Erro ao enviar BPM para AbletonOSC: {e}")

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
    asyncio.create_task(status_broadcaster())

async def status_broadcaster():
    while True:
        if manager.active_connections:
            status = engine.get_status()
            await manager.broadcast({"event": "tick", "data": status})
        await asyncio.sleep(0.06)  # ~16 updates por segundo (leve e ultra fluido)

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

def parse_time_signature(ts_str: str) -> tuple[int, int]:
    try:
        parts = ts_str.split("/")
        return (int(parts[0]), int(parts[1]))
    except Exception:
        return (4, 4)

class LoadSongRequest(BaseModel):
    song_id: str

@app.post("/api/load")
def load_song(req: LoadSongRequest):
    song = library.get_song(req.song_id)
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

    # Sincroniza o BPM automaticamente no Ableton Live
    if song.get("bpm"):
        sync_tempo_to_ableton(song["bpm"])

    # Se a música não tiver capa, busca automaticamente em segundo plano
    if not song.get("has_cover"):
        asyncio.create_task(asyncio.to_thread(library.auto_fetch_cover, req.song_id))

    return {"status": "loaded", "song": song, "bpm_synced": bool(song.get("bpm"))}

# ==========================
# Endpoints de Transporte e Controle ao Vivo
# ==========================

@app.post("/api/play")
def play():
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

class FadeStopRequest(BaseModel):
    duration: float = 3.0

@app.post("/api/fade_stop")
def fade_stop(req: FadeStopRequest = FadeStopRequest()):
    engine.fade_stop(req.duration)
    return {"status": "fade_stop_started", "duration": req.duration}

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

@app.post("/api/toggle_loop")
def toggle_loop(req: ToggleLoopRequest = None):
    cue_idx = req.cue_idx if req else None
    active = engine.toggle_loop(cue_idx=cue_idx)
    return {"loop_active": active, "loop_cue_idx": engine.loop_cue_idx}

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
    device_id: int

@app.post("/api/device")
def set_device(req: DeviceRequest):
    engine.set_output_device(req.device_id)
    return {"status": "ok", "device_id": req.device_id}

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
        
    return {"status": "reprocessed", "song": song}

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
            elif action == "fade_stop":
                engine.fade_stop(msg.get("duration", 3.0))
            elif action == "trigger_cue":
                engine.trigger_cue(msg.get("cue_idx", 0), quantize=msg.get("quantize", True))
            elif action == "toggle_loop":
                engine.toggle_loop(msg.get("cue_idx"))
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
