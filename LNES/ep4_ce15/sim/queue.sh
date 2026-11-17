#!/bin/bash
# queue.sh LIST [LANES] -- runs the simulations of LIST (lines: ROM workdir defines...) LANES at a time
cd "$(dirname "$0")"
grep -v '^#' "$1" | grep . | xargs -P "${2:-2}" -L 1 sh -c './run_sim.sh "$@" > /dev/null 2>&1' _
