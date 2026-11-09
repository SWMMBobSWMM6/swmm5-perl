# libmcheck.pl - check the math the Perl port computes against C on this machine, bit for bit, NaN signs and
# payloads included. Reads vector files in the format of tools/libm/test/mkvectors.c (name\0, n:u32,
# n x (args..., result) as raw little-endian doubles) and evaluates each function in the exact form the generated
# engine uses (tools/c2x/emit_perl.py): exp, sin, cos and ** from Perl, POSIX::tan/asin/acos/atan/log10/floor/
# ceil, the guarded log and sqrt, abs, and the C operations of perl/test/mkexact.c (negation, (float), (int),
# (long), and a*b, a+b, a-b and pow on integral arguments, with the zero-sign fix, and a/b with zero divisors).
# Each value is checked twice: as it comes (a plain double), and after a numeric comparison has made Perl cache
# it as an integer too (IOK), which is what sends + - * ** - to Perl's integer code.
#   perl/test/run_libm_tests.sh
# Written by Claude (Anthropic) for Robert Dickinson; see ../README.md.
package SWMM5;
use strict;
use warnings FATAL => 'all';
use POSIX ();
use File::Basename ();
use File::Spec ();
require(File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/../swmm5/crt.pl');

sub hexd { return unpack('H16', pack('d>', $_[0])) }

# the forms the generated code uses (see emit_perl.py: libc(), zfix(), x_UNARY_OPERATOR(), d2i())
my %F1 = (
    exp => sub { exp($_[0]) }, sin => sub { sin($_[0]) }, cos => sub { cos($_[0]) },
    tan => sub { POSIX::tan($_[0]) }, asin => sub { POSIX::asin($_[0]) }, acos => sub { POSIX::acos($_[0]) },
    atan => sub { POSIX::atan($_[0]) }, log10 => sub { POSIX::log10($_[0]) },
    log => sub { my $x = $_[0]; ($x > 0.0 ? log($x) : rt_log0($x)) },
    sqrt => sub { my $x = $_[0]; ($x > 0.0 ? sqrt($x) : rt_sqrt0($x)) },
    floor => sub { my $x = $_[0]; ($x == $x ? POSIX::floor($x) : $x + $x) },
    ceil => sub { my $x = $_[0]; ($x == $x ? POSIX::ceil($x) : $x + $x) },
    fabs => sub { abs($_[0]) },
    neg => sub { my $x = $_[0]; (-$x || rt_zn($x)) },
    f32 => sub { rt_f32($_[0]) },
    d2i => sub { my $x = $_[0]; (($x < 2147483648.0 && $x > -2147483649.0) ? int($x) : -2147483648) },
    d2l => sub { rt_d2l($_[0]) },
);
my %F2 = (
    pow => sub { my ($x, $y, $t) = @_; (((($t = $x ** $y) && abs($t) <= 9007199254740992.0)) ? $t : rt_cpow($x, $y)) },
    powi => sub { my ($x, $y, $t) = @_; (((($t = $x ** $y) && abs($t) <= 9007199254740992.0)) ? $t : rt_cpow($x, $y)) },
    mul => sub { my ($a, $b) = @_; (($a * $b) || rt_zm($a, $b)) },
    add => sub { my ($a, $b) = @_; (($a + $b) || rt_za($a, $b)) },
    sub => sub { my ($a, $b) = @_; (($a - $b) || rt_zs($a, $b)) },
    div => sub { my ($a, $b) = @_; ($b == 0.0 ? rt_fdiv0($a, $b) : $a / $b) },
);
my %INTRES = (d2i => 1, d2l => 1);

# make Perl cache an integral double as an integer too (pp_eq's SvIV_please), as the engine's comparisons do
sub flagged { my $v = $_[0]; my $d = ($v == 1); return $v }

open(my $fh, '<:raw', $ARGV[0]) or die "$ARGV[0]: $!\n";
my $data = do { local $/; <$fh> };
my ($pos, $total, $bad) = (0, 0, 0);
while ($pos < length($data)) {
    my $z = index($data, "\0", $pos);
    my $name = substr($data, $pos, $z - $pos);
    my $n = unpack('V', substr($data, $z + 1, 4));
    $pos = $z + 5;
    my $k = exists($F2{$name}) ? 3 : ($name eq 'fma' ? 4 : 2);
    my @v = unpack("d<" . ($n * $k), substr($data, $pos, $n * $k * 8));
    $pos += $n * $k * 8;
    if (!exists($F1{$name}) && !exists($F2{$name})) {
        print "$name: $n vectors, not used by the Perl port (skipped)\n";
        next;
    }
    my ($nb, $nn, $shown) = (0, 0, 0);
    for my $j (0 .. $n - 1) {
        my @a = @v[$j * $k .. $j * $k + $k - 2];
        my $want = $v[$j * $k + $k - 1];
        for my $mode (0, 1) {
            my @args = $mode ? map { flagged($_) } @a : @a;
            my $got = $k == 3 ? $F2{$name}->(@args) : $F1{$name}->(@args);
            my $ok;
            if ($INTRES{$name}) {
                $ok = $got == unpack('q<', pack('d<', $want));
            } else {
                # the bits, and (for a number held as an integer) that it is a double at all
                $ok = hexd($got) eq hexd($want) && ($got != $got || $got == unpack('d<', pack('d<', $got)));
            }
            next if $ok;
            $nb++;
            $nn++ if $got != $got && $want != $want;
            if ($shown++ < 5) {
                printf STDERR "  %s(%s)%s = %s  perl: %s\n", $name, join(', ', map { hexd($_) } @a),
                    $mode ? ' [integer-cached]' : '', $INTRES{$name} ? unpack('q<', pack('d<', $want)) : hexd($want),
                    $INTRES{$name} ? $got : hexd($got);
            }
        }
    }
    printf "%s: %d vectors (each twice), %d differ (%d of them only in a NaN's sign or payload)\n", $name, $n, $nb, $nn;
    $total += $n;
    $bad += $nb;
}
print "$bad of $total differ\n";
