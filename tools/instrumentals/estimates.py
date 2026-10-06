"""Chunk-based progress and local timing estimates, independent of PyTorch."""

from __future__ import annotations

import json
import math
import os
import platform
from pathlib import Path
import statistics
import subprocess
import threading
import time

from scheduling import PRIORITY_PROFILE

PHASES = ("preparing", "reading", "separating", "encoding", "saving")
WEIGHTS = {"preparing": (0, 3), "reading": (3, 2), "separating": (5, 90), "encoding": (95, 4), "saving": (99, 0)}


def profile_key(model: str, threads: int) -> str:
    cpu = platform.processor()
    if platform.system() == "Darwin":
        try:
            result = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
                                    capture_output=True, text=True, timeout=5)
            cpu = result.stdout.strip() or cpu
        except (OSError, subprocess.SubprocessError):
            pass  # Hardware identification must not prevent worker startup.
    return json.dumps({"model": model, "device": "cpu", "threads": threads,
                       "scheduling": PRIORITY_PROFILE,
                       "shifts": 1, "overlap": 0.25, "demucs": "4.0.1", "torch": "2.5.1",
                       "os": platform.system(), "arch": platform.machine(),
                       "cpu": cpu, "logical_cpus": os.cpu_count()}, sort_keys=True)


class TimingHistory:
    def __init__(self, path: Path, profile: str, atomic_write):
        self.path, self.profile, self.atomic_write = path, profile, atomic_write
        self.lock = threading.RLock()
        try:
            data = json.loads(path.read_text())
            self.profiles = data["profiles"] if data.get("version") == 1 else {}
            if not isinstance(self.profiles, dict):
                self.profiles = {}
        except (OSError, ValueError, KeyError, TypeError):
            self.profiles = {}

    def samples(self) -> list[dict]:
        with self.lock:
            samples = self.profiles.get(self.profile, [])
            if not isinstance(samples, list):
                return []
            return [s for s in samples
                    if isinstance(s, dict) and isinstance(s.get("audio"), (int, float)) and s["audio"] > 0]

    def estimate(self, audio: float, cold: bool) -> dict[str, float]:
        # Conservative starting rates based on the initial local Elvis benchmark.
        rates = {"reading": 0.005, "separating": 0.50, "encoding": 0.04}
        samples = self.samples()
        result = {}
        for phase, default in rates.items():
            values = [s[phase] / s["audio"] for s in samples
                      if isinstance(s.get(phase), (int, float)) and math.isfinite(s[phase]) and s[phase] > 0]
            result[phase] = max(0.1, audio * (statistics.median(values) if values else default))
        for phase, default in (("preparing", 15.0 if cold else 0.1), ("saving", 1.0)):
            values = [s[phase] for s in samples
                      if isinstance(s.get(phase), (int, float)) and math.isfinite(s[phase]) and s[phase] > 0
                      and (phase != "preparing" or s.get("cold") == cold)]
            result[phase] = statistics.median(values) if values else default
        return result

    def chunk_rate(self) -> float | None:
        values = [s["chunk_rate"] for s in self.samples()
                  if isinstance(s.get("chunk_rate"), (int, float)) and math.isfinite(s["chunk_rate"]) and s["chunk_rate"] > 0]
        return statistics.median(values) if values else None

    def record(self, sample: dict) -> None:
        if sample.get("audio", 0) <= 0 or sample.get("chunks", 0) <= 0:
            return
        with self.lock:
            samples = self.samples()
            samples.append(sample)
            self.profiles[self.profile] = samples[-30:]
            self.atomic_write(self.path, (json.dumps({"version": 1, "profiles": self.profiles}, indent=2) + "\n").encode())


class JobProgress:
    def __init__(self, status: Path, history: TimingHistory, writer, cold: bool,
                 clock=time.monotonic, wall_clock=time.time):
        self.status, self.history, self.writer, self.cold = status, history, writer, cold
        self.clock, self.wall_clock = clock, wall_clock
        self.lock = threading.RLock()
        self.started = self.phase_started = self.last_progress = clock()
        self.phase = "preparing"
        self.audio = 0.0
        self.fraction = 0.0
        self.done = self.total = 0
        self.rate = history.chunk_rate()
        self.observations = 0
        self.max_percent = 0
        self.phase_times = {p: 0.0 for p in PHASES}
        self.extra: dict = {}
        self.waiting = 0

    def set_audio(self, seconds: float) -> None:
        with self.lock:
            self.audio = seconds

    def set_phase(self, phase: str) -> None:
        with self.lock:
            now = self.clock()
            if self.phase in PHASES:
                self.phase_times[self.phase] += now - self.phase_started
            self.phase, self.phase_started, self.last_progress = phase, now, now
            self.fraction = 0.0
            self.publish()

    def fraction_done(self, fraction: float) -> None:
        with self.lock:
            fraction = max(0.0, min(1.0, fraction))
            if fraction > self.fraction:
                self.fraction = fraction
                self.last_progress = self.clock()
            self.publish()

    def set_chunks(self, total: int) -> None:
        with self.lock:
            self.total = max(self.done, total)

    def chunk_done(self, seconds: float) -> None:
        with self.lock:
            self.done += 1
            self.observations += 1
            # Initial forward pass can include one-time runtime warmup.
            if self.observations > 1:
                self.rate = seconds if self.rate is None else self.rate * 0.75 + seconds * 0.25
            self.last_progress = self.clock()
            self.fraction = min(1.0, self.done / max(1, self.total))
            self.publish()

    def remaining(self) -> float | None:
        with self.lock:
            if self.phase == "ready":
                return 0.0
            if self.phase not in PHASES or self.audio <= 0:
                return None
            estimates = self.history.estimate(self.audio, self.cold)
            later = PHASES[PHASES.index(self.phase) + 1:]
            tail = sum(estimates[p] for p in later)
            elapsed = self.clock() - self.phase_started
            if self.phase == "separating":
                if self.rate is None or (self.observations < 3 and not self.history.chunk_rate()):
                    return None
                in_chunk = self.clock() - self.last_progress
                return max(1.0, (self.total - self.done) * self.rate - in_chunk) + tail
            if self.phase == "preparing" and not self.history.samples():
                return None
            if self.fraction > 0:
                return max(0.0, elapsed * (1 - self.fraction) / self.fraction) + tail
            return max(1.0, estimates[self.phase] - elapsed) + tail

    def snapshot(self) -> dict:
        with self.lock:
            eta = self.remaining()
            percent = -1
            if self.phase in WEIGHTS and self.phase != "preparing":
                start, weight = WEIGHTS[self.phase]
                self.max_percent = max(self.max_percent, min(99, int(start + weight * self.fraction)))
                percent = self.max_percent
            elif self.phase == "ready":
                percent = 100
            timeout = 300 if self.phase == "preparing" else max(60, int((self.rate or 12) * 5))
            return {"Stage": self.phase, "Percent": percent,
                    "ElapsedSeconds": int(self.clock() - self.started),
                    "EstimatedRemainingSeconds": -1 if eta is None else math.ceil(eta),
                    "ChunksDone": self.done, "ChunksTotal": self.total,
                    "JobsWaiting": self.waiting, "QueuePosition": 0,
                    "UpdatedAt": int(self.wall_clock()),
                    "ProgressAgeSeconds": int(self.clock() - self.last_progress),
                    "ProgressTimeoutSeconds": timeout,
                    "Confidence": "learning" if len(self.history.samples()) < 3 and self.observations < 3 else "measured",
                    **self.extra}

    def publish(self) -> None:
        with self.lock:
            values = self.snapshot()
            stage = values.pop("Stage")
            self.writer(self.status, stage, **values)

    def finish(self, stage: str, **extra) -> None:
        with self.lock:
            self.extra.update(extra)
            self.set_phase(stage)

    def record(self) -> None:
        with self.lock:
            sample = {**self.phase_times, "audio": self.audio, "cold": self.cold,
                      "chunks": self.done, "chunk_rate": self.rate, "at": int(self.wall_clock())}
            self.history.record(sample)


class ProgressPool:
    """Demucs-compatible lazy pool: measure actual chunk inference completions.

    Demucs submits a whole pass before resolving its futures. This lets us replace
    the planned chunk count with the actual count before the first completion.
    """

    def __init__(self, progress: JobProgress, pass_totals: list[int], clock=time.monotonic):
        self.progress, self.pass_totals, self.clock = progress, list(pass_totals), clock
        self.pass_index = 0
        self.submitted = self.completed = 0
        progress.set_chunks(sum(pass_totals))

    def submit(self, function, *args, **kwargs):
        if self.submitted and self.completed == self.submitted:
            self.pass_index += 1
            self.submitted = self.completed = 0
        if self.pass_index >= len(self.pass_totals):
            raise RuntimeError("Demucs produced an unexpected additional inference pass")
        self.submitted += 1
        pool = self

        class ChunkResult:
            complete = False
            value = None

            def result(self):
                if not self.complete:
                    pool.pass_totals[pool.pass_index] = pool.submitted
                    pool.progress.set_chunks(sum(pool.pass_totals))
                    started = pool.clock()
                    self.value = function(*args, **kwargs)
                    self.complete = True
                    pool.completed += 1
                    pool.progress.chunk_done(pool.clock() - started)
                return self.value

        return ChunkResult()


def queue_estimates(durations: list[float | None], history: TimingHistory,
                    active_remaining: float | None, cold: bool) -> list[dict]:
    """None active_remaining means an active job has not calibrated its ETA yet."""
    wait = active_remaining
    results = []
    for index, audio in enumerate(durations):
        processing = sum(history.estimate(audio, cold and index == 0).values()) if audio is not None else None
        results.append({"QueuePosition": index + 1, "JobsWaiting": len(durations),
                        "EstimatedWaitSeconds": -1 if wait is None else math.ceil(wait),
                        "EstimatedProcessingSeconds": -1 if processing is None else math.ceil(processing),
                        "Confidence": "measured" if len(history.samples()) >= 3 else "learning"})
        wait = wait + processing if wait is not None and processing is not None else None
    return results
