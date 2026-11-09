# swmm5-perl

EPA SWMM 5.2.4 in Perl, written by a translator that reads EPA's C, and judged against EPA itself: the binary
`.out` file byte for byte, and the `.rpt` report line for line except the three lines that print the wall clock.

**Result: 478 of the 480 gate models ran, and all 478 are identical to EPA 5.2.4; 2 were not run** (stopped at
the 1800-second limit: `EPA/72_H&H_Elements(2).inp` and `Hydrology/SCANLON.inp`, the two models EPA itself takes
longest on, 38.6 s and 34.8 s, and the two the Ruby port could not finish either). First full gate: runs pl_1a,
pl_1b, pl_1solo, pl_1s1 to pl_1s4 and pl_1g, 8 and 9 November 2026; an independent rerun from a clean checkout, with
the engine regenerated (pl_v_a to pl_v_g, 9 November), gave the same result. Every `.out` byte-identical, every
`.rpt` identical except the three clock lines, exit code 0 on every model that finished, as EPA's. The engine runs at
about 150 times EPA's time (median; see Speed).

It is not a new engine and not a wrapper: there is no C in it and it calls no other port. Every number it writes
is EPA 5.2.4's, including the results of EPA's own defects wherever EPA's behaviour is defined
(`lessons/02-epa-defects-found.md`). Perl is one of the eight languages of the second wave of Bob Dickinson's Code
Rosetta Stone app.

## The parity contract

The same as the earlier ports' (see `go/` or the swmm5-go repository): EPA SWMM 5.2.4 built from the USEPA v5.2.4
tag with gcc 13.3 `-O2` on x86-64 Linux with glibc 2.39 (`ref/Makefile`), on a processor with FMA and AVX2; each
model run in its own folder; pass = `.out` byte-identical (when EPA writes one) and `.rpt` identical after removing
`Analysis begun on`, `Analysis ended on` and `Total elapsed time`, the exit code the same (EPA's command line always
exits 0). When an input error stops EPA before it writes results, the engine must not write a results file either.
Corpus: the 480 gate models of `gate/models_all.tsv` from SWMMBobSWMM6/1729-SWMM5-Models-2030.

## Run

Requires Perl 5.38 (tested with **Perl 5.38.2**, `This is perl 5, version 38, subversion 2 (v5.38.2) built for
x86_64-linux-gnu-thread-multi`, the Ubuntu build at `/usr/bin/perl`) and nothing else: only Perl's core modules
(POSIX, Time::HiRes, File::Spec, File::Basename, Cwd, IO::Handle), no CPAN. There is nothing to build.

```sh
perl/runswmm model.inp model.rpt model.out          # = perl perl/runswmm.pl ...
```

To regenerate the engine: `python3 tools/c2x/emit_perl.py perl/swmm5` from the repository root (needs
`pip install libclang==18.1.1` and the clang 18 headers at `/usr/lib/llvm-18/lib/clang/18/include`; about 30 s).

## How it was made

`tools/c2x/front.py` parses EPA's 54 C files with libclang; `tools/c2x/emit_perl.py` (1,725 lines, built on the
Python back end's analysis in `emit_py.py` and `emit_cs.py`: pointer modes, names, literals) writes the engine as one
file in package `SWMM5`, `perl/swmm5/engine.pl` (34,353 lines, generated). Hand-written: `perl/swmm5/crt.pl` (765
lines, the C library pieces SWMM uses), `perl/swmm5/overrides.pl` (299 lines, ports of `odesolve.c`, `mempool.c`
and six helpers that use pointer arithmetic, as in the Python, Ruby and PHP ports) and `perl/runswmm.pl` (56 lines,
EPA's `run/main.c`). When the port disagreed with EPA, the fix went into the translator or the runtime, never into
the generated file.

Perl has C's `if`, `while` and `for`, its own `last` and `next`, references, and `@_`, which passes every argument
by alias. The engine is written with `use strict` and `use warnings FATAL => 'all'`: any warning (an undefined value
used as a number, a string that is not a number, an array element read past the end) stops the run, since in a
translation from C each would be a bug. What the translation does (each in the emitter's header):

- **Records** are array references with one slot per field, the field indices constants
  (`$Node->[$j]->[TNode_newDepth]`), which Perl folds at compile time into a single multi-level element fetch. A
  struct's own arrays and structs are copied by `clone_<Type>`, as C's struct assignment copies them.
- **Arrays** are array references: copying the reference shares the array, as copying a C pointer does. The one
  array too big for Perl scalars, `TUHData.pastRain` (the RDII rainfall history: 3.4 GB in C on
  Hydrology/sewer_rdii_problem.inp, which as Perl scalars at 24 bytes or more apiece would not fit in this
  machine's 7 GB), is a packed string of doubles, read and written with `unpack`/`substr`.
- **char\*** is a CPtr, `[\$buffer, $offset]`: a reference to a byte string and an offset, read and written through
  the runtime's `cg`/`cs`; NULL is `undef`.
- **Pointers to numbers.** A scalar pointer parameter that is only dereferenced becomes an alias of the caller's
  variable through `@_` and refaliasing: `\my $h1 = \$_[3];`, so `findSurfArea($j, $qLast, $length, $h1, $h2, $y1,
  $y2)` reads as the C does.
- **Integers.** Perl's `/` divides as doubles: C's integer `/` is `int(a / b)` (exact for 32-bit operands); `%`
  takes the sign of its right operand in Perl, so C's `%` is `rt_imod` (under `use integer`); `>>` of a signed int
  runs under `use integer`; bitwise results of signed ints wrap to 32 bits through `rt_i32`, and unsigned
  arithmetic (the hash function's) is masked to 32 bits. `(int)` of a double is x86's answer (INT_MIN for NaN and
  out of range).
- **Doubles: the sign of zero.** Perl adds, subtracts and multiplies two whole-number doubles as 64-bit integers,
  exactly, and an integer has no -0.0: `0.0 * -3.0` is +0.0 in Perl and -0.0 in C, which prints "-0.00". A double
  `+`, `-` or `*` whose operands could both be whole is written `((A * B) || rt_zm(A, B))`: a nonzero result (or a
  NaN) is kept and a zero result is recomputed by the runtime with C's sign rules; unary minus likewise
  (`lessons/35-perl-adds-whole-doubles-as-integers.md`). The fix is left out where it cannot change anything: an
  operand that is a literal with a fraction, or a sum or difference that cannot be -0.0 in C.
- **Division by zero dies** in Perl, for doubles too: a division whose divisor is not a nonzero constant is
  `($d == 0.0 ? rt_fdiv0(A, $d) : A / $d)`; `rt_fdiv0` gives IEEE's infinities and, for 0/0, x86's default NaN
  (sign bit set, printed "-nan"), as C does.
- **switch** becomes an `if`/`elsif` chain when no case falls through and a balanced tree of comparisons on a case
  table when there are many cases; otherwise a labelled bare block with a fall-through flag, `break` being
  `last SWn`. **do-while** is `while (1) { ...; last unless (cond); }`, since Perl's `do {} while` is not a loop
  that `last` and `next` can leave. The comma operator is `do { A; B }`. Function pointers are code references.

## The runtime and the math library

- **printf/snprintf** (`crt.pl`, `rt_fmt_float`, `rt_fmt_int`): Perl's `sprintf` prints infinities and NaNs as
  "Inf" and "NaN" and has fast paths of its own (`%.0f` among them). Only the digits of `%f` and `%e` come from Perl's
  `sprintf` with an explicit precision, which hands them to glibc's `snprintf`; `%.0f` is asked for as `%#.0f`, which
  keeps Perl off its own path. Signs, `nan`/`inf`, padding, `%g`'s choice of style and every integer conversion are
  written in the runtime.
- **strtod/atof/sscanf**: `POSIX::strtod`, which is glibc's `strtod` (POSIX.so imports `strtod@GLIBC_2.2.5`), for
  every number; `atoi` is written here as glibc's `(int)strtol`.
- Checked against glibc 2.39 by `perl/test/run_crtcheck.sh` (the 1,394,252 cases from `tools/crt/test/mkfmt.c` the
  other runtimes replay): **1 differs**, `%#g` of 999999.5 (glibc `1.e+06`, the port `1.00000e+06`), the case every
  runtime reports; SWMM never uses `%#g`. Output: `perl/results/crtcheck_result.txt`.
- **Math.** `/usr/bin/perl` imports `exp@GLIBC_2.29`, `log@GLIBC_2.29`, `pow@GLIBC_2.29`, `sin`, `cos` and `sqrt`,
  and POSIX.so imports `tan`, `asin`, `acos`, `atan` and `log10`: the versioned symbols EPA imports (`nm -D` against
  `ref/runswmm`), so the port follows EPA, FMA routines included, on any machine both run on. Around them:
  - `log` and `sqrt` die where C returns -inf or a NaN: the engine calls them only for a positive argument
    (`($x > 0.0 ? log($x) : rt_log0($x))`) and the runtime answers the rest as glibc does.
  - `**` calls `pow` except when both operands are whole numbers, where Perl computes the power with its own
    integer code: exact, which is not glibc's answer for the sign of a zero (`(-0.0) ** 3.0`) or for an exact
    midpoint beyond 2**53 (`(-214.0) ** 8.0` differs from glibc's in the last bit). `POSIX::pow` is Perl's `**`
    (POSIX.pm). The engine keeps a nonzero result of at most 2**53, where the two agree, and recomputes anything else
    in `rt_cpow`, which passes a whole exponent as a string ("8.0"): Perl caches that as an inexact integer and
    calls glibc's `pow` (`lessons/36-perls-power-operator-is-not-always-pow.md`).
  - `POSIX::floor` and `POSIX::ceil` return a signaling NaN unchanged where glibc's quiet it, so the engine writes
    `($x == $x ? POSIX::floor($x) : $x + $x)`. `abs` of a double is `fabs`.
- Checked bit for bit, NaN signs and payloads included, by `perl/test/run_libm_tests.sh`, each argument twice: as a
  plain double, and after a comparison has made Perl cache it as an integer too (the state that sends `+`, `-`,
  `*` and `**` to Perl's integer code): 10,000,416 random arguments over SWMM's ranges plus special values
  (`tools/libm/test/mkvectors.c`), 3,300,000 edge cases (`mkedge.c`: huge trigonometric arguments, negative bases,
  overflow, underflow, subnormals) and 13,000,360 cases (`perl/test/mkexact.c`) for `sqrt`, `floor`, `ceil`, `fabs`,
  negation, `(float)`, `(int)`, `(long)`, and `*`, `+`, `-`, `pow` and `/` on whole numbers, zeros of both signs and
  zero divisors among them, each in the form the engine writes it: **0 differ** (`perl/results/libm_tests.txt`).
- **float.** `(float)x` is `rt_f32`: `pack('f')` is C's cast except that it sends values just above FLT_MAX to
  infinity, where `cvtsd2ss` rounds them down to FLT_MAX; the runtime handles that edge. The REAL4 values of the
  `.out` file go through the same conversion.
- **stdio**: Perl filehandles in `:raw` mode, with C's end-of-file flag and `fgets` semantics.

## How it was checked

| Run | Models | At once | Engine | Result |
|---|---|---|---|---|
| pl_1a | 210: the first half, in corpus order, of the 440 models outside the slow lists | 1 | working tree, commit 03e4374's files | 210 identical |
| pl_1b | the other 230 of them | 1 | the same | 230 identical |
| pl_1solo | EPA/attenuation_DW_High_CE.inp (the slowest that could finish) and Hydrology/sewer_rdii_problem.inp (3.2 GB) | 1 | the same | 2 identical |
| pl_1s1 to pl_1s4 | the 36 other slow decks, 9 in each | 2 | the same | 36 identical |
| pl_1g | EPA/72_H&H_Elements(2).inp and Hydrology/SCANLON.inp | 2 | the same | not run: both stopped at 1800 s |
| **pl_v_a, pl_v_b, pl_v_solo, pl_v_s1 to pl_v_s4, pl_v_g** | **the same eight lists, all 480 once** | as above | **a clean checkout of commit 03e4374, engine regenerated by its emitter (byte-identical to the committed file)** | **478 identical; the same 2 not run (stopped at 1800 s)** |
| pl_main | 48: 45 drawn at random from the 478 that finished, plus the three decks that SAVE and USE `cho.txt` | 1 | a clean clone of commit 8119e0d, engine regenerated there (byte-identical to the committed file) | 48 identical |

pl_1a to pl_1g are the first full gate: 478 identical, exit code 0 on every one, as EPA's; 2 not run. The pl_v runs
(23,318 s of engine time for the 478; 4 h 52 min of run time) are the independent rerun the brief asks for, from
`git archive` of the committed tree into a scratch folder, with `tools/c2x/emit_perl.py` run again there and its
`engine.pl` and `literals.txt` compared with the committed ones before the run; they used that checkout's launcher
and wrapper (`PERL_ENGINE`). The slow lists hold the decks whose time was estimated at 150 s or more (the PHP port's
gate time times 11.6, a factor fitted on development runs). The two stopped models are counted as nothing but not
run, although what they wrote before they were stopped matches EPA as far as it goes, in both runs:
72_H&H_Elements(2).inp 1,499 complete report lines of EPA's 1,935 (no `.out` data yet), SCANLON.inp 992 of 2,976
report lines and the first 36,364,288 (pl_1g) and 34,627,584 (pl_v_g) bytes of its 78,975,850-byte `.out`
(`perl/results/stopped_models_check.txt`).

The main session then checked the result itself: a clean `git clone` of commit 8119e0d, `tools/c2x/emit_perl.py`
run again there (its `engine.pl` and `literals.txt` byte-identical to the committed ones), and gate run pl_main
from that clone on 48 models: 45 drawn at random (seed 20261109) from the 478 that finished, plus
`Hydrology/save_rtk_long.inp`, `one_sub_one_rdii_node.inp` and `Use_SeasonalRDIIn.inp`, the decks that SAVE and USE
`cho.txt`. All 48 identical, exit code 0 on each, 1,918 s of engine time; ids in `perl/gate/ids_main_check.txt`,
record in `perl/results/pl_main.json`. `cho.txt` was unchanged after it.

No gate run failed a model that finished. The failures came earlier, in development runs on 190 decks copied to a
scratch folder and compared with `gate/ref_outputs`: Perl's compile-time warnings made fatal (a hexadecimal constant
above 32 bits, a division in void context, an assignment in a condition), `POSIX::pow` turning out to be Perl's `**`,
and, the last one, a runtime edit that had dropped `rt_fdiv0`, which stopped OWA_EXTRAN/extran6_type1.inp at its
first division by zero (the math check now covers division too). All 190 matched before the first gate, apart
from three whose reports print the absolute path of the scratch folder. The id lists are in `perl/gate/`, the
records (JSON, logs, queue and run times) in `perl/results/` and `perl/gate/`.

All runs: `python3 gate/gate.py NAME "$PWD/perl/runswmm_saves.sh" --ids IDS -j J --timeout 1800 --prune`, inside
`flock` on the shared corpus lock, with the output folder in `/dev/shm` (`lessons/22`), through
`perl/gate/run_chunk.sh`. `runswmm_saves.sh` (the Ruby port's wrapper with the engine changed) backs up every file a
deck SAVEs (listed by the swmm6-rust repository's `gate/savefiles.py`, called read-only), including the backslash
spelling of `[LID_USAGE]` report files (`lessons/29`), and restores them after the run; a deck with nothing to back
up runs the engine with `exec`, so the gate's timeout stops the engine itself. The 36 slow decks that neither SAVE
nor USE a file, and the two longest, ran two at a time (as the Ruby port's slow decks did) so that each background
job stayed inside the session's two-hour limit; everything else ran one at a time, as the brief's gate command does.
`Hydrology/cho.txt` was 1,114,474 bytes, md5 5b0ca1fe78588202fa779dbfa417b089, before and after.

## Speed

The gate's clock: the first full gate took 23,845 seconds of engine time for the 478 models that finished (6 h 37
min), plus 3,600 s for the two that were stopped; spread over eight runs, it took 4 h 57 min of wall time. The 440
models of pl_1a and pl_1b, one at a time, took 4,162 s (median 2.3 s); the 36 slow decks of pl_1s1 to pl_1s4, two at
a time, 17,233 s; the longest that finished were EPA/attenuation_DW_High_CE.inp, 1,481 s (EPA: 10.4 s; it ran alone),
and Hydrology/17_Sub_90_Link_USA_Units.inp, 1,249 s. Against EPA's own times from the reference run (made earlier, on
a differently loaded machine, and the slow decks here ran two at a time, so a rough guide only), the median ratio is
146 (101 models where EPA took 0.1 s or more; range 17 to 291); against the PHP port's gate times, 10.3 (median of the
125 models PHP took 1 s or more on; range 2.9 to 18.6); against the Ruby port's, 2.1 (108 models Ruby took 5 s or more
on; range 1.6 to 3.1). Start-up (compiling the 34,353-line engine; `perl/runswmm --version`) takes 0.3 s of CPU.

A sampling profile of attenuation_DW_High_CE.inp (a 22-node dynamic-wave model with a 1 s routing step) puts 18% of
the time in `lookup` (the cross-section tables), 12% in `dwflow_findConduitFlow` and about 11% in the runtime's
zero-sign helpers, which run whenever a sum or product is zero (often, in a network that is mostly dry); the rest is
spread thin. Leaving out the zero that stood for C's uninitialised locals changed the time by little (17.7 s to
17.1 s of CPU on one model, median of three interleaved runs; nothing measurable on another). Perl has no JIT; this is
its interpreter's speed. Memory: Hydrology/sewer_rdii_problem.inp, which allocates 3.38 GB of RDII rainfall history
in C, held 3.2 GB resident once that history was allocated (the packed string described above).

## What this does not show

- That SWMM is right: identical to EPA means EPA's answers, good or bad.
- Other platforms: the port calls the system libm through Perl, so on another machine it should follow EPA built
  there; only x86-64 Linux with glibc 2.39 was run, with Perl 5.38.2.
- Perl's integer path beyond 2**53. Perl adds, subtracts and multiplies whole-number doubles as 64-bit integers;
  below 2**53 that is C's double arithmetic (apart from the sign of zero, which the engine fixes), but a chain of
  such operations whose intermediate results pass 2**53 keeps bits that C rounds away at each step
  (`(2**53 + 1) + 1` is 9007199254740994 in Perl, 9007199254740992 in C). Nothing in the engine prevents that; it
  needs whole-number values beyond 9e15 passed from one integer operation to the next, and on the gate models it
  would have shown as a difference.
- Paths no gate model exercises: streets and inlets (one deck, which stops on input errors), climate files,
  USE HOTSTART, USE INFLOWS, USE RUNOFF; the stepping API is translated but only the command line was gated.
- A checked run in C's sense: Perl is memory-safe, and with warnings fatal an undefined value read as a number stops
  the run, but a C overrun that stays inside a Perl array's bounds (or writes past an array's end, which Perl grows)
  would not show; the gate would see it only if it changed an output.
- Speed beyond the gate's own clock: no interleaved benchmark against EPA was run (lessons/07).
- No person has reviewed the generated code line by line; the evidence is the gate and the runtime checks.

## Licence and credit

EPA SWMM is a work of the U.S. Environmental Protection Agency and is in the public domain; its engine is Lewis
Rossman's design, and this port keeps every algorithm as he wrote it. The port contains no glibc code: Perl calls the
system's libm (glibc, LGPL-2.1-or-later, `ref/LGPL-2.1.txt`) as a shared library at run time, as EPA's own build
does. Perl is distributed under the Artistic License or the GNU GPL. No licence has been chosen yet for the
translator and the runtime.

## AI use

The translator back end (`tools/c2x/emit_perl.py`), the runtime (`perl/swmm5/crt.pl`, `perl/swmm5/overrides.pl`,
`perl/runswmm.pl`), the generated engine, the launcher, gate wrapper and chunk runner, the runtime and math checks,
lessons 35 and 36 and this README were written by Claude (Anthropic's AI model, Claude Opus 5.5) in a Claude Code
session on 8 and 9 November 2026, for Robert (Bob) Dickinson, who asked for Perl in his Code Rosetta Stone app and
set the byte-for-byte standard. Claude ran every gate and check reported here. The checks are mechanical; no person
has yet reviewed the code.
