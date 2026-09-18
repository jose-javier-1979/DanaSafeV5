#!/bin/zsh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [ ! -d ".venv" ]; then
  python3 -m venv .venv
fi
source .venv/bin/activate
python -m pip install -q -r Engine/requirements.txt
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
echo "=================================================="
echo " DanaSafe Developer V3.2 Server"
echo "=================================================="
echo "Port: 7117"
if [ -n "$IP" ]; then
  echo "On iPhone use: http://$IP:7117"
else
  echo "Could not detect Mac LAN IP. Run: ipconfig getifaddr en0"
fi
echo "Radar update: MANUAL from the app Refresh button"
echo "Pipeline: AEMET latest 10 -> DanaSafe algorithm -> /snapshot"
echo "=================================================="
python Tools/local_danasafe_server.py --port 7117
