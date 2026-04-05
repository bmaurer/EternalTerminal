#!/bin/bash
# Record one E2E scenario for asciinema.
# Usage: bash record_scenario.sh <mode> <output.cast>
#   mode: "trunk" | "backpressure" | "discard"
#
# This script is designed to be run INSIDE an asciinema recording.
# It types commands slowly so the recording is readable.
set -e

MODE="$1"
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$DIR/build"
PROXY_RATE=100000  # 100KB/s

# Simulate typing
type_cmd() {
    local cmd="$1"
    echo ""
    for (( i=0; i<${#cmd}; i++ )); do
        printf '%s' "${cmd:$i:1}"
        sleep 0.02
    done
    echo ""
    eval "$cmd"
}

# Styled output
banner() { echo -e "\n\033[1;36m=== $1 ===\033[0m\n"; }
info()   { echo -e "\033[33m$1\033[0m"; }
good()   { echo -e "\033[1;32m$1\033[0m"; }
bad()    { echo -e "\033[1;31m$1\033[0m"; }

banner "ET Flow Control E2E Demo: $MODE mode"

case "$MODE" in
    trunk)
        info "Building from ee8ddc21c + test harness (no flow control)"
        info "The server reads from the PTY and calls writePacket() directly."
        info "No WriteBuffer, no backpressure, no discard."
        COMMIT="1c46dd970"
        FC_FLAG=""
        # Clean stale files that don't exist at this commit
        rm -f "$DIR/src/base/WriteBuffer.hpp"
        ;;
    backpressure)
        info "Building with --flow-control backpressure"
        info "The server uses a 256KB WriteBuffer. When full, it stops reading"
        info "from the PTY. The producing process stalls but data is preserved."
        COMMIT="b1171286e"
        FC_FLAG="--flow-control backpressure"
        ;;
    discard)
        info "Building with --flow-control discard"
        info "The server uses a 256KB WriteBuffer in discard mode. When full,"
        info "old data is dropped. The producing process never stalls."
        COMMIT="b1171286e"
        FC_FLAG="--flow-control discard"
        ;;
    *)
        echo "Usage: $0 <trunk|backpressure|discard>"
        exit 1
        ;;
esac

echo ""

# Step 1: Build
banner "Step 1: Build"
cd "$DIR"
type_cmd "git checkout $COMMIT -- src/ proto/ test/integration_tests/ test/unit_tests/"
cd "$BUILD"
info "(running cmake + ninja -j4...)"
cmake -DDISABLE_VCPKG=ON -GNinja .. 2>&1 | tail -1
ninja -j4 2>&1 | tail -3
type_cmd "$BUILD/et --help 2>&1 | grep -E 'idpasskey|flow-control' || echo '(no flow-control flag)'"

# Step 2: Start services
banner "Step 2: Start etserver + throttle proxy (${PROXY_RATE}B/s) + etterminal"

# Clean up
kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null || true
pkill -9 -f throttle_proxy 2>/dev/null || true
rm -f /tmp/et_demo.fifo
sleep 1

ID="DemoTest$(date +%s | tail -c 9)"
KEY="E2ETestKey123456789012345678901A"

TMUX_SOCK="/tmp/et_demo_$$.sock"
tmux -S "$TMUX_SOCK" new-session -d -s demo -x 200 -y 50

# etserver
tmux -S "$TMUX_SOCK" send-keys "$BUILD/etserver --serverfifo=/tmp/et_demo.fifo --port=4444" Enter
sleep 5

# proxy
tmux -S "$TMUX_SOCK" split-window -v
sleep 1
tmux -S "$TMUX_SOCK" send-keys "python3 $DIR/test/e2e/throttle_proxy.py 4445 4444 $PROXY_RATE" Enter
sleep 3

# etterminal
tmux -S "$TMUX_SOCK" split-window -v
sleep 1
tmux -S "$TMUX_SOCK" send-keys "$BUILD/etterminal --idpasskey='$ID/$KEY' --serverfifo=/tmp/et_demo.fifo" Enter
sleep 5

# Wait for services with retry
for attempt in $(seq 1 10); do
    ES=$(lsof -i:4444 2>/dev/null | grep -c LISTEN)
    PX=$(lsof -i:4445 2>/dev/null | grep -c LISTEN)
    [ "$ES" -ge 1 ] && [ "$PX" -ge 1 ] && break
    sleep 2
done
if [ "$ES" -lt 1 ] || [ "$PX" -lt 1 ]; then
    bad "FAILED to start services: etserver=$ES proxy=$PX"
    tmux -S "$TMUX_SOCK" kill-server 2>/dev/null
    exit 1
fi
good "Services running: etserver on :4444, proxy on :4445"

# Step 3: Connect ET client
banner "Step 3: Connect ET client through throttle proxy"
tmux -S "$TMUX_SOCK" new-window -n et
tmux -S "$TMUX_SOCK" send-keys -t demo:et "$BUILD/et --idpasskey='$ID/$KEY' 127.0.0.1:4445 $FC_FLAG" Enter
sleep 10

# Verify proxy connection
PROXY_PANE=$(tmux -S "$TMUX_SOCK" capture-pane -t demo:0.1 -p)
if echo "$PROXY_PANE" | grep -q connect; then
    good "ET client connected through throttle proxy"
else
    bad "FAILED: proxy saw no connection"
    tmux -S "$TMUX_SOCK" kill-server 2>/dev/null
    exit 1
fi

# Step 4: Run timestamp test
banner "Step 4: Run print_timestamps.py (high-volume output)"
SIDECAR="/tmp/et_demo_sidecar_$$.txt"
tmux -S "$TMUX_SOCK" send-keys -t demo:et "SIDECAR_FILE=$SIDECAR python3 $DIR/test/e2e/print_timestamps.py" Enter

info "Measuring lag every 10 seconds for 30 seconds..."
echo ""
printf "%-8s  %-14s  %-14s  %-10s\n" "TIME" "DISPLAY_LAG" "PROCESS_LAG" "STATUS"
printf "%-8s  %-14s  %-14s  %-10s\n" "----" "-----------" "-----------" "------"

for secs in 10 20 30; do
    sleep 10
    SCREEN=$(tmux -S "$TMUX_SOCK" capture-pane -t demo:et -p | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' | tail -1)
    REAL=$(python3 -c "from datetime import datetime; print(datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f'))")

    if [ -n "$SCREEN" ]; then
        DLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime('${SCREEN}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')")
    else
        DLAG="?"
    fi

    if [ -f "$SIDECAR" ]; then
        PROCESS_TS=$(cat "$SIDECAR")
        PLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime('${PROCESS_TS}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')")
    else
        PLAG="?"
    fi

    if [ "$PLAG" != "?" ] && python3 -c "exit(0 if float('$PLAG') < 1.0 else 1)" 2>/dev/null; then
        PSTATUS="running"
    else
        PSTATUS="STALLED"
    fi

    printf "t=%-5ss  %-14s  %-14s  %-10s\n" "$secs" "${DLAG}s" "${PLAG}s" "$PSTATUS"
done

echo ""
ES_ALIVE=$(lsof -i:4444 2>/dev/null | grep -c LISTEN)
if [ "$ES_ALIVE" -gt 0 ]; then
    good "etserver: alive"
else
    bad "etserver: CRASHED"
fi

# Step 5: Ctrl-C test
banner "Step 5: Ctrl-C responsiveness"
info "Sending Ctrl-C..."
START_NS=$(date +%s%N)
tmux -S "$TMUX_SOCK" send-keys -t demo:et C-c
CTRLC_RESULT="TIMEOUT"
for j in $(seq 1 15); do
    sleep 1
    if tmux -S "$TMUX_SOCK" capture-pane -t demo:et -p | tail -3 | grep -q '\$ *$'; then
        END_NS=$(date +%s%N)
        CTRLC_MS=$(( (END_NS - START_NS) / 1000000 ))
        CTRLC_RESULT="${CTRLC_MS}ms"
        break
    fi
done
info "Ctrl-C response time: $CTRLC_RESULT"

# Cleanup
banner "Summary: $MODE mode"
case "$MODE" in
    trunk)
        echo "  No flow control. Server writes directly to socket."
        echo "  - Display lag grows unbounded (~1s per second)"
        echo "  - Process stalls when TCP buffer fills"
        echo "  - etserver may crash on client disconnect"
        ;;
    backpressure)
        echo "  256KB WriteBuffer with backpressure."
        echo "  - Display lag grows (bounded by buffer + TCP)"
        echo "  - Process stalls when buffer fills (preserves all data)"
        echo "  - etserver survives client disconnect"
        ;;
    discard)
        echo "  256KB WriteBuffer with discard."
        echo "  - Display lag grows (bounded by TCP buffer)"
        echo "  - Process runs freely (old data discarded)"
        echo "  - etserver survives client disconnect"
        ;;
esac
echo ""

# Cleanup
tmux -S "$TMUX_SOCK" kill-server 2>/dev/null || true
kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null || true
rm -f /tmp/et_demo.fifo "$TMUX_SOCK" "$SIDECAR"

# Restore HEAD
cd "$DIR"
git checkout HEAD -- . 2>/dev/null
