#!/bin/bash
# Runs one E2E flow control scenario. Called by asciinema rec --command.
MODE="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
BUILD="$REPO/build"
RATE=100000
ID="Demo$(date +%s | tail -c 8)"
KEY="E2ETestKey123456789012345678901A"
SIDECAR="/tmp/et_demo_sidecar_$$.txt"
ETMUX="/tmp/et_demo_client_$$.sock"
PROXY_LOG="/tmp/et_demo_proxy_$$.log"

C='\033[1;36m'; G='\033[1;32m'; R='\033[1;31m'; Y='\033[33m'; N='\033[0m'

cleanup() {
    tmux -S "$ETMUX" kill-server 2>/dev/null
    kill $ETSERVER_PID $PROXY_PID 2>/dev/null
    kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null
    pkill -9 -f "etterminal.*$ID" 2>/dev/null
    rm -f /tmp/et_demo.fifo "$ETMUX" "$SIDECAR" "$PROXY_LOG"
}
trap cleanup EXIT

case "$MODE" in
    trunk)
        echo -e "${C}=== ET Flow Control Demo: TRUNK (no flow control) ===${N}"
        echo -e "${Y}Server reads PTY and calls writePacket() directly.${N}"
        cd "$REPO"
        git checkout ee8ddc21c -- src/ proto/ test/integration_tests/ test/unit_tests/ 2>/dev/null
        git checkout 1c46dd970 -- src/terminal/TerminalClientMain.cpp src/terminal/TerminalMain.cpp src/base/Headers.hpp 2>/dev/null
        rm -f src/base/WriteBuffer.hpp test/unit_tests/WriteBufferTest.cpp
        ;;
    backpressure)
        echo -e "${C}=== ET Flow Control Demo: BACKPRESSURE mode ===${N}"
        echo -e "${Y}256KB WriteBuffer. Process stalls when buffer fills.${N}"
        cd "$REPO"
        git checkout b1171286e -- src/ proto/ test/integration_tests/ test/unit_tests/ 2>/dev/null
        ;;
    discard)
        echo -e "${C}=== ET Flow Control Demo: DISCARD mode ===${N}"
        echo -e "${Y}256KB WriteBuffer with discard. Old data dropped.${N}"
        echo -e "${Y}Process never stalls.${N}"
        cd "$REPO"
        git checkout b1171286e -- src/ proto/ test/integration_tests/ test/unit_tests/ 2>/dev/null
        ;;
esac
FC_FLAG=""
[ "$MODE" = "backpressure" ] && FC_FLAG="--flow-control backpressure"
[ "$MODE" = "discard" ] && FC_FLAG="--flow-control discard"
echo ""

echo -e "${C}--- Build ---${N}"
cd "$BUILD"
cmake -DDISABLE_VCPKG=ON -GNinja .. 2>&1 | tail -1
ninja -j4 2>&1 | tail -3
echo ""

echo -e "${C}--- Start services ---${N}"
rm -f /tmp/et_demo.fifo

"$BUILD/etserver" --serverfifo=/tmp/et_demo.fifo --port=4444 &>/dev/null &
ETSERVER_PID=$!
sleep 3

PYTHONUNBUFFERED=1 python3 -u "$DIR/throttle_proxy.py" 4445 4444 "$RATE" >"$PROXY_LOG" 2>&1 &
PROXY_PID=$!
sleep 2

"$BUILD/etterminal" --idpasskey="$ID/$KEY" --serverfifo=/tmp/et_demo.fifo &>/dev/null &
sleep 3

# Wait for services
for i in $(seq 1 15); do
    ES=$(lsof -i:4444 2>/dev/null | grep -c LISTEN)
    PX=$(lsof -i:4445 2>/dev/null | grep -c LISTEN)
    [ "$ES" -ge 1 ] && [ "$PX" -ge 1 ] && break
    sleep 1
done
[ "$ES" -lt 1 ] || [ "$PX" -lt 1 ] && { echo -e "${R}FAILED: etserver=$ES proxy=$PX${N}"; exit 1; }
echo -e "${G}etserver=:4444 proxy=:4445 (${RATE}B/s)${N}"
echo ""

echo -e "${C}--- Connect ET client through proxy ---${N}"
tmux -S "$ETMUX" new-session -d -s et -x 200 -y 50
# Wait for shell to be ready in tmux pane
for i in $(seq 1 30); do
    tmux -S "$ETMUX" capture-pane -p 2>/dev/null | grep -q '\$' && break
    sleep 1
done
tmux -S "$ETMUX" send-keys "$BUILD/et --idpasskey='$ID/$KEY' 127.0.0.1:4445 $FC_FLAG" Enter

# Wait for proxy connection (up to 30s)
for i in $(seq 1 30); do
    if grep -q connect "$PROXY_LOG" 2>/dev/null; then
        echo -e "${G}Connected through throttle proxy${N}"
        break
    fi
    sleep 1
    [ "$i" -eq 30 ] && { echo -e "${R}FAILED: proxy saw no connection after 30s${N}"; echo "proxy log:"; cat "$PROXY_LOG"; echo "tmux pane:"; tmux -S "$ETMUX" capture-pane -p 2>/dev/null | tail -5; echo "ss:"; ss -tnp 2>/dev/null | grep '444[45]\b' | head -3; exit 1; }
done

# Wait for ET session to establish (shell prompt in tmux)
for i in $(seq 1 30); do
    PANE=$(tmux -S "$ETMUX" capture-pane -p 2>/dev/null)
    # Look for a shell prompt that's NOT from the build directory (i.e. remote shell)
    if echo "$PANE" | grep -q '\~\]\$'; then
        echo -e "${G}Remote shell ready${N}"
        break
    fi
    sleep 1
    [ "$i" -eq 30 ] && echo -e "${Y}Shell may not be ready yet, proceeding...${N}"
done
echo ""

echo -e "${C}--- Running print_timestamps.py (30s) ---${N}"
tmux -S "$ETMUX" send-keys "SIDECAR_FILE=$SIDECAR python3 $DIR/print_timestamps.py" Enter

printf "%-8s  %-14s  %-14s  %-10s\n" "TIME" "DISPLAY_LAG" "PROCESS_LAG" "STATUS"
printf "%-8s  %-14s  %-14s  %-10s\n" "----" "-----------" "-----------" "------"

for secs in 10 20 30; do
    sleep 10
    SCREEN=$(tmux -S "$ETMUX" capture-pane -p 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]+' | tail -1)
    REAL=$(python3 -c "from datetime import datetime; print(datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f'))")

    DLAG="?"
    [ -n "$SCREEN" ] && DLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime('${SCREEN}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')" 2>/dev/null || true)

    PLAG="?"
    [ -f "$SIDECAR" ] && PLAG=$(python3 -c "
from datetime import datetime
s=datetime.strptime(open('$SIDECAR').read().strip(),'%Y-%m-%d %H:%M:%S.%f')
r=datetime.strptime('${REAL}'.strip(),'%Y-%m-%d %H:%M:%S.%f')
print(f'{(r-s).total_seconds():.1f}')" 2>/dev/null || true)

    PSTATUS=""
    if [ "$PLAG" != "?" ] && python3 -c "exit(0 if float('$PLAG') < 1.0 else 1)" 2>/dev/null; then
        PSTATUS="${G}running${N}"
    else
        PSTATUS="${R}STALLED${N}"
    fi

    printf "t=%-5ss  %-14s  %-14s  " "$secs" "${DLAG}s" "${PLAG}s"
    echo -e "$PSTATUS"
done

echo ""
echo "Proxy throughput:"
cat "$PROXY_LOG" | grep 'sent=' | tail -3
echo ""

ES_ALIVE=$(lsof -i:4444 2>/dev/null | grep -c LISTEN)
[ "$ES_ALIVE" -gt 0 ] && echo -e "etserver: ${G}alive${N}" || echo -e "etserver: ${R}CRASHED${N}"

echo ""
echo -e "${C}--- Summary: $MODE ---${N}"
case "$MODE" in
    trunk) echo "  No flow control. writePacket() blocks on TCP. Process stalls." ;;
    backpressure) echo "  256KB buffer. Process stalls when full. All data preserved." ;;
    discard) echo "  256KB buffer. Old data dropped. Process runs freely." ;;
esac

tmux -S "$ETMUX" send-keys C-c 2>/dev/null
sleep 1
tmux -S "$ETMUX" send-keys "exit" Enter 2>/dev/null
sleep 1
