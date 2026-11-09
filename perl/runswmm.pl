# runswmm for the Perl port: same command line and console messages as EPA's run/main.c.
#   perl perl/runswmm.pl <input file> <report file> [output file]
# Written by Claude (Anthropic) for Robert Dickinson; see perl/README.md.
package SWMM5;
use strict;
use warnings FATAL => 'all';
use File::Basename ();
use Time::HiRes ();

use File::Spec ();
my $here = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/swmm5';
require "$here/crt.pl";
require "$here/engine.pl";
require "$here/overrides.pl";
init_globals();

sub swmm_main {
    my @argv = @_;
    my $version = swmm_getVersion();
    my $vMajor = int($version / 10000);
    my $vMinor = int(($version - 10000 * $vMajor) / 1000);
    my $vRelease = $version - 10000 * $vMajor - 1000 * $vMinor;
    my $start = Time::HiRes::time();
    $| = 0;
    if (@argv == 0) {
        print "\nNot Enough Arguments (See Help --help)\n\n";
    } elsif (@argv == 1) {
        my $a = $argv[0];
        if ($a eq '--help' || $a eq '-h') {
            print "\n\nSTORMWATER MANAGEMENT MODEL (SWMM) HELP\n\n", "COMMANDS:\n", "\t--help (-h)       SWMM Help\n",
                "\t--version (-v)    Build Version\n", "\nRUNNING A SIMULATION:\n",
                "\t runswmm <input file> <report file> <optional output file>\n\n";
        } elsif ($a eq '--version' || $a eq '-v') {
            print "\n$vMajor.$vMinor.$vRelease\n\n";
        } else {
            print "\nUnknown Argument (See Help --help)\n\n";
        }
    } else {
        print "\n... EPA SWMM $vMajor.$vMinor (Build $vMajor.$vMinor.$vRelease) [Perl port]\n";
        STDOUT->flush;
        swmm_run(c_lit($argv[0]), c_lit($argv[1]), c_lit(@argv > 2 ? $argv[2] : ''));
        printf "\n\n... EPA SWMM completed in %.2f seconds.", Time::HiRes::time() - $start;
        my $err = c_buf(128);
        if (swmm_getError($err, 127) > 0) {
            print " There are errors.\n";
        } elsif (swmm_getWarnings() > 0) {
            print " There are warnings.\n";
        } else {
            print "\n";
        }
    }
    STDOUT->flush;
    return 0;
}

exit(swmm_main(@ARGV));
