# Search USDB from UltraStar Deluxe

Press **U** from the main menu or song selection, or choose **M → Search USDB**
from the song menu. Type an artist, title, genre, or USDB ID. The results show six
tracks per page, with Previous/Next controls and each song's download state.

Click a result or press Enter to request its download. Syncer queues it using your
existing login and download preferences. Requests continue being submitted if you
close the search window. Once a song is downloaded, select it again to open it in
the game's local song selection; the incremental catalog refresh loads it.

The search window is available during normal/free song selection. Finish a medley
selection before opening the online catalog.

## Setup on this Mac

```sh
python3 tools/usdb-browser/install_macos.py
make macos-standalone-app
```

Restart **USDB Syncer** and **UltraStar Deluxe** once. Leave Syncer running and
sign in through **USDB → USDB Login** there. Use **USDB → Check USDB Song List**
in Syncer to refresh the catalog if needed.

The add-on is tested with USDB Syncer 0.25.0. It serves the catalog over a
token-authenticated loopback connection, sharing Syncer's normal download manager.
The game makes its requests on a separate thread, with debounced search and
two-second status refreshes. The native connection does not depend on the web
request page's network address.

Connection information is automatically published to
`~/Library/Application Support/UltraStar Deluxe/usdb-bridge.ini`. The add-on and
game support `USDX_USDB_BRIDGE` for a custom location. On another platform, put
`usdx_catalog.py` in Syncer's add-ons directory and ensure the bridge path matches
your USDX user-data directory.

## Tests

```sh
uv run --no-project --python 3.12 --with usdb_syncer==0.25.0 \
  python -m unittest discover -s tools/usdb-browser -p 'test_*.py'
make test-usdb-client
```
