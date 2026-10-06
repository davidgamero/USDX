import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from estimates import JobProgress, ProgressPool, TimingHistory, profile_key, queue_estimates
from worker import atomic_write, read_ini, write_status


class Clock:
    def __init__(self):
        self.time = 0.0

    def __call__(self):
        return self.time

    def advance(self, seconds):
        self.time += seconds


class EstimateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.history = TimingHistory(self.root / 'history.json', 'test-profile', atomic_write)
        self.clock = Clock()
        self.progress = JobProgress(self.root / 'job.status', self.history, write_status,
                                    cold=True, clock=self.clock, wall_clock=self.clock)
        self.progress.set_audio(180)

    def sample(self, cold=True, preparing=12, separating=90):
        return {'audio': 180, 'cold': cold, 'preparing': preparing, 'reading': 1,
                'separating': separating, 'encoding': 6, 'saving': 1,
                'chunks': 30, 'chunk_rate': separating / 30}

    def test_history_survives_restart_and_separates_cold_start(self):
        self.history.record(self.sample(cold=True, preparing=12))
        self.history.record(self.sample(cold=False, preparing=0.2))
        reloaded = TimingHistory(self.history.path, 'test-profile', atomic_write)
        self.assertEqual(reloaded.estimate(180, True)['preparing'], 12)
        self.assertEqual(reloaded.estimate(180, False)['preparing'], 0.2)
        self.assertEqual(reloaded.estimate(360, False)['separating'], 180)
        other = TimingHistory(self.history.path, 'different-hardware', atomic_write)
        self.assertEqual(other.samples(), [])

    def test_short_song_has_no_false_early_eta_or_100_percent(self):
        self.progress.set_audio(3)
        self.progress.set_phase('separating')
        self.progress.set_chunks(1)
        self.assertIsNone(self.progress.remaining())
        self.clock.advance(2)
        self.progress.chunk_done(2)
        self.assertLess(self.progress.snapshot()['Percent'], 100)
        self.progress.set_phase('encoding')
        self.progress.fraction_done(1)
        self.assertLess(self.progress.snapshot()['Percent'], 100)
        self.progress.set_phase('saving')
        self.assertEqual(self.progress.snapshot()['Percent'], 99)
        self.progress.finish('ready')
        self.assertEqual(self.progress.snapshot()['Percent'], 100)
        self.assertEqual(self.progress.remaining(), 0)

    def test_eta_calibrates_and_adapts_to_load(self):
        self.progress.set_phase('separating')
        self.progress.set_chunks(40)
        for elapsed in (15, 2):
            self.clock.advance(elapsed)
            self.progress.chunk_done(elapsed)
            self.assertIsNone(self.progress.remaining())
        self.clock.advance(2)
        self.progress.chunk_done(2)
        self.assertAlmostEqual(self.progress.rate, 2)  # warmup excluded
        fast_eta = self.progress.remaining()
        for _ in range(3):
            self.clock.advance(8)
            self.progress.chunk_done(8)
        self.assertGreater(self.progress.remaining(), fast_eta)
        self.clock.advance(10_000)
        self.assertGreaterEqual(self.progress.remaining(), 0)
        snapshot = self.progress.snapshot()
        self.assertGreater(snapshot['ProgressAgeSeconds'], snapshot['ProgressTimeoutSeconds'])

    def test_pool_counts_actual_chunks_across_multiple_passes(self):
        self.progress.set_phase('separating')
        pool = ProgressPool(self.progress, [4, 3], self.clock)

        def inference(value):
            self.clock.advance(2)
            return value * 2

        first = [pool.submit(inference, n) for n in range(3)]
        self.assertEqual(self.progress.done, 0)  # no work during submission
        self.assertEqual([f.result() for f in first], [0, 2, 4])
        self.assertEqual(first[0].result(), 0)  # repeated result must not count twice
        self.assertEqual(self.progress.done, 3)
        second = [pool.submit(inference, n) for n in range(2)]
        self.assertEqual([f.result() for f in second], [0, 2])
        self.assertEqual((self.progress.done, self.progress.total), (5, 5))
        self.assertLess(self.progress.snapshot()['Percent'], 100)

    def test_queue_wait_includes_active_job_and_preceding_jobs(self):
        self.history.record(self.sample())
        estimates = queue_estimates([180, 360], self.history, active_remaining=25, cold=False)
        self.assertEqual(estimates[0]['EstimatedWaitSeconds'], 25)
        self.assertEqual(estimates[1]['EstimatedWaitSeconds'], 25 + estimates[0]['EstimatedProcessingSeconds'])
        self.assertEqual(estimates[1]['QueuePosition'], 2)
        unknown = queue_estimates([180, 360], self.history, active_remaining=None, cold=False)
        self.assertEqual(unknown[0]['EstimatedWaitSeconds'], -1)
        self.assertGreater(unknown[0]['EstimatedProcessingSeconds'], 0)

    def test_failed_and_restarted_jobs_do_not_fake_completion(self):
        self.progress.set_phase('separating')
        self.progress.set_chunks(10)
        self.clock.advance(3)
        self.progress.chunk_done(3)
        self.progress.finish('failed', Error='failure')
        saved = read_ini(self.progress.status)['Job']
        self.assertEqual(saved['Stage'], 'failed')
        self.assertNotEqual(saved['Percent'], '100')
        self.assertEqual(self.history.samples(), [])
        restarted = JobProgress(self.progress.status, self.history, write_status, cold=True,
                                clock=self.clock, wall_clock=self.clock)
        restarted.publish()
        self.assertEqual(read_ini(self.progress.status)['Job']['ChunksDone'], '0')

    def test_broken_history_falls_back_and_history_is_bounded(self):
        self.history.path.write_text('invalid JSON')
        recovered = TimingHistory(self.history.path, 'test-profile', atomic_write)
        self.assertGreater(recovered.estimate(180, True)['separating'], 0)
        for _ in range(35):
            recovered.record(self.sample())
        self.assertEqual(len(recovered.samples()), 30)
        self.assertEqual(json.loads(recovered.path.read_text())['version'], 1)

    def test_missing_hardware_utility_does_not_block_worker(self):
        with patch('estimates.platform.system', return_value='Darwin'), patch('estimates.platform.processor', return_value='arm'), patch('estimates.subprocess.run', side_effect=FileNotFoundError):
            profile = json.loads(profile_key('htdemucs', 2))
        self.assertEqual(profile['cpu'], 'arm')
        self.assertEqual(profile['threads'], 2)


if __name__ == '__main__':
    unittest.main()
