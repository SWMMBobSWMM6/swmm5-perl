#!/bin/sh
# check_literals.sh - every floating-point literal in the generated engine, as Perl reads it from source, must be
# the double the C compiler made of EPA's literal. tools/c2x/emit_perl.py writes each literal it emits with that
# double's bits to swmm5/literals.txt; this writes the literals into a Perl program as source text and compares.
cd "$(dirname "$0")/.."
T=$(mktemp "${TMPDIR:-/tmp}/pllit.XXXXXX")
{
  echo 'my ($n, $bad) = (0, 0);'
  awk -F'\t' '{ printf "$n++; if (unpack(\"H16\", pack(\"d>\", %s)) ne \"%s\") { $bad++; print STDERR \"  %s: \", unpack(\"H16\", pack(\"d>\", %s)), \" wanted %s\\n\" }\n", $1, $2, $1, $1, $2 }' swmm5/literals.txt
  echo 'print "$n literals, $bad differ\n";'
} > "$T"
perl "$T"
rm -f "$T"
