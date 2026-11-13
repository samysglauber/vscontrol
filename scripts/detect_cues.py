#!/usr/bin/env python3
import sys
import json
import os

# Add parent directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from app.song_library import SongLibrary

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: detect_cues.py <song_id_or_path> [bpm] [time_signature] [tracks_dir]"}))
        sys.exit(1)
        
    song_id = sys.argv[1]
    bpm = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] != "null" and sys.argv[2] != "" else None
    ts = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "null" and sys.argv[3] != "" else None
    tracks_dir = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "null" and sys.argv[4] != "" else os.environ.get("TRACKS_DIR", "/Users/samysglauber/Documents/Vs")
    
    lib = SongLibrary(directory=tracks_dir)
    song = lib.reprocess_song(song_id, bpm=bpm, time_signature=ts)
    if song:
        print(json.dumps({"status": "success", "song": song}))
    else:
        print(json.dumps({"error": "Failed to reprocess song"}))
