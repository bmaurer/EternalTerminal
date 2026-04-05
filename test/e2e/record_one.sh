#!/bin/bash
# Record one E2E flow control demo as an asciinema cast file.
#
# Usage: bash record_one.sh <trunk|backpressure|discard> <output.cast>
#
# This script starts services in the background, runs the test, and prints
# results. Wrap it with asciinema rec to capture the output.
MODE="$1"
CAST="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
BUILD="$REPO/build"

if [ -z "$MODE" ] || [ -z "$CAST" ]; then
    echo "Usage: $0 <trunk|backpressure|discard> <output.cast>"
    exit 1
fi

# Clean up
kill -9 $(lsof -t -i:4444 2>/dev/null) $(lsof -t -i:4445 2>/dev/null) 2>/dev/null
pkill -9 -f throttle_proxy 2>/dev/null
for s in /tmp/et_demo_*.sock; do tmux -S "$s" kill-server 2>/dev/null; done
rm -f /tmp/et_demo.fifo
sleep 2

asciinema rec --cols 100 --rows 40 --overwrite \
    --title "ET Flow Control: $MODE" \
    --command "bash $DIR/do_scenario.sh $MODE" \
    "$CAST" </dev/null

# Restore
cd "$REPO" && git checkout HEAD -- . 2>/dev/null
