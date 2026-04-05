#!/bin/bash
# Record one E2E scenario by driving a tmux session.
# The caller records the tmux pane with asciinema.
#
# Usage: bash record_scenario_tmux.sh <mode> <tmux_sock>
#   mode: "trunk" | "backpressure" | "discard"
#
# The script sends commands to the tmux session and waits for output.
# The tmux pane should already exist and be the active pane.
set -e

MODE="$1"
SOCK="$2"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$DIR/build"

send() { tmux -S "$SOCK" send-keys "$1" Enter; }
wait_for() { for i in $(seq 1 60); do tmux -S "$SOCK" capture-pane -p | grep -q "$1" && return 0; sleep 1; done; return 1; }
type_slow() { sleep 0.5; send "$1"; }

case "$MODE" in
    trunk)    COMMIT="1c46dd970"; FC_FLAG="" ;;
    backpressure) COMMIT="b1171286e"; FC_FLAG="--flow-control backpressure" ;;
    discard)  COMMIT="b1171286e"; FC_FLAG="--flow-control discard" ;;
esac

send "echo '=== ET Flow Control Demo: $MODE mode ==='"
sleep 1

# Build
send "echo '--- Step 1: Build from commit $COMMIT ---'"
sleep 0.5
send "cd $DIR && git checkout $COMMIT -- src/ proto/ test/integration_tests/ test/unit_tests/"
sleep 1
[ "$MODE" = "trunk" ] && send "rm -f $DIR/src/base/WriteBuffer.hpp"
sleep 0.5
send "cd $BUILD && cmake -DDISABLE_VCPKG=ON -GNinja .. 2>&1 | tail -1 && ninja -j4 2>&1 | tail -3"
sleep 15  # wait for build

# Services
send "echo '--- Step 2: Start services ---'"
sleep 0.5
ID="Demo$(date +%s | tail -c 9)"
KEY="E2ETestKey123456789012345678901A"
DMXSOCK="/tmp/et_demo_svc_$$.sock"

send "kill -9 \$(lsof -t -i:4444 2>/dev/null) \$(lsof -t -i:4445 2>/dev/null) 2>/dev/null; rm -f /tmp/et_demo.fifo; sleep 1"
sleep 2
send "tmux -S $DMXSOCK new-session -d -s svc -x 200 -y 50"
sleep 1
send "tmux -S $DMXSOCK send-keys '$BUILD/etserver --serverfifo=/tmp/et_demo.fifo --port=4444' Enter"
sleep 5
send "tmux -S $DMXSOCK split-window -v"
sleep 1
send "tmux -S $DMXSOCK send-keys 'python3 $DIR/test/e2e/throttle_proxy.py 4445 4444 100000' Enter"
sleep 3
send "tmux -S $DMXSOCK split-window -v"
sleep 1
send "tmux -S $DMXSOCK send-keys '$BUILD/etterminal --idpasskey=$ID/$KEY --serverfifo=/tmp/et_demo.fifo' Enter"
sleep 5
send "echo 'etserver='\$(lsof -i:4444 2>/dev/null | grep -c LISTEN)' proxy='\$(lsof -i:4445 2>/dev/null | grep -c LISTEN)"
sleep 2

# Connect client
send "echo '--- Step 3: Connect ET client through 100KB/s throttle proxy ---'"
sleep 0.5
send "$BUILD/et --idpasskey='$ID/$KEY' 127.0.0.1:4445 $FC_FLAG"
sleep 10

# Run timestamp test
send "echo '--- Step 4: Running print_timestamps.py ---'"
sleep 0.5
SIDECAR="/tmp/et_demo_sidecar_$$.txt"
send "SIDECAR_FILE=$SIDECAR python3 $DIR/test/e2e/print_timestamps.py"

# Measure lag
sleep 10
for secs in 10 20 30; do
    SCREEN=$(tmux -S "$SOCK" capture-pane -p | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' | tail -1)
    REAL=$(python3 -c "from datetime import datetime; print(datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f'))")
    DLAG="?"
    PLAG="?"
    [ -n "$SCREEN" ] && DLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime('${SCREEN}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')" 2>/dev/null)
    [ -f "$SIDECAR" ] && PLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime(open('$SIDECAR').read().strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')" 2>/dev/null)
    # Print results into the tmux pane (visible in recording)
    # We use a temporary marker approach - just print to our controlling terminal
    echo "  t=${secs}s: display_lag=${DLAG}s  process_lag=${PLAG}s"
    [ "$secs" -lt 30 ] && sleep 10
done

# Ctrl-C
echo ""
echo "--- Sending Ctrl-C ---"
tmux -S "$SOCK" send-keys C-c
sleep 3

echo ""
ES_ALIVE=$(lsof -i:4444 2>/dev/null | grep -c LISTEN || echo 0)
[ "$ES_ALIVE" -gt 0 ] && echo "etserver: alive" || echo "etserver: CRASHED"

# Cleanup
tmux -S "$SOCK" send-keys "exit" Enter
sleep 2
tmux -S "$DMXSOCK" kill-server 2>/dev/null
kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null
rm -f /tmp/et_demo.fifo "$DMXSOCK" "$SIDECAR"

cd "$DIR" && git checkout HEAD -- . 2>/dev/null
