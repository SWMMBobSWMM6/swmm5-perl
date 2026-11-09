# Hand-ported pieces of EPA SWMM 5.2.4 that use C pointer arithmetic the translator does not map:
# odesolve.c (whole file), mempool.c (whole file), and six helpers from swmm5.c / project.c.
# Each keeps the C statement order and floating-point expressions exactly (a port of the PHP port's
# overrides.php). Doubles here go through the engine's rules: a +, - or * whose operands may both be integral
# keeps C's sign of a zero result through rt_za/rt_zs/rt_zm (see tools/c2x/emit_perl.py).
# Written by Claude (Anthropic) for Robert Dickinson; see perl/README.md.
package SWMM5;
use strict;
use warnings FATAL => 'all';
use feature 'refaliasing';
no warnings 'experimental::refaliasing';

sub sstrncpy {
    my ($dest, $src, $n) = @_;
    my $offset = 0;
    if ($n > 0) {
        while (cg($src, $offset) != 0) {
            last if $offset == $n;
            cs($dest, $offset, cg($src, $offset));
            $offset++;
        }
    }
    cs($dest, $offset, 0);
    return c_strlen($dest);
}

sub sstrcat {
    my ($dest, $src, $size) = @_;
    my $offset = c_strlen($dest);
    my $srcIndex = 0;
    while (cg($src, $srcIndex) != 0) {
        cs($dest, $offset, cg($src, $srcIndex));
        $offset++;
        $srcIndex++;
        last if $offset == $size - 1;
    }
    cs($dest, $offset, 0);
    return c_strlen($dest);
}

sub getAbsolutePath {
    my ($fname, $absPath, $size) = @_;
    return if !defined($fname) || c_strlen($fname) == 0;
    if (isRelativePath($fname) != 0) {
        require Cwd;
        my $full = Cwd::realpath(rt_bytes($fname));
        return if !defined $full;
        my $room = length(${$absPath->[0]}) - $absPath->[1] - 1;
        $full = substr($full, 0, $room) if length($full) > $room;
        substr(${$absPath->[0]}, $absPath->[1], length($full) + 1, $full . "\0");
    } else {
        sstrncpy($absPath, $fname, c_strlen($fname));
    }
    my $endOfDir = c_strrchr($absPath, 47);
    cs($endOfDir, 1, 0) if defined $endOfDir;
}

my @MKS = ('a' .. 'z', 'A' .. 'Z', '0' .. '9');

sub c_mkstemp {
    my $template = $_[0];
    my $n = c_strlen($template);
    for my $tries (1 .. 1000) {
        for my $i ($n - 6 .. $n - 1) { cs($template, $i, ord($MKS[int(rand(62))])) }
        my $name = rt_bytes($template);
        if (sysopen(my $fh, $name, POSIX::O_WRONLY() | POSIX::O_CREAT() | POSIX::O_EXCL(), 0600)) {
            close($fh);
            return 3;
        }
    }
    return -1;
}

sub getTempFileName {
    my ($fname) = @_;
    sstrncpy($fname, c_lit('swmmXXXXXX'), 259);
    c_mkstemp($fname);
    return $fname;
}

sub project_createMatrix {
    my ($nrows, $ncols) = @_;
    return undef if $nrows <= 0 || $ncols <= 0;
    # EPA zeroes only an eighth of the matrix (lessons/02, defect 5); the ports zero all of it
    return rt_arr2($nrows, $ncols, 0.0);
}

sub project_freeMatrix { return }

# ------------------------------------------------------------------ mempool.c
sub AllocInit { return {} }
sub Alloc { return c_buf($_[0]) }
sub AllocSetPool { return $_[0] }
sub AllocReset { return }
sub AllocFreePool { return }

# ------------------------------------------------------------------ odesolve.c (Cash-Karp Runge-Kutta)
my ($nmax, $y, $yscal, $dydx, $yerr, $ytemp, $ak2, $ak3, $ak4, $ak5, $ak6) = (0);

use constant {
    ODE_MAXSTP => 10000, ODE_TINY => 1.0e-30, ODE_SAFETY => 0.9, ODE_PGROW => -0.2, ODE_PSHRNK => -0.25,
    ODE_ERRCON => 1.89e-4,
};

sub odesolve_open {
    my ($n) = @_;
    $nmax = 0;
    ($y, $yscal, $dydx, $yerr, $ytemp, $ak2, $ak3, $ak4, $ak5, $ak6) = map { rt_arr($n, 0.0) } 1 .. 10;
    $nmax = $n;
    return 1;
}

sub odesolve_close {
    ($y, $yscal, $dydx, $yerr, $ytemp, $ak2, $ak3, $ak4, $ak5, $ak6) = ();
    $nmax = 0;
    return;
}

sub odesolve_integrate {
    my ($ystart, $n, $x1, $x2, $eps, $h1, $derivs) = @_;
    my ($hdid, $hnext) = (0.0, 0.0);
    my $x = $x1;
    my $h = $h1;
    my $t;
    return 1 if $nmax < $n;
    for (my $i = 0; $i < $n; $i++) { $y->[$i] = $ystart->[$i] }
    for (my $nstp = 1; $nstp <= ODE_MAXSTP; $nstp++) {
        $derivs->($x, $y, $dydx);
        for (my $i = 0; $i < $n; $i++) {
            # fabs(y[i]) + fabs(dydx[i]*h) + TINY
            my $p = (($t = $dydx->[$i] * $h) || rt_zm($dydx->[$i], $h));
            my $q = abs($y->[$i]);
            my $r = abs($p);
            $yscal->[$i] = (($t = $q + $r) || rt_za($q, $r)) + ODE_TINY;
        }
        # if ((x+h-x2)*(x+h-x1) > 0.0) h = x2 - x;
        my $xh = (($t = $x + $h) || rt_za($x, $h));
        my $u = (($t = $xh - $x2) || rt_zs($xh, $x2));
        my $v = (($t = $xh - $x1) || rt_zs($xh, $x1));
        if ((($t = $u * $v) || rt_zm($u, $v)) > 0.0) { $h = (($t = $x2 - $x) || rt_zs($x2, $x)) }
        my $errcode = ode_rkqs($x, $n, $h, $eps, $hdid, $hnext, $derivs);
        last if $errcode;
        # if ((x-x2)*(x2-x1) >= 0.0)
        $u = (($t = $x - $x2) || rt_zs($x, $x2));
        $v = (($t = $x2 - $x1) || rt_zs($x2, $x1));
        if ((($t = $u * $v) || rt_zm($u, $v)) >= 0.0) {
            for (my $i = 0; $i < $n; $i++) { $ystart->[$i] = $y->[$i] }
            return 0;
        }
        return 2 if abs($hnext) <= 0.0;
        $h = $hnext;
    }
    return 3;
}

# x, hdid, hnext are the caller's variables (C passes their addresses)
sub ode_rkqs {
    \my $x = \$_[0];
    my ($n, $htry, $eps) = @_[1 .. 3];
    \my $hdid = \$_[4];
    \my $hnext = \$_[5];
    my $derivs = $_[6];
    my $xold = $x;
    my $h = $htry;
    my $t;
    for (;;) {
        ode_rkck($xold, $n, $h, $derivs);
        my $errmax = 0.0;
        for (my $i = 0; $i < $n; $i++) {
            my $err = abs($yscal->[$i] == 0.0 ? rt_fdiv0($yerr->[$i], $yscal->[$i]) : $yerr->[$i] / $yscal->[$i]);
            $errmax = $err if $err > $errmax;
        }
        $errmax = $eps == 0.0 ? rt_fdiv0($errmax, $eps) : $errmax / $eps;
        if ($errmax > 1.0) {
            my $p = ODE_SAFETY * $h;
            my $q = $errmax ** ODE_PSHRNK;
            my $htemp = (($t = $p * $q) || rt_zm($p, $q));
            if ($h >= 0) {
                $h = $htemp > 0.1 * $h ? $htemp : 0.1 * $h;
            } else {
                $h = $htemp < 0.1 * $h ? $htemp : 0.1 * $h;
            }
            my $xnew = (($t = $xold + $h) || rt_za($xold, $h));
            return 2 if $xnew == $xold;
            next;
        }
        if ($errmax > ODE_ERRCON) {
            my $p = ODE_SAFETY * $h;
            my $q = $errmax ** ODE_PGROW;
            $hnext = (($t = $p * $q) || rt_zm($p, $q));
        } else {
            $hnext = (($t = 5.0 * $h) || rt_zm(5.0, $h));
        }
        $hdid = $h;
        $x = (($t = $x + $hdid) || rt_za($x, $hdid));
        for (my $i = 0; $i < $n; $i++) { $y->[$i] = $ytemp->[$i] }
        return 0;
    }
}

use constant {
    ODE_A2 => 0.2, ODE_A3 => 0.3, ODE_A4 => 0.6, ODE_A5 => 1.0, ODE_A6 => 0.875,
    ODE_B21 => 0.2, ODE_B31 => 3.0 / 40.0, ODE_B32 => 9.0 / 40.0, ODE_B41 => 0.3, ODE_B42 => -0.9, ODE_B43 => 1.2,
    ODE_B51 => -11.0 / 54.0, ODE_B52 => 2.5, ODE_B53 => -70.0 / 27.0, ODE_B54 => 35.0 / 27.0,
    ODE_B61 => 1631.0 / 55296.0, ODE_B62 => 175.0 / 512.0, ODE_B63 => 575.0 / 13824.0,
    ODE_B64 => 44275.0 / 110592.0, ODE_B65 => 253.0 / 4096.0, ODE_C1 => 37.0 / 378.0,
    ODE_C3 => 250.0 / 621.0, ODE_C4 => 125.0 / 594.0, ODE_C6 => 512.0 / 1771.0, ODE_DC5 => -277.0 / 14336.0,
};
use constant {
    ODE_DC1 => ODE_C1 - 2825.0 / 27648.0, ODE_DC3 => ODE_C3 - 18575.0 / 48384.0,
    ODE_DC4 => ODE_C4 - 13525.0 / 55296.0, ODE_DC6 => ODE_C6 - 0.25,
};

# the Cash-Karp step, one C operation at a time. A product with one of the non-integral coefficients is a
# double multiplication in Perl too; every other +, - and * keeps C's sign of a zero result (rt_za/rt_zs/rt_zm)
sub ode_rkck {
    my ($x, $n, $h, $derivs) = @_;
    my ($t, $p, $q, $r, $s);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_B21 * $h;
        $q = (($t = $p * $dydx->[$i]) || rt_zm($p, $dydx->[$i]));
        $ytemp->[$i] = (($t = $y->[$i] + $q) || rt_za($y->[$i], $q));
    }
    $p = ODE_A2 * $h;
    $derivs->((($t = $x + $p) || rt_za($x, $p)), $ytemp, $ak2);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_B31 * $dydx->[$i];
        $q = ODE_B32 * $ak2->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $s = (($t = $h * $r) || rt_zm($h, $r));
        $ytemp->[$i] = (($t = $y->[$i] + $s) || rt_za($y->[$i], $s));
    }
    $p = ODE_A3 * $h;
    $derivs->((($t = $x + $p) || rt_za($x, $p)), $ytemp, $ak3);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_B41 * $dydx->[$i];
        $q = ODE_B42 * $ak2->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $q = ODE_B43 * $ak3->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $s = (($t = $h * $r) || rt_zm($h, $r));
        $ytemp->[$i] = (($t = $y->[$i] + $s) || rt_za($y->[$i], $s));
    }
    $p = ODE_A4 * $h;
    $derivs->((($t = $x + $p) || rt_za($x, $p)), $ytemp, $ak4);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_B51 * $dydx->[$i];
        $q = ODE_B52 * $ak2->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $q = ODE_B53 * $ak3->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_B54 * $ak4->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $s = (($t = $h * $r) || rt_zm($h, $r));
        $ytemp->[$i] = (($t = $y->[$i] + $s) || rt_za($y->[$i], $s));
    }
    $p = (($t = ODE_A5 * $h) || rt_zm(ODE_A5, $h));          # a5 = 1.0 is integral
    $derivs->((($t = $x + $p) || rt_za($x, $p)), $ytemp, $ak5);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_B61 * $dydx->[$i];
        $q = ODE_B62 * $ak2->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $q = ODE_B63 * $ak3->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_B64 * $ak4->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_B65 * $ak5->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $s = (($t = $h * $r) || rt_zm($h, $r));
        $ytemp->[$i] = (($t = $y->[$i] + $s) || rt_za($y->[$i], $s));
    }
    $p = ODE_A6 * $h;
    $derivs->((($t = $x + $p) || rt_za($x, $p)), $ytemp, $ak6);
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_C1 * $dydx->[$i];
        $q = ODE_C3 * $ak3->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $q = ODE_C4 * $ak4->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_C6 * $ak6->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $s = (($t = $h * $r) || rt_zm($h, $r));
        $ytemp->[$i] = (($t = $y->[$i] + $s) || rt_za($y->[$i], $s));
    }
    for (my $i = 0; $i < $n; $i++) {
        $p = ODE_DC1 * $dydx->[$i];
        $q = ODE_DC3 * $ak3->[$i];
        $r = (($t = $p + $q) || rt_za($p, $q));
        $q = ODE_DC4 * $ak4->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_DC5 * $ak5->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $q = ODE_DC6 * $ak6->[$i];
        $r = (($t = $r + $q) || rt_za($r, $q));
        $yerr->[$i] = (($t = $h * $r) || rt_zm($h, $r));
    }
}

1;
