"""Opt-in real Demucs test: USDX_TEST_AUDIO=/path/to/audio.m4a."""

import configparser
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import worker


@unittest.skipUnless(os.environ.get('USDX_TEST_AUDIO'), 'Set USDX_TEST_AUDIO for real separation')
class LiveProgressTests(unittest.TestCase):
    def test_queue_progress_and_warm_model_history(self):
        with tempfile.TemporaryDirectory(prefix='usdx-live-eta-') as temp:
            root = Path(temp)
            queue = root / 'queue'
            queue.mkdir()
            ids = []
            for index, seconds in enumerate((40, 12)):
                folder = root / f'song-{index}'
                folder.mkdir()
                audio = folder / 'audio.m4a'
                chart = folder / 'chart.txt'
                subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-i', os.environ['USDX_TEST_AUDIO'],
                                '-t', str(seconds), '-c:a', 'aac', str(audio)], check=True)
                chart.write_text('#ARTIST:Fixture\n#TITLE:Progress test\n#MP3:audio.m4a\n#BPM:120\n: 0 4 0 Hi\nE\n')
                job = queue / (worker.job_id(chart) + '.job')
                config = configparser.ConfigParser(interpolation=None)
                config['Song'] = {'Chart': str(chart), 'Audio': str(audio)}
                with job.open('w') as file:
                    config.write(file)
                ids.append(job.stem)
            observations = {key: [] for key in ids}
            with (root / 'worker.log').open('w') as log:
                process = subprocess.Popen([sys.executable, str(Path(worker.__file__)), '--queue', str(queue)],
                                           stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 240
                    while time.monotonic() < deadline:
                        self.assertIsNone(process.poll(), (root / 'worker.log').read_text())
                        for key in ids:
                            path = queue / f'{key}.status'
                            if not path.exists():
                                continue
                            status = dict(worker.read_ini(path)['Job'])
                            if not observations[key] or observations[key][-1] != status:
                                observations[key].append(status)
                            self.assertNotEqual(status['stage'], 'failed', status)
                            if status.get('percent') == '100':
                                chart = Path(status['chart'])
                                self.assertTrue(chart.with_name(status['instrumental']).is_file())
                                self.assertIn('#INSTRUMENTAL:', chart.read_text())
                        if all(values and values[-1]['stage'] == 'ready' for values in observations.values()):
                            break
                        time.sleep(0.1)
                    else:
                        self.fail('Real separation timed out: ' + (root / 'worker.log').read_text())
                finally:
                    process.terminate()
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            first, second = (observations[key] for key in ids)
            if sys.platform == 'darwin':
                self.assertEqual((root / 'worker.log').read_text().count('Conversion QoS: user-initiated'), 2)
            self.assertTrue(any(s['stage'] == 'separating' and int(s['chunksdone']) >= 3
                                and int(s['estimatedremainingseconds']) > 0 for s in first))
            self.assertTrue(any(s['stage'] == 'queued' and int(s['estimatedwaitseconds']) > 0 for s in second))
            for values in observations.values():
                percentages = [int(s['percent']) for s in values if int(s['percent']) >= 0]
                self.assertEqual(percentages, sorted(percentages))
                self.assertTrue(all(int(s['percent']) < 100 for s in values if s['stage'] != 'ready'))
            history = json.loads((queue / 'timings.json').read_text())
            samples = next(iter(history['profiles'].values()))
            self.assertEqual([s['cold'] for s in samples], [True, False])
            self.assertTrue(all(s['chunks'] > 0 and s['separating'] > 0 for s in samples))
            print('\nReal progress verified:', json.dumps({
                'cold_seconds': first[-1]['seconds'], 'warm_seconds': second[-1]['seconds'],
                'chunks': [first[-1]['chunkstotal'], second[-1]['chunkstotal']],
                'history_samples': len(samples),
            }))


if __name__ == '__main__':
    unittest.main()
