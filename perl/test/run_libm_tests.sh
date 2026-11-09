#!/bin/bash
# run_libm_tests.sh [N] - check the Perl port's math against C on this machine (the libm EPA calls), bit for bit:
# N random arguments per function over SWMM's ranges plus special values (tools/libm/test/mkvectors.c), an edge-case
# set (tools/libm/test/mkedge.c), and the exact functions, C casts and integer-path operations (test/mkexact.c).
# The vectors go to PERL_LIBM_WORK (default: a temporary folder) and are deleted.
# Written by Claude (Anthropic) for Robert Dickinson; see ../README.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
N=${1:-1000000}; W=$(mktemp -d "${PERL_LIBM_WORK:-${TMPDIR:-/tmp}}/pllibm.XXXXXX")
gcc -O2 -o "$W/mkvectors" "$ROOT/tools/libm/test/mkvectors.c" -lm
gcc -O2 -o "$W/mkedge" "$ROOT/tools/libm/test/mkedge.c" -lm
gcc -O2 -fno-builtin -o "$W/mkexact" "$HERE/mkexact.c" -lm
"$W/mkvectors" "$N" "$W/vectors.bin" 2> /dev/null > /dev/null
"$W/mkedge" 100000 "$W/edge.bin" 2> /dev/null > /dev/null
"$W/mkexact" "$N" "$W/exact.bin" 2> /dev/null > /dev/null
for f in vectors edge exact; do
  echo "== $(perl -e 'printf "perl %vd", $^V'): $f.bin$([ $f = vectors ] && echo " (N = $N per function)")"
  perl "$HERE/libmcheck.pl" "$W/$f.bin"
done
rm -rf "$W"
