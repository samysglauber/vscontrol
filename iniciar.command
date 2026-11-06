#!/bin/bash
# VS Control - Iniciador para macOS
# Dê dois cliques neste arquivo no Finder para iniciar o app!

cd "$(dirname "$0")"

echo "========================================================="
echo "   🎛️  INICIANDO O VS CONTROL (ESTILO PLAYBACK)"
echo "========================================================="
echo ""

# Obtém IP local para exibir no terminal
LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")

echo "👉 Abrindo a interface no Mac: http://localhost:8080"
echo "📱 Para controlar pelo Android, acesse: http://${LOCAL_IP}:8080"
echo ""

# Abre o navegador automaticamente no Mac após 1 segundo
(sleep 1 && open "http://localhost:8080") &

# Executa o servidor FastAPI/Uvicorn
/Library/Frameworks/Python.framework/Versions/3.15/bin/python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload
