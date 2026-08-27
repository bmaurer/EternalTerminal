#!/bin/bash
# Run all E2E flow control scenarios and generate HTML report.
#
# Usage: bash run_all_scenarios.sh [output_dir]
#
# Scenarios: trunk (~60s), backpressure (~60s), discard (~60s),
#            discard-disconnect (~150s). Total: ~6 minutes.
#
# Output: <dir>/report.html, <dir>/*.jsonl, <dir>/*_meta.json

set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
OUTDIR="${1:-$DIR/results}"
LOCKFILE="/tmp/et_e2e_run.lock"

exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another run in progress"; exit 1; }

mkdir -p "$OUTDIR"
echo "=== ET Flow Control E2E Test Suite ==="
echo "Output: $OUTDIR"
echo "Started: $(date)"
echo ""

for SCENARIO in "trunk" "backpressure" "discard" "discard --disconnect"; do
    MODE=$(echo "$SCENARIO" | awk '{print $1}')
    EXTRA=$(echo "$SCENARIO" | awk '{$1=""; print $0}' | xargs)
    echo "================================================================"
    echo "  Scenario: $MODE $EXTRA"
    echo "================================================================"

    bash "$DIR/do_scenario.sh" $SCENARIO --outdir "$OUTDIR"
    echo ""
done

cd "$REPO" && git checkout HEAD -- src/ proto/ test/integration_tests/ test/unit_tests/ 2>/dev/null
cd build && cmake -DDISABLE_VCPKG=ON -GNinja .. 2>&1 | tail -1 && ninja -j4 2>&1 | tail -1

echo "================================================================"
echo "  Generating HTML report"
echo "================================================================"
python3 "$DIR/generate_report.py" "$OUTDIR" "$OUTDIR/report.html"

echo ""
echo "=== Complete at $(date) ==="
ls -la "$OUTDIR"/*.html "$OUTDIR"/*.jsonl 2>/dev/null
