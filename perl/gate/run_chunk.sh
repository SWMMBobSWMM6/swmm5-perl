#!/bin/bash
# run_chunk.sh NAME IDS_FILE [WAIT_SECONDS] [JOBS] - one gate run of the Perl port on a chunk of the corpus:
#   python3 gate/gate.py NAME "perl/runswmm_saves.sh" --ids IDS -j JOBS --timeout 1800 --prune
# (JOBS 1 by default; 2 only for chunks of slow decks that neither SAVE nor USE a file, as the Ruby port did)
# inside flock on the shared corpus lock (waiting at most WAIT_SECONDS, default 3600, for it), with the results
# folder in /dev/shm (lessons/22). Afterwards the outputs of any failing model are copied to gate/results/NAME on
# disk (evidence, lessons/15) and the memory copy removed. The log is gate/NAME_run.txt; the queue, start and end
# times go to perl/gate/NAME_times.txt (no "started" line: the lock was not had in time and nothing ran).
# PERL_ENGINE overrides the engine command (e.g. the wrapper of a clean checkout).
# (php/gate/run_chunk.sh for Perl, and it also clears a results link left dangling by a killed run.)
# Written by Claude (Anthropic) for Robert Dickinson; see ../README.md.
set -u
NAME=$1; IDS=$(cd "$(dirname "$2")" && pwd)/$(basename "$2"); WAIT=${3:-3600}; JOBS=${4:-1}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ENGINE=${PERL_ENGINE:-$ROOT/perl/runswmm_saves.sh}
LOCK=${SWMM_GATE_LOCK:-${TMPDIR:-/tmp}/swmm5-gate.lock}  # one corpus run at a time
cd "$ROOT/gate"
M=/dev/shm/gate_$NAME
rm -rf "$M" && mkdir -p "$M"
if [ -L "results/$NAME" ] || [ -e "results/$NAME" ]; then rm -rf "results/$NAME"; fi
ln -s "$M" "results/$NAME"
echo "queued $(date -Is) engine $ENGINE ids $IDS jobs $JOBS" > "$ROOT/perl/gate/${NAME}_times.txt"
TMPDIR=/dev/shm flock -w "$WAIT" "$LOCK" bash -c "echo \"started \$(date -Is)\" >> '$ROOT/perl/gate/${NAME}_times.txt'; \
  nice -n 10 python3 gate.py '$NAME' '$ENGINE' --ids '$IDS' -j $JOBS --timeout 1800 --prune" > "${NAME}_run.txt" 2>&1
rc=$?
echo "ended $(date -Is) rc=$rc" >> "$ROOT/perl/gate/${NAME}_times.txt"
rm "results/$NAME"
mkdir -p "results/$NAME"
cp -a "$M"/. "results/$NAME"/ 2>/dev/null
rmdir "results/$NAME" 2>/dev/null
rm -rf "$M"
tail -4 "${NAME}_run.txt"
