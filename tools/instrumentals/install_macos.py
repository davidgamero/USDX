"""Install the on-demand worker as a per-user macOS background service."""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

if sys.platform != "darwin":
    raise SystemExit("This installer is for macOS. See README.md for manual startup.")

project = Path(__file__).resolve().parent
python = project / ".venv/bin/python"
if not python.exists():
    raise SystemExit("Run uv sync --project tools/instrumentals first.")

queue = Path.home() / "Library/Application Support/UltraStar Deluxe/instrumentals"
queue.mkdir(parents=True, exist_ok=True, mode=0o700)
(queue / "work").mkdir(exist_ok=True)
label = "com.davidgamero.usdx.instrumentals"
agents = Path.home() / "Library/LaunchAgents"
agents.mkdir(exist_ok=True)
plist = agents / f"{label}.plist"
command = [str(python), str(project / "worker.py"), "--queue", str(queue), "--threads", "2"]
old = None
if plist.exists():
    old = plistlib.loads(plist.read_bytes())
    if old.get("ProgramArguments", [])[:2] != command[:2]:
        raise SystemExit(f"An existing different service is defined in {plist}; leaving it intact.")

config = {
    "Label": label,
    "ProgramArguments": command,
    "RunAtLoad": True,
    "KeepAlive": True,
    "ProcessType": "Interactive",
    "Nice": 0,
    "LowPriorityIO": False,
    "EnvironmentVariables": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "TORCH_HOME": str(queue / "models"),
        "TMPDIR": str(queue / "work"),
        "PYTHONUNBUFFERED": "1",
    },
    "StandardOutPath": str(queue / "worker.log"),
    "StandardErrorPath": str(queue / "worker.log"),
}
domain = f"gui/{os.getuid()}"
service = f"{domain}/{label}"
loaded = subprocess.run(["launchctl", "print", service], capture_output=True).returncode == 0
plist.write_bytes(plistlib.dumps(config))
if loaded and old == config:
    subprocess.run(["launchctl", "kickstart", "-k", service], check=True)
else:
    if loaded:
        subprocess.run(["launchctl", "bootout", service], check=True, capture_output=True)
    # launchd may finish removing an old service asynchronously after bootout.
    for attempt in range(60):
        result = subprocess.run(["launchctl", "bootstrap", domain, str(plist)], capture_output=True, text=True)
        if result.returncode == 0:
            break
        if attempt == 59:
            raise SystemExit(result.stderr.strip())
        time.sleep(0.5)
print(f"Installed {label}")
print(f"Queue and log: {queue}")
