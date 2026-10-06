import configparser
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import worker


class ChartTests(unittest.TestCase):
    def test_utf8_bom_crlf_and_notes_are_preserved(self):
        original = '#ARTIST:Beyoncé\r\n#TITLE:Test\r\n#GAP:1250\r\n: 0 4 -3 hé\r\nE\r\n'.encode('utf-8-sig')
        updated = worker.update_chart(original, 'mix [INSTR].m4a', 'mix [VOC].m4a')
        self.assertTrue(updated.startswith(b'\xef\xbb\xbf'))
        self.assertIn(b'#GAP:1250\r\n', updated)
        self.assertTrue(updated.endswith(': 0 4 -3 hé\r\nE\r\n'.encode()))
        self.assertIn(b'#INSTRUMENTAL:mix [INSTR].m4a\r\n', updated)

    def test_cp1252_and_existing_vocals_preserved(self):
        original = '#ARTIST:Beyoncé\n#VOCALS:official.wav\n: 0 1 0 test\nE\n'.encode('cp1252')
        updated = worker.update_chart(original, 'instrumental.m4a', 'new-vocals.m4a')
        self.assertIn(b'Beyonc\xe9', updated)
        self.assertIn(b'#VOCALS:official.wav', updated)
        self.assertNotIn(b'new-vocals', updated)

    def test_existing_instrumental_is_protected(self):
        with self.assertRaisesRegex(ValueError, 'already has'):
            worker.update_chart(b'#INSTRUMENTAL:official.wav\nE\n', 'new.m4a', 'v.m4a')

    def test_declared_encoding_controls_new_headers(self):
        result = worker.update_chart(b'#ENCODING:CP1252\n#TITLE:Test\nE\n', 'Beyoncé.m4a', 'vocals.m4a')
        self.assertIn(b'#INSTRUMENTAL:Beyonc\xe9.m4a', result)


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.chart = self.root / 'Beyoncé.txt'
        self.audio = self.root / 'song.m4a'
        self.chart.write_text('#ARTIST:Beyoncé\n#TITLE:Song\n#MP3:song.m4a\n#BPM:120\n: 0 4 0 Hi\nE\n')
        self.original = self.chart.read_bytes()
        self.audio.write_bytes(b'original audio')
        self.job = self.root / (worker.job_id(self.chart) + '.job')
        config = configparser.ConfigParser(interpolation=None)
        config['Song'] = {'Chart': str(self.chart), 'Audio': str(self.audio)}
        with self.job.open('w') as f:
            config.write(f)

    def splitter(self, audio, out):
        v, i = out / 'v.m4a', out / 'i.m4a'
        v.write_bytes(b'vocals')
        i.write_bytes(b'instrumental')
        return v, i

    def test_finished_job_links_complete_files(self):
        meta = self.root / 'metadata.usdb'
        meta.write_text(json.dumps({'txt': {'fname': self.chart.name}, 'audio': {'resource': 'source'}}))
        with patch.object(worker.Separator, 'split', side_effect=self.splitter), patch.object(worker, 'duration', return_value=180):
            worker.process_job(self.job, worker.Separator())
        self.assertFalse(self.job.exists())
        status = worker.read_ini(self.job.with_suffix('.status'))['Job']
        self.assertEqual(status['Stage'], 'ready')
        self.assertEqual((self.root / status['Instrumental']).read_bytes(), b'instrumental')
        self.assertIn(b'#INSTRUMENTAL:', self.chart.read_bytes())
        self.assertEqual(self.audio.read_bytes(), b'original audio')
        self.assertEqual(json.loads(meta.read_text())['instrumental']['status'], 'success')

    def test_changed_audio_fails_without_publishing(self):
        def changed(audio, out):
            audio.write_bytes(b'updated source')
            return self.splitter(audio, out)
        with self.assertLogs(worker.LOG, level='ERROR'), patch.object(worker.Separator, 'split', side_effect=changed), patch.object(worker, 'duration', return_value=180):
            worker.process_job(self.job, worker.Separator())
        self.assertEqual(worker.read_ini(self.job.with_suffix('.status'))['Job']['Stage'], 'failed')
        self.assertTrue(self.job.with_suffix('.failed').exists())
        self.assertEqual(self.chart.read_bytes(), self.original)
        self.assertFalse((self.root / 'song [INSTR].m4a').exists())

    def test_duration_mismatch_fails_without_changing_chart(self):
        with self.assertLogs(worker.LOG, level='ERROR'), patch.object(worker.Separator, 'split', side_effect=self.splitter), patch.object(worker, 'duration', side_effect=[180, 185]):
            worker.process_job(self.job, worker.Separator())
        self.assertEqual(worker.read_ini(self.job.with_suffix('.status'))['Job']['Stage'], 'failed')
        self.assertEqual(self.chart.read_bytes(), self.original)

    def test_failed_chart_publication_can_be_retried(self):
        real_write = worker.atomic_write

        def fail_chart(path, data):
            if path == self.chart:
                raise OSError('Simulated chart write failure')
            real_write(path, data)

        with self.assertLogs(worker.LOG, level='ERROR'), patch.object(worker, 'atomic_write', side_effect=fail_chart), patch.object(worker.Separator, 'split', side_effect=self.splitter), patch.object(worker, 'duration', return_value=180):
            worker.process_job(self.job, worker.Separator())
        self.assertEqual(self.chart.read_bytes(), self.original)
        self.assertFalse((self.root / 'song [INSTR].m4a').exists())
        self.assertFalse((self.root / 'song [VOC].m4a').exists())
        self.job.with_suffix('.failed').rename(self.job)
        with patch.object(worker.Separator, 'split', side_effect=self.splitter), patch.object(worker, 'duration', return_value=180):
            worker.process_job(self.job, worker.Separator())
        self.assertEqual(worker.read_ini(self.job.with_suffix('.status'))['Job']['Stage'], 'ready')


if __name__ == '__main__':
    unittest.main()
