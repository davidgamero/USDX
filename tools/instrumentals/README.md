# Make instrumental in UltraStar Deluxe

Select a song in USDX, press **M**, and choose **Make instrumental**. The menu
shows queued/processing status and then **Use instrumental**. Selecting it sets
the vocal balance to zero and restarts the preview with the instrumental. Select
**Use original vocals** to switch back, or press **K** while singing. The vocal
balance setting applies to other songs that have an instrumental as well.

The optional Python worker performs Demucs separation outside the game process,
one song at a time, with two CPU threads. The first request downloads the
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
