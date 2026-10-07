"""USDB Syncer add-on: loopback catalog/download API for the native USDX UI."""

import configparser
import io
import os
from pathlib import Path
import secrets
import sys
import threading

from flask import Flask, jsonify, request
from werkzeug.serving import make_server

PAGE_SIZE = 6
_server = None
_timer = None


def create_app(search, download, token):
    app = Flask(__name__)

    @app.before_request
    def authenticate():
        if not secrets.compare_digest(request.headers.get('X-USDX-Token', ''), token):
            return jsonify(error='The Syncer connection changed. Please search again.'), 401

    @app.get('/songs')
    def songs():
        query = request.args.get('q', '')[:200]
        try:
            offset = max(0, int(request.args.get('offset', '0')))
            return jsonify(search(query, offset, PAGE_SIZE))
        except Exception as error:
            return jsonify(error=str(error)), 400

    @app.post('/songs/<int:song_id>/download')
    def request_download(song_id):
        if not 0 < song_id < 100000:
            return jsonify(error='Invalid USDB song ID.'), 400
        try:
            return jsonify(download(song_id))
        except Exception as error:
            return jsonify(error=str(error)), 400

    return app


def describe_song(song):
    audio = song.audio_path()
    chart = song.sync_meta.txt_path() if song.sync_meta else None
    ready = bool(audio and audio.is_file() and chart and chart.is_file())
    status = str(song.status)
    if song.sync_meta is not None and not ready and status not in ('Pending', 'Downloading'):
        status = 'Failed'
    return {'id': int(song.song_id), 'artist': song.artist, 'title': song.title,
            'year': song.year or 0, 'status': status, 'ready': ready,
            'chart': str(chart) if ready else ''}


def search_catalog(query, offset, limit):
    from usdb_syncer import db, utils
    from usdb_syncer.usdb_song import UsdbSong

    db.connect(utils.AppPaths.db)
    try:
        ids = list(db.search_usdb_songs(db.SearchBuilder(text=query)))
        return {'total': len(ids), 'offset': offset, 'limit': limit,
                'songs': [describe_song(s) for i in ids[offset:offset + limit]
                          if (s := UsdbSong.get(i))]}
    finally:
        db.close()


def download_song(song_id):
    from usdb_syncer import SongId, db, utils
    from usdb_syncer.song_loader import DownloadManager
    from usdb_syncer.usdb_scraper import SessionManager
    from usdb_syncer.usdb_song import UsdbSong

    db.connect(utils.AppPaths.db)
    try:
        song = UsdbSong.get(SongId(song_id))
        if song is None:
            raise ValueError('Song no longer exists in the USDB catalog.')
        info = describe_song(song)
        if not info['ready'] and song.status.can_be_downloaded():
            if not SessionManager.get_user():
                raise ValueError('Sign in through USDB → USDB Login in Syncer first.')
            if not utils.ffmpeg_is_available():
                raise ValueError('Configure FFmpeg in USDB Syncer before downloading.')
            # Syncer can retain successful metadata after files were removed.
            # A missing local audio/chart must actually be fetched again.
            DownloadManager.download([song], utils.ProgressProxy('Requested from UltraStar Deluxe'),
                                     force_redownload=song.sync_meta is not None)
        return describe_song(song)
    finally:
        db.close()


def connection_file():
    if value := os.environ.get('USDX_USDB_BRIDGE'):
        return Path(value)
    if sys.platform == 'darwin':
        root = Path.home() / 'Library/Application Support/UltraStar Deluxe'
    elif sys.platform == 'win32':
        root = Path(os.environ['APPDATA']) / 'ultrastardx'
    else:
        root = Path.home() / '.ultrastardx'
    return root / 'usdb-bridge.ini'


def start_server():
    global _server
    from usdb_syncer.logger import logger

    token = secrets.token_hex(32)
    _server = make_server('127.0.0.1', 0, create_app(search_catalog, download_song, token))
    thread = threading.Thread(target=_server.serve_forever, daemon=True, name='USDX catalog bridge')
    thread.start()
    target = connection_file()
    target.parent.mkdir(parents=True, exist_ok=True)
    config = configparser.ConfigParser(interpolation=None)
    config['Bridge'] = {'URL': f'http://127.0.0.1:{_server.server_port}', 'Token': token}
    output = io.StringIO()
    config.write(output)
    temp = target.with_suffix('.tmp')
    temp.write_text(output.getvalue(), encoding='utf-8')
    temp.chmod(0o600)
    temp.replace(target)
    logger.info('Native USDX catalog search is ready.')


def on_loaded(window):
    global _timer
    from PySide6.QtCore import QTimer
    from usdb_syncer import events

    def ready():
        if not window.isVisible():
            return
        _timer.stop()
        if _server is None:
            start_server()

    def shutdown(_):
        if _server is not None:
            _server.shutdown()

    events.Shutdown.subscribe(shutdown)
    _timer = QTimer(window)
    _timer.setInterval(500)
    _timer.timeout.connect(ready)
    _timer.start()


def register():
    from usdb_syncer.gui import hooks
    hooks.MainWindowDidLoad.subscribe(on_loaded)


# Syncer loads add-ons as modules; tests can exercise create_app without a GUI.
if os.environ.get('USDX_BRIDGE_TEST') != '1':
    register()
