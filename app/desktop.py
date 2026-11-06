"""
VS Control - Aplicativo Nativo macOS
Executa uma janela nativa Cocoa (NSWindow / WKWebView) com estilo Apple e Dock Icon.
"""

import os
import sys
import time
import urllib.request
import threading
import uvicorn
import webview

def start_server():
    from app.main import app
    config = uvicorn.Config(
        app,
        host="0.0.0.0",
        port=8080,
        log_level="warning",
        access_log=False
    )
    server = uvicorn.Server(config)
    server.run()

def wait_for_server(url="http://127.0.0.1:8080/api/songs", timeout=10.0):
    """Aguarda o servidor FastAPI responder com status 200 antes de abrir a janela."""
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            with urllib.request.urlopen(url, timeout=0.8) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(0.1)
    return False

def main():
    # 1. Inicia o servidor em segundo plano (para alimentar a janela e o celular Android)
    server_thread = threading.Thread(target=start_server, daemon=True)
    server_thread.start()

    # 2. Aguarda o servidor responder com segurança para evitar tela preta de conexão recusada
    server_ready = wait_for_server()
    if not server_ready:
        print("Aviso: Servidor demorou para responder, tentando abrir a janela...")

    # 3. Cria a janela nativa do macOS
    window = webview.create_window(
        title="VS Control",
        url="http://127.0.0.1:8080",
        width=1240,
        height=820,
        min_size=(980, 660),
        background_color="#0b0d14",
        text_select=False,
        zoomable=False
    )

    # 4. Executa o loop principal de eventos do macOS (AppKit / Cocoa)
    webview.start(gui="cocoa", debug=True)

if __name__ == "__main__":
    main()
