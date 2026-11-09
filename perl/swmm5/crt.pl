# C runtime layer for the Perl port of EPA SWMM 5.2.4 (package SWMM5, loaded before the generated engine).
#
# Reproduces the C library behaviour SWMM's output depends on, where Perl's own differs:
#   - printf: Perl's sprintf prints Inf/NaN its own way and has fast paths of its own; only the digits of %f and %e
#     come from Perl's sprintf with an explicit precision (which hands them to glibc's snprintf); signs, nan/inf,
#     padding, %g's choice and all integer conversions are written here (test/crtcheck.pl compares with glibc)
#   - strtod/atof: POSIX::strtod, which is glibc's strtod; sscanf's numbers likewise; atoi is written here
#   - signed zeros: Perl adds, subtracts and multiplies two integral doubles as integers, which loses the sign of
#     a zero result; the engine calls rt_za, rt_zs, rt_zm, rt_zn for a zero result (see tools/c2x/emit_perl.py)
#   - x / 0.0 dies in Perl (the engine calls rt_fdiv0 for that case); log and sqrt die where C returns -inf/NaN
#   - double -> int: x86's cvttsd2si (NaN and out of range give INT_MIN); float: IEEE single rounding as C's cast
#   - char*: CPtr, [\$buffer, $offset]; chars are signed as on x86
#   - stdio: Perl filehandles in :raw mode with C's end-of-file flag and fgets semantics
# Written by Claude (Anthropic) for Robert Dickinson; see perl/README.md.
package SWMM5;
use strict;
use warnings FATAL => 'all';
no warnings 'portable';
use POSIX ();
use IO::Handle;

use constant NZ => -0.0;                                    # IEEE -0.0 (Perl keeps the sign of this literal)
use constant FLT_MAX => 3.4028234663852886e38;
use constant FLT_OVF => 3.4028235677973366e38;             # 2**128 - 2**103: from here a double rounds to inf
my $NEG_NAN = unpack('d>', pack('H16', 'fff8000000000000'));  # x86 default NaN: glibc prints "-nan"
my $POS_NAN = unpack('d>', pack('H16', '7ff8000000000000'));
my $INF = 9**9**9;

# ------------------------------------------------------------------- char pointers: [\$buffer, $offset]
sub c_lit { my $s = $_[0] . "\0"; return [\$s, 0] }

sub c_buf {
    my $n = $_[0] > 0 ? $_[0] : 1;
    my $s = "\0" x $n;
    return [\$s, 0];
}

sub rt_bytes {
    my ($r, $o) = @{$_[0]};
    my $e = index($$r, "\0", $o);
    return substr($$r, $o, ($e < 0 ? length($$r) : $e) - $o);
}

sub c_buf_from {
    my ($src, $n) = @_;
    my $p = c_buf($n);
    my $s = rt_bytes($src);
    $s = substr($s, 0, $n) if length($s) > $n;
    substr(${$p->[0]}, 0, length($s), $s);
    return $p;
}

sub c_from_bytes {
    my ($vals, $n) = @_;
    my $p = c_buf($n);
    for my $i (0 .. $#$vals) { substr(${$p->[0]}, $i, 1, chr($vals->[$i] & 255)) }
    return $p;
}

# a copy of the whole buffer: a struct's own char array, copied by the struct's clone_<Type>
sub c_dup { my $s = ${$_[0][0]}; return [\$s, $_[0][1]] }

# p[i] (a signed char) and p[i] = v
sub cg { return unpack('c', substr(${$_[0][0]}, $_[0][1] + $_[1], 1)) }
sub cs { substr(${$_[0][0]}, $_[0][1] + $_[1], 1, chr($_[2] & 255)); return $_[2] }

sub cadd { return [$_[0][0], $_[0][1] + $_[1]] }

sub rt_peq {
    my ($a, $b) = @_;
    return (!defined($a) && !defined($b)) if !defined($a) || !defined($b);
    return $a->[0] == $b->[0] && $a->[1] == $b->[1];
}

# ------------------------------------------------------------------- arrays and records
sub rt_arr { my ($n, $fill) = @_; return [($fill) x ($n > 0 ? $n : 0)] }
sub rt_recs { my ($new, $n) = @_; return [map { $new->() } 1 .. $n] }
sub rt_bufs { my ($n, $m) = @_; return [map { c_buf($m) } 1 .. $n] }
sub rt_arr2 { my ($n, $m, $fill) = @_; return [map { [($fill) x $m] } 1 .. $n] }

sub rt_rec_init {
    my $o = shift;
    while (@_) { my $k = shift; $o->[$k] = shift }
    return $o;
}

sub rt_realloc {
    my ($x, $n, $fill) = @_;
    my $new = ref($fill) eq 'CODE';
    return $new ? rt_recs($fill, $n) : rt_arr($n, $fill) if !defined $x;
    if ($n < @$x) { $#$x = $n - 1 }
    else { push @$x, ($new ? $fill->() : $fill) while @$x < $n }
    return $x;
}

sub rt_realloc_c {
    my ($p, $n) = @_;
    my $q = c_buf($n);
    my $s = substr(${$p->[0]}, $p->[1], $n);
    substr(${$q->[0]}, 0, length($s), $s);
    return $q;
}

# packed doubles (TUHData.pastRain): a reference to a string of 8-byte doubles
sub rt_pnew { my $s = "\0" x (8 * ($_[0] > 0 ? $_[0] : 1)); return \$s }
sub rt_pget { return unpack('d<', substr(${$_[0]}, 8 * $_[1], 8)) }
sub rt_pset { substr(${$_[0]}, 8 * $_[1], 8, pack('d<', $_[2])); return $_[2] }

# &x passed where the callee takes an array: a one-element array, copied back
sub rt_arr1 {
    my $a = [$_[0]];
    my $r = $_[1]->($a);
    $_[0] = $a->[0];
    return $r;
}

# &c (a char) passed where the callee takes a char*: a two-byte buffer, copied back
sub rt_chr1 {
    my $p = c_buf(2);
    cs($p, 0, $_[0]);
    my $r = $_[1]->($p);
    $_[0] = cg($p, 0);
    return $r;
}

sub rt_first { return $_[0] }

# ------------------------------------------------------------------- arithmetic with C semantics
sub rt_sign { return (ord(pack('d>', $_[0])) & 0x80) != 0 }

# zero results of +, -, * and unary minus, with C's signs (a nonzero result never reaches these)
sub rt_zm { return (((ord(pack('d>', $_[0])) ^ ord(pack('d>', $_[1]))) & 0x80) ? NZ : 0.0) }
sub rt_za { return ((ord(pack('d>', $_[0])) & ord(pack('d>', $_[1]))) & 0x80) ? NZ : 0.0 }
sub rt_zs { return ((ord(pack('d>', $_[0])) & ~ord(pack('d>', $_[1]))) & 0x80) ? NZ : 0.0 }
sub rt_zn { return (ord(pack('d>', $_[0])) & 0x80) ? 0.0 : NZ }

# C's a / b for a zero divisor b (+0.0 or -0.0), where Perl's / dies: divsd gives a NaN dividend back (quieted),
# the default NaN for 0/0 (sign set: glibc prints "-nan"), and otherwise an infinity with the XOR of the signs
sub rt_fdiv0 {
    my ($a, $b) = @_;
    return $a + $a if $a != $a;
    return $NEG_NAN if $a == 0;
    return (rt_sign($a) xor rt_sign($b)) ? -$INF : $INF;
}

# C's pow(x, y) where Perl's x ** y may not be it. With two integral operands (each below 2**53) Perl computes an
# integer power of its own, exactly: that is glibc's answer when it is a nonzero double of at most 53 bits, but not
# the sign of a zero (pow(-0.0, 3.0) is -0.0) and not always the rounding of a result beyond 2**53, where glibc's
# pow may land on the other neighbour of an exact midpoint. An exponent held as a string ("3.0") is cached by Perl
# as an inexact integer (pIOK, not IOK), which keeps pp_pow off its integer code: x ** "3.0" is glibc's pow(x, 3.0).
# (POSIX::pow cannot help: POSIX.pm defines it as Perl's **.)
sub rt_cpow {
    my ($x, $y) = @_;
    return $x ** $y if $y != int($y) || abs($y) >= 9007199254740992.0;
    return $x ** sprintf('%.1f', $y);
}

sub rt_d2l {
    my $x = $_[0];
    return ($x < 9223372036854775808.0 && $x >= -9223372036854775808.0) ? int($x) : -9223372036854775807 - 1;
}

sub rt_i32 {
    my $x = $_[0] & 0xFFFFFFFF;
    return $x >= 0x80000000 ? $x - 0x100000000 : $x;
}

sub rt_imod { use integer; return $_[0] % $_[1] }

# C's (float)x: pack('f') sends anything above FLT_MAX to infinity, where cvtsd2ss rounds the values just above it
# down to FLT_MAX; NaNs keep their sign (pack converts them with a C cast)
sub rt_f32 {
    my $x = $_[0];
    my $a = abs($x);
    return unpack('f<', pack('f<', $x)) if $a <= FLT_MAX || $x != $x;
    return $x > 0 ? $INF : -$INF if $a >= FLT_OVF;
    return $x > 0 ? FLT_MAX : -FLT_MAX;
}

# ------------------------------------------------------------------- math.h corners
sub rt_sqrt0 {
    my $x = $_[0];
    return $x if $x == 0;                 # sqrt(-0.0) is -0.0
    return $x + $x if $x != $x;          # a NaN comes back quiet
    return $NEG_NAN;                      # sqrtsd of a negative number: the default NaN
}

sub rt_log0 {
    my $x = $_[0];
    return -$INF if $x == 0;
    return $x + $x if $x != $x;
    return $NEG_NAN;                      # glibc __math_invalid: (x - x) / (x - x)
}

# ------------------------------------------------------------------- memory and strings
sub c_memset {
    my ($a, $v, $n) = @_;
    if (ref($a->[0]) eq 'SCALAR') {
        substr(${$a->[0]}, $a->[1], $n, chr($v & 255) x $n);
        return $a;
    }
    my $cnt = int($n / 8);
    $cnt = @$a if $cnt > @$a;
    for my $i (0 .. $cnt - 1) { $a->[$i] = 0 }
    return $a;
}

sub c_strlen { return index(${$_[0][0]}, "\0", $_[0][1]) - $_[0][1] }

sub c_strcpy {
    my ($d, $s) = @_;
    my $src = rt_bytes($s) . "\0";
    substr(${$d->[0]}, $d->[1], length($src), $src);
    return $d;
}

sub c_strncpy {
    my ($d, $s, $n) = @_;
    my $src = substr(rt_bytes($s), 0, $n);
    $src .= "\0" x ($n - length($src));
    substr(${$d->[0]}, $d->[1], $n, $src);
    return $d;
}

sub c_strcat {
    my ($d, $s) = @_;
    c_strcpy(cadd($d, c_strlen($d)), $s);
    return $d;
}

# glibc returns the difference of the first differing bytes, as unsigned chars
sub c_strcmp {
    my $x = rt_bytes($_[0]);
    my $y = rt_bytes($_[1]);
    return 0 if $x eq $y;
    my $n = length($x) < length($y) ? length($x) : length($y);
    for my $i (0 .. $n - 1) {
        my $d = ord(substr($x, $i, 1)) - ord(substr($y, $i, 1));
        return $d if $d;
    }
    return length($x) > length($y) ? ord(substr($x, $n, 1)) : -ord(substr($y, $n, 1));
}

sub c_strchr {
    my ($s, $c) = @_;
    $c &= 255;
    my $e = index(${$s->[0]}, "\0", $s->[1]);
    return [$s->[0], $e] if $c == 0;
    my $i = index(${$s->[0]}, chr($c), $s->[1]);
    return undef if $i < 0 || $i > $e;
    return [$s->[0], $i];
}

sub c_strrchr {
    my ($s, $c) = @_;
    $c &= 255;
    my $e = index(${$s->[0]}, "\0", $s->[1]);
    return [$s->[0], $e] if $c == 0;
    my $i = rindex(${$s->[0]}, chr($c), $e - 1);
    return undef if $i < $s->[1];
    return [$s->[0], $i];
}

sub c_strstr {
    my ($h, $n) = @_;
    my $i = index(rt_bytes($h), rt_bytes($n));
    return $i < 0 ? undef : [$h->[0], $h->[1] + $i];
}

sub c_strcspn {
    my $s = rt_bytes($_[0]);
    my $r = rt_bytes($_[1]);
    for my $i (0 .. length($s) - 1) { return $i if index($r, substr($s, $i, 1)) >= 0 }
    return length($s);
}

my $tok_next;

sub c_strtok {
    my ($s, $delim) = @_;
    $tok_next = $s if defined $s;
    my $p = $tok_next;
    return undef if !defined $p;
    my $ds = rt_bytes($delim);
    my $r = $p->[0];
    my $e = index($$r, "\0", $p->[1]);
    my $i = $p->[1];
    $i++ while $i < $e && index($ds, substr($$r, $i, 1)) >= 0;
    if ($i >= $e) { $tok_next = undef; return undef }
    my $j = $i;
    $j++ while $j < $e && index($ds, substr($$r, $j, 1)) < 0;
    if ($j < $e) {
        substr($$r, $j, 1, "\0");
        $tok_next = [$r, $j + 1];
    } else {
        $tok_next = undef;
    }
    return [$r, $i];
}

sub c_toupper { my $c = $_[0]; return ($c >= 97 && $c <= 122) ? $c - 32 : $c }

sub rt_space { my $c = $_[0]; return $c == 32 || ($c >= 9 && $c <= 13) }

# ------------------------------------------------------------------- strtod, atof, atoi
# glibc's own strtod (POSIX::strtod calls it): the text up to C's NUL; returns (value, characters used)
sub rt_strtod_bytes {
    my $t = $_[0];
    my ($v, $unparsed) = POSIX::strtod($t);
    $unparsed //= length($t);
    return ($v, length($t) - $unparsed);
}

sub c_strtod {
    my $s = $_[0];
    my ($v, $used) = rt_strtod_bytes(rt_bytes($s));
    if (@_ > 1) { $_[1] = $used > 0 ? [$s->[0], $s->[1] + $used] : $s }
    return $used > 0 ? $v : 0.0;
}

sub c_atof { return c_strtod($_[0]) }

# glibc's atoi is (int)strtol: the long saturates, then the conversion keeps its low 32 bits
sub c_atoi {
    my $t = rt_bytes($_[0]);
    return 0 unless $t =~ /\A[ \t\n\x0b\f\r]*([-+]?)(\d+)/;
    my ($sg, $d) = ($1, $2);
    $d =~ s/\A0+(?=\d)//;
    my $v;
    if (length($d) > 19 || (length($d) == 19 && $d gt ($sg eq '-' ? '9223372036854775808' : '9223372036854775807'))) {
        $v = $sg eq '-' ? -9223372036854775807 - 1 : 9223372036854775807;
    } else {
        $v = $sg eq '-' ? -$d : 0 + $d;
        $v = int($v);
    }
    return rt_i32($v);
}

# ------------------------------------------------------------------- sscanf
# the targets follow the format: numbers are assigned through @_ (Perl passes arguments by alias); %s and %c
# write into the CPtr they are given
sub c_sscanf {
    my $b = rt_bytes($_[0]);
    my $f = rt_bytes($_[1]);
    my $ai = 2;
    my ($i, $k, $count, $any) = (0, 0, 0, 0);
    my $n = length($b);
    my $nf = length($f);
    while ($k < $nf) {
        my $fc = ord(substr($f, $k, 1));
        if (rt_space($fc)) {
            $k++ while $k < $nf && rt_space(ord(substr($f, $k, 1)));
            $i++ while $i < $n && rt_space(ord(substr($b, $i, 1)));
            next;
        }
        if ($fc != 37) {
            return ($any || $count > 0) ? $count : -1 if $i >= $n;
            return $count if ord(substr($b, $i, 1)) != $fc;
            $i++;
            $k++;
            next;
        }
        $k++;
        if ($k < $nf && substr($f, $k, 1) eq '%') {
            $i++ while $i < $n && rt_space(ord(substr($b, $i, 1)));
            return $count if $i >= $n || substr($b, $i, 1) ne '%';
            $i++;
            $k++;
            next;
        }
        my $suppress = 0;
        if ($k < $nf && substr($f, $k, 1) eq '*') { $suppress = 1; $k++ }
        my $width = 0;
        while ($k < $nf && substr($f, $k, 1) =~ /\d/) { $width = $width * 10 + substr($f, $k, 1); $k++ }
        my $lmod = 0;
        while ($k < $nf && substr($f, $k, 1) =~ /[lhL]/) { $lmod++ if substr($f, $k, 1) eq 'l'; $k++ }
        my $conv = $k < $nf ? substr($f, $k, 1) : '';
        $k++;
        if ($conv ne 'c' && $conv ne '[' && $conv ne 'n') {
            $i++ while $i < $n && rt_space(ord(substr($b, $i, 1)));
        }
        if ($i >= $n && $conv ne 'n') {
            return ($count == 0 && !$any) ? -1 : $count;
        }
        if ($conv eq 'd' || $conv eq 'i' || $conv eq 'u') {
            my $lim = $width > 0 && $i + $width < $n ? $i + $width : $n;
            my $t = substr($b, $i, $lim - $i);
            return $count unless $t =~ /\A([-+]?)(\d+)/;
            my ($sg, $d) = ($1, $2);
            $i += length($sg) + length($d);
            $any = 1;
            $d =~ s/\A0+(?=\d)//;
            my $v;
            if (length($d) > 19 || (length($d) == 19 && $d gt ($sg eq '-' ? '9223372036854775808' : '9223372036854775807'))) {
                $v = $sg eq '-' ? -9223372036854775807 - 1 : 9223372036854775807;
            } else {
                $v = int($sg eq '-' ? -$d : 0 + $d);
            }
            if (!$suppress) {
                $_[$ai++] = $lmod > 0 ? $v : rt_i32($v);
                $count++;
            }
        } elsif ($conv =~ /\A[feEgG]\z/) {
            my $t = substr($b, $i, $width > 0 ? $width : $n - $i);
            my ($v, $used) = rt_strtod_bytes($t);
            return $count if $used == 0;
            $i += $used;
            $any = 1;
            if (!$suppress) {
                $_[$ai++] = $lmod > 0 ? $v : rt_f32($v);
                $count++;
            }
        } elsif ($conv eq 's') {
            my $j = $i;
            my $w = $width > 0 ? $width : 1 << 62;
            $j++ while $j < $n && !rt_space(ord(substr($b, $j, 1))) && $j - $i < $w;
            if (!$suppress) {
                my $d = $_[$ai++];
                my $src = substr($b, $i, $j - $i) . "\0";
                substr(${$d->[0]}, $d->[1], length($src), $src);
                $count++;
            }
            $i = $j;
            $any = 1;
        } elsif ($conv eq 'c') {
            my $cnt = $width > 0 ? $width : 1;
            return ($count == 0 && !$any) ? -1 : $count if $i >= $n;
            if ($suppress) {
                $i += $cnt < $n - $i ? $cnt : $n - $i;
            } else {
                my $d = $_[$ai];
                my $t = 0;
                while ($t < $cnt && $i < $n) {
                    if (ref($d) eq 'ARRAY') { cs($d, $t, ord(substr($b, $i, 1))) }
                    else { my $c = ord(substr($b, $i, 1)); $_[$ai] = $c > 127 ? $c - 256 : $c }
                    $i++;
                    $t++;
                }
                $ai++;
                $count++;
            }
            $any = 1;
        } else {
            die "sscanf %$conv\n";
        }
    }
    return $count;
}

# ------------------------------------------------------------------- printf family
my %fmt_cache;

sub rt_parse_fmt {
    my $fb = $_[0];
    my @parts;
    my $lit = '';
    my $i = 0;
    my $n = length($fb);
    while ($i < $n) {
        my $ch = substr($fb, $i, 1);
        if ($ch ne '%') { $lit .= $ch; $i++; next }
        if ($i + 1 < $n && substr($fb, $i + 1, 1) eq '%') { $lit .= '%'; $i += 2; next }
        if ($lit ne '') { push @parts, [0, $lit]; $lit = '' }
        pos($fb) = $i + 1;
        $fb =~ /\G([-+ #0]*)(\*|\d*)(?:\.(\*|\d*))?([hlLqjzt]*)(.?)/g or die "printf format\n";
        my ($flags, $width, $prec, $lm, $conv) = ($1, $2, $3, $4, $5);
        push @parts, [1, $flags, $width, $prec, $conv, $lm];
        $i = pos($fb);
    }
    push @parts, [0, $lit] if $lit ne '';
    return \@parts;
}

sub rt_pad {
    my ($s, $w, $left) = @_;
    my $l = length($s);
    return $s if $l >= $w;
    return $left ? $s . (' ' x ($w - $l)) : (' ' x ($w - $l)) . $s;
}

sub rt_exp_str {
    my ($k, $upper) = @_;
    my $a = $k < 0 ? -$k : $k;
    return ($upper ? 'E' : 'e') . ($k < 0 ? '-' : '+') . ($a < 10 ? '0' : '') . $a;
}

# digits of |x| (finite) for %e with precision p, from glibc (Perl's sprintf hands %.*e to snprintf):
# (digit string, decimal exponent)
sub rt_e_digits {
    my ($ax, $p) = @_;
    my $s = sprintf('%.*e', $p, $ax);
    my $e = index($s, 'e');
    my $d = substr($s, 0, $e);
    $d =~ s/\.//;
    return ($d, 0 + substr($s, $e + 1));
}

# %f digits of |x|: glibc's through Perl's sprintf; '#' keeps Perl off its own path for %.0f (F0convert)
sub rt_f_digits {
    my ($ax, $p) = @_;
    return sprintf('%.*f', $p, $ax) if $p > 0;
    my $s = sprintf('%#.0f', $ax);
    chop $s;
    return $s;
}

# one floating conversion, as glibc's printf writes it
sub rt_fmt_float {
    my ($x, $flags, $w, $prec, $conv) = @_;
    my $neg = rt_sign($x);
    my $left = index($flags, '-') >= 0;
    my $sign = $neg ? '-' : (index($flags, '+') >= 0 ? '+' : (index($flags, ' ') >= 0 ? ' ' : ''));
    my $upper = $conv eq 'E' || $conv eq 'G' || $conv eq 'F';
    my $alt = index($flags, '#') >= 0;
    if ($x != $x || $x == $INF || $x == -$INF) {
        my $body = $x != $x ? 'nan' : 'inf';
        $body = uc($body) if $upper;
        return rt_pad($sign . $body, $w, $left);
    }
    my $p = defined($prec) ? $prec : 6;
    my $ax = abs($x);
    my $body;
    if ($conv eq 'f' || $conv eq 'F') {
        $body = rt_f_digits($ax, $p);
        $body .= '.' if $p == 0 && $alt;
    } elsif ($conv eq 'e' || $conv eq 'E') {
        my ($d, $k) = rt_e_digits($ax, $p);
        $body = substr($d, 0, 1) . ($p > 0 || $alt ? '.' : '') . substr($d, 1) . rt_exp_str($k, $upper);
    } else {
        my $pp = $p == 0 ? 1 : $p;
        my ($d, $k) = rt_e_digits($ax, $pp - 1);
        if ($pp > $k && $k >= -4) {
            $body = rt_f_digits($ax, $pp - 1 - $k);
            if (!$alt) {
                if (index($body, '.') >= 0) { $body =~ s/0+\z//; $body =~ s/\.\z// }
            } elsif (index($body, '.') < 0) {
                $body .= '.';
            }
        } else {
            my $fr = substr($d, 1);
            $fr =~ s/0+\z// if !$alt;
            $body = substr($d, 0, 1) . ($fr eq '' && !$alt ? '' : '.') . $fr . rt_exp_str($k, $upper);
        }
    }
    if (index($flags, '0') >= 0 && !$left && length($sign) + length($body) < $w) {
        $body = ('0' x ($w - length($sign) - length($body))) . $body;
    }
    return rt_pad($sign . $body, $w, $left);
}

sub rt_fmt_int {
    my ($v, $flags, $w, $prec, $conv, $lm) = @_;
    my $left = index($flags, '-') >= 0;
    my $long = $lm =~ /[ljzq]/;
    my ($digits, $sign, $pre) = ('', '', '');
    if ($conv eq 'd' || $conv eq 'i') {
        $v = rt_i32($v) if !$long;
        if ($v < 0) {
            $digits = $v == -9223372036854775807 - 1 ? '9223372036854775808' : '' . (-$v);
            $sign = '-';
        } else {
            $digits = '' . $v;
            $sign = index($flags, '+') >= 0 ? '+' : (index($flags, ' ') >= 0 ? ' ' : '');
        }
    } else {
        $v &= 0xFFFFFFFF if !$long;
        $digits = $conv eq 'u' ? sprintf('%u', $v) : $conv eq 'x' ? sprintf('%x', $v)
                : $conv eq 'X' ? sprintf('%X', $v) : sprintf('%o', $v);
        if (index($flags, '#') >= 0 && $v != 0) {
            if ($conv eq 'x') { $pre = '0x' } elsif ($conv eq 'X') { $pre = '0X' } elsif ($conv eq 'o') { $digits = '0' . $digits }
        }
    }
    if (defined $prec) {
        if ($prec == 0 && $v == 0) { $digits = '' }
        elsif (length($digits) < $prec) { $digits = ('0' x ($prec - length($digits))) . $digits }
    } elsif (index($flags, '0') >= 0 && !$left) {
        my $l = length($sign) + length($pre) + length($digits);
        $digits = ('0' x ($w - $l)) . $digits if $l < $w;
    }
    return rt_pad($sign . $pre . $digits, $w, $left);
}

sub rt_format {
    my $fb = rt_bytes(shift);
    my $ent = $fmt_cache{$fb} //= rt_parse_fmt($fb);
    my $out = '';
    for my $p (@$ent) {
        if ($p->[0] == 0) { $out .= $p->[1]; next }
        my (undef, $flags, $width, $prec, $conv, $lm) = @$p;
        my $w;
        if ($width eq '*') {
            $w = shift;
            if ($w < 0) { $flags .= '-'; $w = -$w }
        } else {
            $w = $width eq '' ? 0 : 0 + $width;
        }
        if (defined $prec) {
            if ($prec eq '*') { my $pr = shift; $prec = $pr >= 0 ? $pr : undef }
            else { $prec = $prec eq '' ? 0 : 0 + $prec }
        }
        my $a = shift;
        if ($conv eq 's') {
            my $sv = defined($a) ? rt_bytes($a) : '(null)';
            $sv = substr($sv, 0, $prec) if defined $prec;
            $out .= rt_pad($sv, $w, index($flags, '-') >= 0);
        } elsif ($conv eq 'c') {
            $out .= rt_pad(chr($a & 255), $w, index($flags, '-') >= 0);
        } elsif ($conv =~ /\A[fFeEgG]\z/) {
            $out .= rt_fmt_float($a, $flags, $w, $prec, $conv);
        } elsif ($conv =~ /\A[diuxXo]\z/) {
            $out .= rt_fmt_int(int($a), $flags, $w, $prec, $conv, $lm);
        } else {
            die "printf %$conv\n";
        }
    }
    return $out;
}

sub c_fprintf {
    my $f = shift;
    my $b = rt_format(@_);
    return -1 if !defined $f;
    print { $f->{fh} } $b;
    return length($b);
}

sub c_snprintf {
    my $buf = shift;
    my $n = shift;
    my $b = rt_format(@_);
    if ($n > 0) {
        my $m = length($b) < $n - 1 ? length($b) : $n - 1;
        substr(${$buf->[0]}, $buf->[1], $m + 1, substr($b, 0, $m) . "\0");
    }
    return length($b);
}

# ------------------------------------------------------------------- files
# FILE*: { fh => Perl filehandle, eof => C's end-of-file flag, std => stdout/stderr, pend => the rest of a line
# longer than an fgets buffer }
my ($cstdout, $cstderr);

sub rt_stdout { return $cstdout //= { fh => \*STDOUT, eof => 0, std => 1, pend => '' } }
sub rt_stderr { return $cstderr //= { fh => \*STDERR, eof => 0, std => 1, pend => '' } }

my %MODES = ('r' => '<', 'w' => '>', 'a' => '>>', 'r+' => '+<', 'w+' => '+>', 'a+' => '+>>');

sub c_fopen {
    my $fn = rt_bytes($_[0]);
    my $m = rt_bytes($_[1]);
    $m =~ s/[bt]//g;
    my $pm = $MODES{$m} or return undef;
    return undef if $fn eq '';
    open(my $fh, $pm . ':raw', $fn) or return undef;
    return { fh => $fh, eof => 0, std => 0, pend => '' };
}

sub c_fclose {
    my $f = $_[0];
    return -1 if !defined $f;
    if ($f->{std}) { $f->{fh}->flush } else { close($f->{fh}) }
    return 0;
}

sub c_fflush { $_[0]->{fh}->flush if defined $_[0]; return 0 }
sub c_feof { return $_[0]->{eof} ? 1 : 0 }

sub c_rewind {
    my $f = $_[0];
    seek($f->{fh}, 0, 0);
    $f->{pend} = '';
    $f->{eof} = 0;
}

sub c_fseek {
    my ($f, $off, $whence) = @_;
    $off -= length($f->{pend}) if $whence == 1;
    $f->{pend} = '';
    $f->{eof} = 0;
    return seek($f->{fh}, $off, $whence) ? 0 : -1;
}

sub c_ftell { return tell($_[0]->{fh}) - length($_[0]->{pend}) }

sub c_fgets {
    my ($buf, $n, $f) = @_;
    my $line;
    if ($f->{pend} ne '') {
        $line = $f->{pend};
        $f->{pend} = '';
    } else {
        local $/ = "\n";
        $line = readline($f->{fh});
    }
    if (!defined($line) || $line eq '') {
        $f->{eof} = 1;
        return undef;
    }
    if (length($line) > $n - 1) {
        $f->{pend} = substr($line, $n - 1);
        $line = substr($line, 0, $n - 1);
    } elsif (substr($line, -1) ne "\n") {
        $f->{eof} = 1;
    }
    substr(${$buf->[0]}, $buf->[1], length($line) + 1, $line . "\0");
    return $buf;
}

sub c_remove { return unlink(rt_bytes($_[0])) ? 0 : -1 }

# pack() codes and natural sizes for fread/fwrite element types
my %PACK = (d => ['d<', 8], f => ['f<', 4], i => ['l<', 4], I => ['L<', 4], q => ['q<', 8]);

sub c_fwrite1 {
    my ($code, $size, $v, $f) = @_;
    if ($code eq 'c') { print { $f->{fh} } chr($v & 255); return 1 }
    my ($fm, $nat) = @{$PACK{$code}};
    my $b = pack($fm, $v);
    print { $f->{fh} } ($size == $nat ? $b : substr($b, 0, $size));
    return 1;
}

sub c_fread1 {
    my ($code, $size, undef, $f) = @_;
    my ($fm, $nat) = @{$PACK{$code}};
    my $b;
    my $got = read($f->{fh}, $b, $size);
    if (!$got || $got < $size) { $f->{eof} = 1; return 0 }
    $b .= substr(pack($fm, $_[2]), $size, $nat - $size) if $size != $nat;
    $_[2] = unpack($fm, $b);
    return 1;
}

sub c_fwrite_arr {
    my ($code, $size, $arr, $off, $n, $f) = @_;
    return 0 if $n <= 0;
    if ($code eq 'c') { print { $f->{fh} } substr(${$arr->[0]}, $arr->[1] + $off, $n); return $n }
    my ($fm) = @{$PACK{$code}};
    print { $f->{fh} } pack($fm . $n, @{$arr}[$off .. $off + $n - 1]);
    return $n;
}

sub c_fread_arr {
    my ($code, $size, $arr, $off, $n, $f) = @_;
    my $b = '';
    if ($code eq 'c') {
        read($f->{fh}, $b, $n) if $n > 0;
        substr(${$arr->[0]}, $arr->[1] + $off, length($b), $b);
        $f->{eof} = 1 if length($b) < $n;
        return length($b);
    }
    my ($fm, $nat) = @{$PACK{$code}};
    read($f->{fh}, $b, $n * $nat) if $n > 0;
    my $m = int(length($b) / $nat);
    my @v = unpack($fm . $m, $b);
    @{$arr}[$off .. $off + $m - 1] = @v if $m > 0;
    $f->{eof} = 1 if $m < $n;
    return $m;
}

# ------------------------------------------------------------------- time
sub c_time { return time() }
sub c_ctime { return c_lit(POSIX::strftime("%a %b %e %H:%M:%S %Y\n", localtime($_[0]))) }

1;
