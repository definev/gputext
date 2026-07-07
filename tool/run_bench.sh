#!/usr/bin/env bash
# GPUText benchmark runner: profile-mode macOS run of GPUTEXT_DEMO=bench,
# extracts the GPUBENCH stdout report into benchmark/results/, and prints a
# delta table against the committed baseline.
#
#   tool/run_bench.sh                       full run + baseline comparison
#   GPUTEXT_BENCH_QUICK=1 tool/run_bench.sh          short smoke run
#   GPUTEXT_BENCH_FILTER=frame.zoom tool/run_bench.sh   subset by id prefix
#   tool/run_bench.sh --update-baseline     copy this run over the baseline
#
# Keep the app window foregrounded while it runs — background throttling
# corrupts frame timings.
set -euo pipefail
cd "$(dirname "$0")/.."

RESULTS_DIR=benchmark/results
BASELINE=benchmark/baseline/macos.json
mkdir -p "$RESULTS_DIR"

UPDATE_BASELINE=0
FLUTTER_ARGS=()
for a in "$@"; do
  case "$a" in
    --update-baseline) UPDATE_BASELINE=1 ;;
    *) FLUTTER_ARGS+=("$a") ;;
  esac
done

log=$(mktemp -t gputext-bench.XXXXXX)
echo "gputext bench: flutter run --profile -d macos (log: $log)"
# The app exit(0)s after emitting the report, which ends flutter run.
GPUTEXT_DEMO=bench flutter run --profile -d macos ${FLUTTER_ARGS+"${FLUTTER_ARGS[@]}"} 2>&1 | tee "$log" || true

# Report lines arrive as "flutter: GPUBENCH:..." through flutter run; accept
# bare lines too in case the tool changes its prefixing.
json=$(sed -n -e 's/^flutter: GPUBENCH:J://p' -e 's/^GPUBENCH:J://p' "$log" | tr -d '\n')
expected=$(sed -n -e 's/^flutter: GPUBENCH:END bytes=\([0-9]*\).*/\1/p' \
                  -e 's/^GPUBENCH:END bytes=\([0-9]*\).*/\1/p' "$log" | tail -1)

if [ -z "$json" ] || [ -z "$expected" ]; then
  echo "error: no GPUBENCH report found in flutter run output" >&2
  exit 1
fi
actual=${#json}
if [ "$actual" != "$expected" ]; then
  echo "error: report truncated ($actual of $expected bytes)" >&2
  exit 1
fi

out="$RESULTS_DIR/$(date +%Y%m%dT%H%M%S)-macos.json"
printf '%s' "$json" > "$out"
echo "wrote $out"

if [ "$UPDATE_BASELINE" = 1 ]; then
  mkdir -p "$(dirname "$BASELINE")"
  cp "$out" "$BASELINE"
  echo "baseline updated: $BASELINE"
elif [ -f "$BASELINE" ]; then
  dart run tool/compare_bench.dart "$BASELINE" "$out"
else
  echo "no baseline at $BASELINE — run with --update-baseline to create one"
fi
