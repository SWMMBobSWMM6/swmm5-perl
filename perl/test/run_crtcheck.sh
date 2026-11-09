#!/bin/sh
# run_crtcheck.sh - check the Perl runtime's printf, strtod and sscanf against the system glibc:
# tools/crt/test/mkfmt.c writes about 1.4 million reference cases from glibc, test/crtcheck.pl replays them
# through swmm5/crt.pl and counts the differences. The vectors go to a temporary folder and are deleted.
set -e
cd "$(dirname "$0")/.."
T=$(mktemp -d "${TMPDIR:-/tmp}/plcrt.XXXXXX")
gcc -O2 -o "$T/mkfmt" ../tools/crt/test/mkfmt.c -lm
"$T/mkfmt" > "$T/fmt.txt"
perl test/crtcheck.pl "$T/fmt.txt"
rm -rf "$T"
