"""Prints timestamped output at high volume to test flow control.

Produces ~2.7MB/s of output. When run through ET with a slow network,
the displayed timestamps should lag behind real time if flow control
is not working properly.

Also writes timestamps to a sidecar file so you can check whether the
process itself is stalled (backpressure mode) vs running freely (discard
mode).
"""
import os
import sys
from datetime import datetime
import time

sidecar = os.environ.get("SIDECAR_FILE", "")
while True:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")
    print((ts + "\n") * 1000)
    if sidecar:
        with open(sidecar, "w") as f:
            f.write(ts + "\n")
    time.sleep(0.01)
