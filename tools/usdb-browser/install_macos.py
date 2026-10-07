"""Install the native-catalog add-on into the user's USDB Syncer."""

from pathlib import Path
import sys

if sys.platform != 'darwin':
    raise SystemExit('See README.md for manual installation on other platforms.')
source = Path(__file__).resolve().with_name('usdx_catalog.py')
target = Path.home() / 'Library/Application Support/usdb_syncer/addons/usdx_catalog.py'
target.parent.mkdir(parents=True, exist_ok=True)
if target.is_symlink() and target.resolve() == source:
    print('Catalog add-on is already installed.')
elif target.exists() or target.is_symlink():
    raise SystemExit(f'A different file exists at {target}; leaving it intact.')
else:
    target.symlink_to(source)
    print(f'Installed {target}')
print('Restart USDB Syncer to enable the native catalog connection.')
