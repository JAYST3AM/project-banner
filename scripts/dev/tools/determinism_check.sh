#!/bin/bash
# The determinism gate, as a check that can be run again.
#
# Same seed, same initial state, same scripted events - different rendering frame rates. The
# authoritative state (men's positions, their condition, the formations, who is still standing)
# must be identical tick by tick, because the battle must not care how fast it is being drawn.
#
# Exits 0 when every variant matches the first, non-zero with the first divergent tick and field
# when one does not.
#
# Needs a real GPU: this scene simulates on the rendering device, so it cannot run headless and
# cannot be part of the headless CI suite. Run it before any change to the compute shader.
#
# Usage:
#   bash scripts/dev/tools/determinism_check.sh            # the standard gate
#   AGENTS=6000 SECONDS_RUN=60 EVERY=25 ... same command  # a bigger, longer gate
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$(cd "$HERE/../../.." && pwd)"
WORK="${WORK:-$PROJECT/.godot/determinism}"
mkdir -p "$WORK"

AGENTS="${AGENTS:-1000}"
SECONDS_RUN="${SECONDS_RUN:-26}"
EVERY="${EVERY:-25}"
VARIANTS="${VARIANTS:-20 30 60 120 0}"
SEED="${SEED:-780780}"

if ! command -v godotc > /dev/null 2>&1; then
	echo "godotc is not on PATH: this check needs the project's Godot build"
	exit 4
fi

for fps in $VARIANTS; do
	out="$WORK/trace_$fps.log"
	echo "running max-fps=$fps ..."
	timeout 180 godotc --path "$PROJECT" res://scenes/dev/gpu_crowd.tscn -- \
		--agents="$AGENTS" --max-fps="$fps" --seed="$SEED" \
		--checksum-every="$EVERY" --wipe-band=1 --wipe-at=300 \
		--seconds="$SECONDS_RUN" --out="$WORK/shot_$fps" > "$out" 2>&1
	if ! grep -q "checksum" "$out"; then
		echo "FAIL: max-fps=$fps produced no checksums (see $out)"
		exit 3
	fi
done

reference=""
status=0
for fps in $VARIANTS; do
	if [ -z "$reference" ]; then
		reference="$WORK/trace_$fps.log"
		continue
	fi
	echo "--- reference vs max-fps=$fps"
	if ! python "$HERE/trace_diff.py" "$reference" "$WORK/trace_$fps.log"; then
		status=1
	fi
done

if [ "$status" -eq 0 ]; then
	echo "DETERMINISM GATE: PASS - every frame rate produced the same battle"
else
	echo "DETERMINISM GATE: FAIL - see the divergence above"
fi
exit "$status"
