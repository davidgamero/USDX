# Make instrumental in UltraStar Deluxe

Select a song in USDX, press **M**, and choose **Make instrumental**. The menu
shows queued/processing status and then **Use instrumental**. Selecting it sets
the vocal balance to zero and restarts the preview with the instrumental. Select
**Use original vocals** to switch back, or press **K** while singing. The vocal
balance setting applies to other songs that have an instrumental as well.

## Progress and estimates

The song menu includes a progress panel with the current stage, a progress bar,
elapsed time, estimated time remaining, completed/total audio chunks, and queue
length. Queued songs show their queue position, estimated wait, and estimated
conversion time separately. Model preparation (including the first download),
audio reading, separation, encoding, and saving have distinct labels.

Demucs's actual chunk completions drive the separation progress. The estimate
smooths recent chunk timings, excludes the initial inference warmup, and calibrates
after three chunks. FFmpeg reports decoding/encoding progress through its
structured progress stream. The bar uses phase weights (5% preparation/reading,
90% separation, 4% encoding, 1% publication); it only reaches 100% after the tracks
and updated chart have been saved successfully.

Successful jobs update a bounded local `timings.json` history in the worker's
queue directory. Rates are grouped by model, CPU, architecture, operating system,
thread count and separation settings. Cold model preparation is measured separately
from runs with an already loaded model. Estimates are marked as learning until
enough measurements exist and rounded to about five seconds in the UI. Initial
estimates use a rough rate based on the Elvis benchmark below.

The worker publishes status about once per second. Missing/stale worker status or
an unusually long gap without actual progress changes the panel to **Worker not
responding**, suspending the ETA. Pending jobs survive a restart and are measured
again on the new attempt.

The optional Python worker performs Demucs separation outside the game process,
one song at a time, with two CPU threads. On macOS the service uses an interactive
process policy with normal nice priority, and every conversion explicitly requests
user-initiated thread QoS. This avoids macOS throttling a user-requested conversion
as discretionary background work. The first request downloads the
`htdemucs` model. Its idle service does not load the model until a song is queued.
The original recording and pitch/lyric notes are retained. Generated tracks have
matching duration and are linked via `#INSTRUMENTAL` / `#VOCALS` headers.
Quality varies by recording; some vocal remnants or instrumental artifacts can
remain.

Local benchmark: the 3:00 Elvis Presley “Can't Help Falling in Love” recording
completed in 111.7 seconds on an 8-logical-CPU Apple Silicon Mac with 16 GB RAM,
including the first 80 MB model download. Both generated AAC tracks measured
180.698 seconds, matching the source. Other songs and CPU load will vary.

## macOS setup

Install Homebrew FFmpeg and uv, then from the checkout:

```sh
uv sync --project tools/instrumentals
python3 tools/instrumentals/install_macos.py
make macos-standalone-app
```

Restart USDX once to load the new menu. The worker starts at login; pending jobs
survive a game restart. Its log, model cache, and INI queue are in:

`~/Library/Application Support/UltraStar Deluxe/instrumentals/`

Stop the worker with:

```sh
launchctl bootout gui/$(id -u)/com.davidgamero.usdx.instrumentals
```

Remove `~/Library/LaunchAgents/com.davidgamero.usdx.instrumentals.plist` to disable
startup at login. Re-run the installer to enable it again.

## Other Unix systems

Run the worker with your USDX user-data directory's `instrumentals` subdirectory:

```sh
uv run --project tools/instrumentals python tools/instrumentals/worker.py \
  --queue /path/to/usdx-user-data/instrumentals --threads 2
```

The current worker uses a Unix file lock; Windows worker installation is not
implemented. The menu reports an unavailable worker if it is not running.
Set `USDX_INSTRUMENTAL_QUEUE` in the game's environment to use a custom queue
directory matching the worker's `--queue` option.

## Verification

```sh
python3 -m unittest discover -s tools/instrumentals -p 'test_*.py'
```

These tests exercise queue completion/failure, atomic publication, chart encoding,
timing preservation, and protection of existing instrumental tracks without
downloading model weights. Real-audio separation can be requested from the menu.

Estimator tests also cover short tracks, multiple inference passes, changing CPU
speed, queue waits, corrupt/bounded timing history, and restart/failure behavior.
For an opt-in end-to-end test of two real conversions in temporary folders:

```sh
USDX_TEST_AUDIO="/path/to/a/song.m4a" tools/instrumentals/.venv/bin/python \
  -m unittest discover -s tools/instrumentals -p 'test_live_progress.py'
```

This verifies real chunk/ETA updates, queued-job estimates, matching published
tracks, and cold/warm timing history without changing the supplied audio file.
