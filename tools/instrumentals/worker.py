"""Process the USDX song menu's durable, per-user instrumental queue.

Only this worker runs the separation model. The game exchanges small INI files
with it, so inference never runs on the game's rendering/audio thread.
"""

from __future__ import annotations

import argparse
import configparser
import concurrent.futures
import hashlib
import io
import json
import logging
import math
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from estimates import JobProgress, ProgressPool, TimingHistory, profile_key, queue_estimates

LOG = logging.getLogger("instrumentals")
MODEL = "htdemucs"


def fingerprint(path: Path) -> tuple[int, int]:
    stat = path.stat()
    return stat.st_size, stat.st_mtime_ns


def job_id(chart: Path) -> str:
    return hashlib.md5(str(chart.absolute()).encode("utf-8")).hexdigest()


def read_ini(path: Path) -> configparser.ConfigParser:
    config = configparser.ConfigParser(interpolation=None)
    config.read(path, encoding="utf-8-sig")
    return config


def atomic_write(path: Path, data: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as file:
            file.write(data)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def write_status(path: Path, stage: str, **values: object) -> None:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    config["Job"] = {"Stage": stage, **{k: str(v).replace("\n", " ") for k, v in values.items()}}
    output = io.StringIO()
    config.write(output)
    atomic_write(path, output.getvalue().encode("utf-8"))


def update_chart(data: bytes, instrumental: str, vocals: str) -> bytes:
    """Keep the chart's encoding, note data and timing intact."""
    declared = re.search(rb"(?im)^#ENCODING:([^\r\n]+)", data)
    if data.startswith(b"\xef\xbb\xbf"):
        encoding = "utf-8-sig"
    elif declared:
        encoding = declared.group(1).decode("ascii").strip()
    else:
        try:
            data.decode("utf-8")
            encoding = "utf-8"
        except UnicodeDecodeError:
            encoding = "cp1252"
    text = data.decode(encoding)
    newline = "\r\n" if "\r\n" in text else "\n"
    lines = text.splitlines(keepends=True)
    # Preserve any existing instrumental supplied by the user/chart author.
    if any(line.upper().startswith("#INSTRUMENTAL:") for line in lines):
        raise ValueError("The chart already has an INSTRUMENTAL tag; its existing track was preserved.")
    additions = [f"#INSTRUMENTAL:{instrumental}{newline}"]
    if not any(line.upper().startswith("#VOCALS:") for line in lines):
        additions.append(f"#VOCALS:{vocals}{newline}")
    index = next((i for i, line in enumerate(lines) if not line.startswith("#")), len(lines))
    lines[index:index] = additions
    return "".join(lines).encode(encoding)


def duration(path: Path) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def ffmpeg_progress(arguments: list[str], seconds: float, report) -> None:
    """Consume FFmpeg's structured progress while keeping stderr out of the pipe."""
    with tempfile.TemporaryFile(mode="w+b") as errors:
        with subprocess.Popen(
            ["ffmpeg", "-v", "error", "-nostdin", "-y", "-progress", "pipe:1", "-nostats", *arguments],
            stdout=subprocess.PIPE, stderr=errors, text=True,
        ) as process:
            for line in process.stdout:
                key, _, value = line.strip().partition("=")
                if key == "out_time_us" and value.lstrip("-").isdigit() and seconds > 0:
                    report(min(1.0, max(0.0, int(value) / 1_000_000 / seconds)))
            if process.wait() != 0:
                errors.seek(0)
                raise RuntimeError(errors.read().decode("utf-8", errors="replace")[-2000:])
    report(1.0)


class Separator:
    def __init__(self, threads: int = 2):
        self.threads = threads
        self.model = None

    def split(self, audio: Path, output: Path, progress: JobProgress) -> tuple[Path, Path]:
        progress.set_phase("preparing")
        import soundfile as sf
        import torch
        from demucs.apply import apply_model
        from demucs.pretrained import get_model

        torch.set_num_threads(self.threads)
        if self.model is None:
            LOG.info("Loading %s (first run downloads model weights)", MODEL)
            self.model = get_model(MODEL).cpu().eval()
        model = self.model
        progress.set_phase("reading")
        decoded = output / "input.wav"
        ffmpeg_progress(
            ["-i", str(audio),
             "-ac", str(model.audio_channels), "-ar", str(model.samplerate),
             "-c:a", "pcm_f32le", str(decoded)], progress.audio, progress.fraction_done,
        )
        samples, sample_rate = sf.read(decoded, dtype="float32", always_2d=True)
        wave = torch.from_numpy(samples.T.copy())
        reference = wave.mean(0)
        mean, std = reference.mean(), reference.std().clamp_min(1e-8)
        models = list(model.models) if hasattr(model, "models") else [model]
        # The single random-shift pass may add up to half a second. ProgressPool
        # replaces this upper-bound estimate with each pass's actual submissions.
        pass_totals = [math.ceil((wave.shape[-1] + int(0.5 * m.samplerate)) /
                                int(0.75 * int(m.samplerate * m.segment))) for m in models]
        progress.set_phase("separating")
        pool = ProgressPool(progress, pass_totals)
        with torch.inference_mode():
            stems = apply_model(
                model, ((wave - mean) / std)[None], device="cpu",
                shifts=1, split=True, overlap=0.25, progress=False, num_workers=0,
                pool=pool,
            )[0] * std + mean
        progress.set_phase("encoding")
        vocal_index = model.sources.index("vocals")
        instrumental = sum(stems[i] for i in range(len(model.sources)) if i != vocal_index)
        outputs = []
        for index, (name, data) in enumerate((("vocals", stems[vocal_index]), ("instrumental", instrumental))):
            wav = output / f"{name}.wav"
            dest = output / f"{name}.m4a"
            sf.write(wav, data.numpy().T, sample_rate, subtype="FLOAT")
            ffmpeg_progress(
                ["-i", str(wav), "-c:a", "aac", "-b:a", "256k", str(dest)],
                progress.audio, lambda fraction: progress.fraction_done((index + fraction) / 2),
            )
            outputs.append(dest)
        return outputs[0], outputs[1]


def synchronize_usdb(chart: Path, instrumental: Path, vocals: Path | None) -> None:
    """Let Syncer discover generated resources on its next local rescan."""
    for path in chart.parent.glob("*.usdb"):
        try:
            before = fingerprint(path)
            meta = json.loads(path.read_text(encoding="utf-8"))
            if meta.get("txt", {}).get("fname") != chart.name:
                continue
            resources = [("instrumental", instrumental)]
            if vocals is not None:
                resources.append(("vocals", vocals))
            for kind, file in resources:
                meta[kind] = {
                    "fname": file.name, "mtime": file.stat().st_mtime_ns // 1000,
                    "resource": meta.get("audio", {}).get("resource"), "status": "success",
                }
            meta["txt"]["mtime"] = chart.stat().st_mtime_ns // 1000
            if fingerprint(path) != before:
                raise ValueError("Syncer metadata changed while updating it")
            atomic_write(path, (json.dumps(meta, indent=4) + "\n").encode("utf-8"))
        except (OSError, ValueError, TypeError) as error:
            LOG.warning("Could not update Syncer metadata %s: %s", path, error)


def process_job(request: Path, separator: Separator, progress: JobProgress | None = None) -> None:
    status = request.with_suffix(".status")
    started = time.monotonic()
    if progress is None:
        history = TimingHistory(request.parent / "timings.json", profile_key(MODEL, separator.threads), atomic_write)
        progress = JobProgress(status, history, write_status, cold=separator.model is None)
    published: list[Path] = []
    chart_committed = False
    try:
        job = read_ini(request)["Song"]
        chart, audio = Path(job["Chart"]), Path(job["Audio"])
        if not chart.is_absolute() or not audio.is_absolute() or not chart.is_file() or not audio.is_file():
            raise ValueError("The song chart or audio file is missing")
        chart_before, audio_before = fingerprint(chart), fingerprint(audio)
        contents = chart.read_bytes()
        has_vocals = bool(re.search(rb"(?im)^#VOCALS:", contents.removeprefix(b"\xef\xbb\xbf")))
        instrumental = chart.with_name(audio.stem + " [INSTR].m4a")
        vocals = chart.with_name(audio.stem + " [VOC].m4a")
        updated = update_chart(contents, instrumental.name, vocals.name)
        if instrumental.exists() or vocals.exists():
            raise ValueError("Stem files already exist; existing files were preserved")
        original_duration = duration(audio)
        if not math.isfinite(original_duration) or original_duration <= 0:
            raise ValueError("Audio duration is invalid")
        progress.set_audio(original_duration)
        progress.extra.update(Model=MODEL, Chart=chart)
        progress.publish()
        LOG.info("Separating %s", chart.name)
        with tempfile.TemporaryDirectory(prefix="usdx-stems-") as temp:
            separated_vocals, separated_instrumental = separator.split(audio, Path(temp), progress)
            progress.set_phase("saving")
            for output in (separated_vocals, separated_instrumental):
                if abs(duration(output) - original_duration) > 0.15:
                    raise ValueError("Separated audio duration does not match the original")
            if fingerprint(chart) != chart_before or fingerprint(audio) != audio_before:
                raise ValueError("The song changed during processing; retry with the updated song")
            # Stage in the destination filesystem, then publish each complete file.
            for source, target in ((separated_vocals, vocals), (separated_instrumental, instrumental)):
                fd, name = tempfile.mkstemp(prefix=".usdx-stem-", dir=chart.parent)
                os.close(fd)
                try:
                    shutil.copyfile(source, name)
                    os.replace(name, target)
                    published.append(target)
                finally:
                    Path(name).unlink(missing_ok=True)
            atomic_write(chart, updated)
            chart_committed = True
        synchronize_usdb(chart, instrumental, None if has_vocals else vocals)
        elapsed = round(time.monotonic() - started, 1)
        progress.finish("ready", Instrumental=instrumental.name, Vocals="" if has_vocals else vocals.name,
                        Seconds=elapsed, Model=MODEL, Chart=chart)
        request.unlink(missing_ok=True)
        try:
            progress.record()
        except OSError:
            LOG.exception("Could not save timing history")
        LOG.info("Ready: %s in %.1f seconds", chart.name, elapsed)
    except Exception as error:
        LOG.exception("Instrumental generation failed for %s", request)
        if not chart_committed:
            for path in published:
                path.unlink(missing_ok=True)
        progress.finish("failed", Error=error)
        if request.exists():
            request.replace(request.with_suffix(".failed"))


def run(queue: Path, threads: int) -> None:
    import fcntl

    queue.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (queue / ".worker.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        stopping = False

        def stop(*_):
            nonlocal stopping
            stopping = True

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        separator = Separator(threads)
        history = TimingHistory(queue / "timings.json", profile_key(MODEL, threads), atomic_write)
        # Cache probes: keep the coordinator responsive even for a large queue.
        durations: dict[Path, tuple[tuple[int, int], float | None]] = {}
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = None
            active = None
            active_request = None
            while not stopping:
                atomic_write(queue / "heartbeat", b"ready\n")
                if future is None or future.done():
                    if future is not None:
                        future.result()
                    active = active_request = future = None
                    requests = pending_requests(queue)
                    if requests:
                        active_request = requests[0]
                        active = JobProgress(active_request.with_suffix(".status"), history, write_status,
                                             cold=separator.model is None)
                        active.publish()
                        future = pool.submit(process_job, active_request, separator, active)
                requests = pending_requests(queue)
                waiting = [p for p in requests if p != active_request]
                probes = 0
                for request in waiting:
                    stamp = fingerprint(request)
                    if request in durations and durations[request][0] == stamp:
                        continue
                    if probes >= 2:
                        break
                    try:
                        value = duration(Path(read_ini(request)["Song"]["Audio"]))
                        if not math.isfinite(value) or value <= 0:
                            value = None
                    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                        value = None
                    durations[request] = (stamp, value)
                    probes += 1
                if active is not None:
                    with active.lock:
                        active.waiting = len(waiting)
                        active.publish()
                estimates = queue_estimates(
                    [durations.get(p, (None, None))[1] for p in waiting], history,
                    active.remaining() if active else 0, cold=active is None and separator.model is None,
                )
                for request, estimate in zip(waiting, estimates):
                    write_status(request.with_suffix(".status"), "queued", Percent=-1,
                                 ElapsedSeconds=0, UpdatedAt=int(time.time()), **estimate)
                durations = {p: value for p, value in durations.items() if p in waiting}
                time.sleep(1)
        (queue / "heartbeat").unlink(missing_ok=True)


def pending_requests(queue: Path) -> list[Path]:
    requests = []
    for path in queue.glob("*.job"):
        try:
            requests.append((path.stat().st_mtime_ns, path.name, path))
        except FileNotFoundError:
            pass  # A completed job can disappear while the coordinator lists it.
    return [p for _, _, p in sorted(requests)]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    run(args.queue, args.threads)
