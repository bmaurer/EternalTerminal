#!/bin/bash
# Record all three E2E flow control scenarios as asciinema .cast files.
# Uses a lockfile to prevent concurrent runs.
#
# Usage: bash test/e2e/record_all.sh [output_dir]
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
OUT="${1:-$REPO/test/e2e/recordings}"
LOCKFILE="/tmp/et_e2e_record.lock"

# Lockfile guard
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another recording is running (lockfile $LOCKFILE)"; exit 1; }

mkdir -p "$OUT"
echo "Recording to $OUT at $(date)"

for MODE in trunk backpressure discard; do
    echo ""
    echo "=== $MODE ==="

    # Clean up between runs
    kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null || true
    pkill -9 -f throttle_proxy 2>/dev/null || true
    for s in /tmp/et_demo_*.sock; do tmux -S "$s" kill-server 2>/dev/null || true; done
    sleep 3

    CASTFILE="$OUT/${MODE}.cast"
    asciinema rec \
        --command "bash $DIR/record_scenario.sh $MODE" \
        --title "ET Flow Control: $MODE mode" \
        --cols 100 --rows 40 \
        --overwrite \
        "$CASTFILE" </dev/null

    echo "Recorded: $CASTFILE ($(wc -c < "$CASTFILE") bytes)"
    sleep 3
done

# Restore repo
cd "$REPO" && git checkout HEAD -- . 2>/dev/null
cd build && ninja -j4 2>&1 | tail -1

echo ""
echo "=== Done at $(date) ==="
ls -la "$OUT"/*.cast
