#!/usr/bin/env python3
import argparse
import json
import subprocess
import threading
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'Engine'
DATA = ENGINE / 'Data'
SCRIPTS = ENGINE / 'Scripts'
SNAPSHOT = DATA / 'Published/danasafe_live_snapshot.json'

FILES = {
    '/radar/systems': DATA / 'Radar/AEMET/NationalSequence/Processed/radar_systems_v03.json',
    '/radar/tracks': DATA / 'Radar/AEMET/NationalSequence/Processed/reliable_tracks.json',
    '/radar/contours': DATA / 'Radar/AEMET/NationalClean/national_marching_contours.json',
    '/hydrology/stations': DATA / 'saih_stations.json',
    '/state': DATA / 'DanaSafe_state.json',
}
SNAPSHOT_SECTIONS = {
    '/radar/systems': 'radar', '/radar/tracks': 'tracks',
    '/radar/contours': 'contours', '/hydrology/stations': 'hydrology',
}

last_refresh = {
    'ok': None, 'running': False,
    'started_at': None, 'finished_at': None,
    'radar_timestamp': None, 'error': None,
}
refresh_lock = threading.Lock()
status_lock = threading.Lock()


def read_snapshot_metadata():
    if not SNAPSHOT.exists(): return None, None, None
    try:
        data = json.loads(SNAPSHOT.read_text(encoding='utf-8'))
        frames = data.get('radar', {}).get('frames', [])
        systems = len(frames[-1].get('systems', [])) if frames else 0
        return data.get('radar_timestamp'), systems, data.get('generated_at')
    except Exception:
        return None, None, None


def update_status(**kwargs):
    with status_lock: last_refresh.update(kwargs)


def run_pipeline():
    if not refresh_lock.acquire(blocking=False):
        return False
    published, _, _ = read_snapshot_metadata()
    update_status(running=True, started_at=datetime.now().astimezone().isoformat(), error=None)
    try:
        commands = [
            'download_compo_sequence.py',
            'process_compo_sequence.py',
            'build_radar_systems_v03.py',
            'track_radar_sequence.py',
            'preview_reliable_tracks.py',
            'sync_latest_frame.py',
            'national_marching_squares.py',
            'publish_live_snapshot.py',
        ]
        for script in commands:
            subprocess.run(['python3', str(SCRIPTS / script)], cwd=ENGINE, check=True)
        timestamp, _, _ = read_snapshot_metadata()
        if not timestamp:
            raise RuntimeError('Pipeline completed but no published radar timestamp was found')
        update_status(ok=True, running=False,
                      finished_at=datetime.now().astimezone().isoformat(),
                      radar_timestamp=timestamp, error=None)
        return True
    except Exception as exc:
        update_status(ok=False, running=False,
                      finished_at=datetime.now().astimezone().isoformat(),
                      radar_timestamp=published, error=str(exc))
        return False
    finally:
        refresh_lock.release()


class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload, status=200):
        raw=json.dumps(payload,ensure_ascii=False).encode('utf-8')
        self.send_response(status); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(raw))); self.send_header('Cache-Control','no-store, no-cache, must-revalidate')
        self.end_headers(); self.wfile.write(raw)
    def send_file(self,file):
        if not file.exists(): self.send_json({'status':'missing','file':str(file)},404); return
        raw=file.read_bytes(); self.send_response(200); self.send_header('Content-Type','application/json; charset=utf-8')
        self.send_header('Content-Length',str(len(raw))); self.send_header('Cache-Control','no-store, no-cache, must-revalidate')
        self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        path=self.path.split('?',1)[0]
        if path=='/health':
            timestamp,count,generated=read_snapshot_metadata()
            with status_lock: refresh=dict(last_refresh)
            self.send_json({'service':'DanaSafe Local Developer Server','version':'3.2.0-manual-refresh',
                'status':'ok','port':self.server.server_port,
                'radar_timestamp':timestamp,'radar_systems':count,
                'snapshot_generated_at':generated,'refresh':refresh}); return
        if path=='/snapshot': self.send_file(SNAPSHOT); return
        if path=='/refresh':
            ok=run_pipeline()
            with status_lock: refresh=dict(last_refresh)
            if not ok:
                if refresh.get('running'): self.send_json({'status':'busy','refresh':refresh},409)
                else: self.send_json({'status':'error','refresh':refresh},500)
                return
            self.send_json({'status':'ok','refresh':refresh}); return
        section=SNAPSHOT_SECTIONS.get(path)
        if section is not None:
            if not SNAPSHOT.exists(): self.send_json({'status':'missing','file':str(SNAPSHOT)},404); return
            self.send_json(json.loads(SNAPSHOT.read_text(encoding='utf-8'))[section]); return
        if path=='/state': self.send_file(FILES['/state']); return
        self.send_json({'status':'not_found','endpoints':['/health','/snapshot','/refresh',*FILES.keys()]},404)
    def log_message(self,fmt,*args): print('[DanaSafe]',fmt%args)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument('--port',type=int,default=7117)
    args=parser.parse_args()
    server=ThreadingHTTPServer(('0.0.0.0',args.port),Handler)
    print(f'DanaSafe V3.2 manual-refresh server ready on 0.0.0.0:{args.port}')
    print('No automatic radar refresh. The app Refresh button runs AEMET -> DanaSafe algorithm -> atomic snapshot.')
    server.serve_forever()
if __name__=='__main__': main()
