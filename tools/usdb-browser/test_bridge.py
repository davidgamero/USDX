import os
os.environ['USDX_BRIDGE_TEST'] = '1'

import unittest
import configparser
from pathlib import Path
import subprocess
import tempfile
import threading
from types import SimpleNamespace
from unittest.mock import Mock, patch
from werkzeug.serving import make_server
from usdx_catalog import create_app, download_song


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.search = Mock(return_value={'total': 20, 'songs': [{'id': 22898, 'artist': 'Bublé', 'title': 'Can’t Help Falling In Love'}]})
        self.download = Mock(return_value={'id': 22898, 'status': 'Pending', 'ready': False})
        self.client = create_app(self.search, self.download, 'test-token').test_client()
        self.headers = {'X-USDX-Token': 'test-token'}

    def test_unicode_search_and_paging(self):
        response = self.client.get('/songs', query_string={'q': 'Bublé', 'offset': 6}, headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.search.assert_called_once_with('Bublé', 6, 6)
        self.assertEqual(response.json['songs'][0]['title'], 'Can’t Help Falling In Love')

    def test_unauthorized_requests_cannot_download(self):
        self.assertEqual(self.client.post('/songs/22898/download').status_code, 401)
        self.download.assert_not_called()

    def test_download_and_backend_error(self):
        self.assertEqual(self.client.post('/songs/22898/download', headers=self.headers).json['status'], 'Pending')
        self.download.assert_called_once_with(22898)
        self.download.side_effect = ValueError('Sign in first')
        response = self.client.post('/songs/22898/download', headers=self.headers)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json['error'], 'Sign in first')

    def test_invalid_id_and_offset(self):
        self.assertEqual(self.client.post('/songs/100000/download', headers=self.headers).status_code, 400)
        self.assertEqual(self.client.get('/songs?offset=bad', headers=self.headers).status_code, 400)
        self.download.assert_not_called()

    def test_download_is_idempotent_while_pending(self):
        from usdb_syncer.db import DownloadStatus
        song = SimpleNamespace(song_id=22898, artist='Artist', title='Title', year=1961,
                               status=DownloadStatus.NONE, sync_meta=None, audio_path=lambda: None)

        def enqueue(*_, **kwargs):
            song.status = DownloadStatus.PENDING

        with patch('usdb_syncer.db.connect'), patch('usdb_syncer.db.close'), \
             patch('usdb_syncer.usdb_song.UsdbSong.get', return_value=song), \
             patch('usdb_syncer.usdb_scraper.SessionManager.get_user', return_value=object()), \
             patch('usdb_syncer.utils.ffmpeg_is_available', return_value=True), \
             patch('usdb_syncer.song_loader.DownloadManager.download', side_effect=enqueue) as download:
            self.assertEqual(download_song(22898)['status'], 'Pending')
            self.assertEqual(download_song(22898)['status'], 'Pending')
            self.assertEqual(download.call_count, 1)

    def test_missing_cached_files_are_downloaded_again(self):
        from usdb_syncer.db import DownloadStatus
        meta = SimpleNamespace(txt_path=lambda: None)
        song = SimpleNamespace(song_id=22898, artist='Artist', title='Title', year=1961,
                               status=DownloadStatus.SYNCHRONIZED, sync_meta=meta, audio_path=lambda: None)
        with patch('usdb_syncer.db.connect'), patch('usdb_syncer.db.close'), \
             patch('usdb_syncer.usdb_song.UsdbSong.get', return_value=song), \
             patch('usdb_syncer.usdb_scraper.SessionManager.get_user', return_value=object()), \
             patch('usdb_syncer.utils.ffmpeg_is_available', return_value=True), \
             patch('usdb_syncer.song_loader.DownloadManager.download') as download:
            self.assertEqual(download_song(22898)['status'], 'Failed')
            self.assertTrue(download.call_args.kwargs['force_redownload'])

    def test_native_client_round_trip(self):
        binary = Path(__file__).resolve().parents[2] / 'build/test_usdb_client'
        if not binary.exists():
            self.skipTest('Run make test-usdb-client first')
        server = make_server('127.0.0.1', 0, create_app(self.search, self.download, 'test-token'))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='usdx-native-browser-') as temp:
                config = configparser.ConfigParser(interpolation=None)
                config['Bridge'] = {'URL': f'http://127.0.0.1:{server.server_port}', 'Token': 'test-token'}
                path = Path(temp) / 'bridge.ini'
                with path.open('w') as f:
                    config.write(f)
                result = subprocess.run([str(binary)], env={**os.environ, 'USDX_USDB_BRIDGE': str(path)},
                                        capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.search.assert_called_once_with('Bublé & Elvis', 6, 6)
                self.download.assert_called_once_with(22898)
        finally:
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    unittest.main()
