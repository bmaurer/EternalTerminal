# ET Flow Control: E2E Test Report

## Problem Statement (Issue #631)

When a process inside an ET session produces output faster than the network can
deliver it, ET has no mechanism to manage the mismatch. The result:

1. The terminal display falls progressively behind real time
2. Ctrl-C is delayed because stale data must drain before the interrupt is seen
3. In the worst case (laptop disconnect, wifi drop), long-running jobs freeze
   entirely because the PTY kernel buffer fills up and `write()` blocks

## Test Setup

```
print_timestamps.py ──> PTY ──> etterminal ──> etserver ──[TCP]──> throttle_proxy ──[TCP]──> et client ──> terminal
                                                           100KB/s
```

All components run on a single machine via `--idpasskey` (no SSH). A userspace
TCP throttle proxy between etserver and the et client limits the server-to-client
throughput to 100KB/s. This creates the same conditions as a slow WAN link: the
ET server produces data far faster than the client can consume it.

**Workload**: `print_timestamps.py` prints 1000 timestamped lines in a burst
every 10ms (~2.7MB/s raw output — 27x the proxy's capacity).

**Two metrics are measured every 10 seconds for 30 seconds:**

- **display_lag**: The difference between the timestamp currently visible on the
  client's terminal and the actual wall clock time. This tells you how stale the
  information on your screen is.

- **process_lag**: The difference between the timestamp the producing process
  most recently wrote (to a sidecar file that bypasses ET) and wall clock time.
  If near zero, the process is running freely. If large, the process is blocked
  on `write()` to its stdout — it has been stalled by backpressure from the
  terminal pipeline.

## Raw Results

```
                 disp@10s   disp@20s   disp@30s    proc@10s     proc@20s     proc@30s     etserver
TRUNK            9.6s       19.8s      29.6s       1.0s STALL   0.7s         0.0s         alive
BACKPRESSURE     9.6s       19.4s      29.3s       2.0s STALL   0.0s         0.9s         alive
DISCARD          9.6s       19.5s      29.2s       0.0s run     0.0s run     0.0s run     alive
```

## Interpretation

### Display lag grows at ~1s/s in all three modes

All three modes show display lag growing linearly at approximately 1 second of
lag per second of wall time. After 30 seconds, the terminal is showing data that
is ~29 seconds old.

This is expected and unavoidable given the test setup. The proxy limits
server-to-client throughput to 100KB/s, but the workload produces ~2.7MB/s. The
excess data queues in the TCP kernel send buffer on the server side. TCP is
an ordered, reliable stream — data that has entered the kernel buffer cannot be
"skipped" or "un-sent." It must be delivered in order, at whatever rate the
proxy allows.

Since all three modes send data into the same TCP socket (with the same kernel
buffer size), the display lag is nearly identical. **Display lag is a property
of the network bottleneck, not of ET's flow control.** No amount of
application-level buffering can reduce it once data is in the kernel.

### Process lag is where the modes differ

The critical difference is in **process_lag** — whether `print_timestamps.py`
is running freely or frozen:

**Trunk (no flow control)**: The server reads from the PTY and immediately calls
`writePacket()`. When the TCP send buffer fills, `writePacket()` blocks. While
blocked, the server cannot read from the PTY. The PTY's 4KB kernel buffer fills
up. `print_timestamps.py`'s `write()` call blocks. The process stalls.

At t=10s, process_lag = 1.0s (STALLED). The process is running about 1 second
behind real time — it is intermittently blocking on stdout writes. At t=20s and
t=30s, the process recovers somewhat (0.7s, 0.0s) as the TCP buffer drain rate
and the PTY production rate reach an equilibrium. But the process was stalled,
and on a real network with variable latency, these stalls would be unpredictable
and potentially much longer.

**Backpressure mode**: The server uses a 256KB WriteBuffer between the PTY read
and the TCP socket write. This absorbs short bursts of data, but when the buffer
fills, the server stops reading from the PTY — same stalling behavior as trunk,
just deferred by 256KB. At t=10s, process_lag = 2.0s (STALLED) — actually worse
than trunk because the 256KB buffer takes time to fill before backpressure kicks
in, during which more data queues up.

The advantage of backpressure mode over trunk: **all data is preserved.** Nothing
is lost. The process runs slower, but every byte it writes eventually reaches the
client. This matters for applications where output correctness is critical (e.g.,
`tmux -CC` control mode, where dropped bytes would corrupt the client's state).

**Discard mode**: The server uses a 256KB WriteBuffer, but instead of blocking
when full, it drops the oldest data and keeps reading from the PTY. The PTY
buffer never fills up. `print_timestamps.py` never blocks.

At t=10s, t=20s, and t=30s: process_lag = 0.0s. The process runs at full speed
the entire time. It has no idea the downstream is slow. This is exactly the
behavior you want for a long-running job (ML training, builds, data processing)
that should keep making progress regardless of terminal speed.

The trade-off: old output is lost. If you scroll up in the terminal after the
network catches up, some output will be missing. For most interactive use cases,
this is acceptable — you care about what's happening *now*, not what happened
30 seconds ago.

### Server stability

In the trunk codebase, etserver crashes with `EINVAL` from `select()` when the
client disconnects during a write drain loop. The `waitOnSocketWritable()` helper
calls `FD_SET` on a closed fd, which `select()` rejects. This crash was fixed in
the test harness commit by handling `EBADF` and `EINVAL` the same way as `EINTR`
(return false, let the caller stop draining).

Both backpressure and discard modes inherit this fix and survive client
disconnection.

## What this means for real-world use

### Scenario: ML training job

You start a training job inside ET, then close your laptop. With trunk or
backpressure mode, the training job freezes once the PTY buffer fills (~4KB of
output). It stays frozen until you reconnect. With discard mode, the training
job keeps running. When you reconnect, you see recent output — the hours of
intermediate output were discarded, which is fine because you only care about
current loss values.

### Scenario: Build output

You kick off a large build that produces megabytes of compiler output. Your
wifi drops. With backpressure mode, the build pauses within seconds. With
discard mode, the build continues unimpeded.

### Scenario: tmux -CC

You use ET with tmux in control mode. Here, every byte matters — tmux's client
state must stay in sync with the server. Discard mode would cause state
corruption. Use backpressure mode, which guarantees all data is delivered.

## Reproducing These Results

```bash
# Build
cd /path/to/EternalTerminal/build
cmake -DDISABLE_VCPKG=ON -GNinja .. && ninja -j4

# Record all three scenarios as asciinema .cast files
bash test/e2e/record_all.sh test/e2e/recordings/

# Play a recording
asciinema play test/e2e/recordings/discard.cast

# Or run one scenario interactively
bash test/e2e/do_scenario.sh discard
```

See `test/e2e/README.md` for manual setup and `test/e2e/throttle_proxy.py` for
details on the proxy implementation.
