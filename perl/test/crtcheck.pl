# crtcheck.pl - compare the Perl port's printf, strtod and sscanf (swmm5/crt.pl) with the system glibc's results
# written by tools/crt/test/mkfmt.c (lines KIND \t FORMAT \t ARG \t RESULT, hex-encoded).
#   perl/test/run_crtcheck.sh  (builds mkfmt, runs it and this script, prints the summary)
# Written by Claude (Anthropic) for Robert Dickinson; see ../README.md.
package SWMM5;
use strict;
use warnings FATAL => 'all';
use File::Basename ();
use File::Spec ();
require(File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/../swmm5/crt.pl');

sub dbl { return unpack('d>', pack('H16', $_[0])) }
sub bits { return unpack('H16', pack('d>', $_[0])) }
sub hx { return unpack('H*', $_[0]) }

my @names = ('printf %f', 'printf %d', 'printf %ld', 'printf %s', 'strtod', 'sscanf');
my @total = (0) x 6;
my @bad = (0) x 6;
my $shown = 0;
my $out = c_buf(1024);
my %fcache;
open(my $fh, '<', $ARGV[0]) or die "$ARGV[0]: $!\n";
while (my $line = <$fh>) {
    chomp $line;
    next if $line eq '';
    my ($kind, $fm, $arg, $want) = split /\t/, $line, 4;
    my $f = $fcache{$fm} //= c_lit($fm);
    my ($k, $got);
    if ($kind eq 'f') {
        $k = 0;
        my $x = dbl($arg);
        $fm eq '%*.*f' ? c_snprintf($out, 1024, $f, 9, 3, $x) : c_snprintf($out, 1024, $f, $x);
        $got = hx(rt_bytes($out));
    } elsif ($kind eq 'i') {
        $k = 1;
        c_snprintf($out, 1024, $f, rt_i32(hex($arg)));
        $got = hx(rt_bytes($out));
    } elsif ($kind eq 'l') {
        $k = 2;
        c_snprintf($out, 1024, $f, unpack('q>', pack('H16', $arg)));
        $got = hx(rt_bytes($out));
    } elsif ($kind eq 's') {
        $k = 3;
        c_snprintf($out, 1024, $f, c_lit(pack('H*', $arg)));
        $got = hx(rt_bytes($out));
    } elsif ($kind eq 'd') {
        $k = 4;
        my $s = c_lit(pack('H*', $arg));
        my $e;
        my $v = c_strtod($s, $e);
        $got = bits($v) . ':' . ($e->[1] - $s->[1]);
    } elsif ($kind eq 'n') {
        $k = 5;
        my $s = c_lit(pack('H*', $arg));
        my ($i1, $d1) = (-77, -77.0);
        my $b = c_buf(32);
        cs($b, 0, 63);
        my $n = c_sscanf($s, c_lit('%d %lf %s'), $i1, $d1, $b);
        $got = "$n:$i1:" . bits($d1) . ':' . hx(rt_bytes($b));
    } else {
        next;
    }
    $total[$k]++;
    next if $got eq $want;
    $bad[$k]++;
    if ($shown++ < 25) { print STDERR "  $kind $fm arg=$arg  glibc=$want  perl=$got\n" }
}
for my $k (0 .. 5) { print "$names[$k]: $total[$k] cases, $bad[$k] differ\n" }
my ($sb, $st) = (0, 0);
$sb += $_ for @bad;
$st += $_ for @total;
print "$sb of $st cases differ\n";
