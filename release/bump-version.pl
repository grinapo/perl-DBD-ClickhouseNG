#!/usr/bin/env perl
# Set a new release version everywhere it is written by hand:
#   - $VERSION in lib/DBD/ClickhouseNG.pm
#   - "version" in META.json (edited in place, formatting kept)
#   - Changes: a new top heading "NEW  YYYY-MM-DD" (fill in the entries),
#     or with --amend the existing top heading renamed to NEW and today's
#     date (for repeated releases that share one Changes entry).
# t/02-version.t checks that these three agree.
#
# Versions are plain decimals (0.53, 0.5301, ...), and NEW must sort above
# the current one under Perl's version rules.
#
# Usage: release/bump-version.pl NEW [--amend]

use v5.40;
use File::Basename qw( dirname );
use File::Spec ();
use ExtUtils::MakeMaker ();
use JSON::PP ();
use POSIX qw( strftime );
use version ();

my( $new, $amend );
for my $arg ( @ARGV ) {
    if( $arg eq '--amend' ) { $amend = 1 }
    elsif( !defined $new && $arg =~ /\A[0-9]+\.[0-9]+\z/ ) { $new = $arg }
    else { die "usage: $0 NEW [--amend]   (NEW is a plain decimal, e.g. 0.5301)\n" }
}
die "usage: $0 NEW [--amend]   (NEW is a plain decimal, e.g. 0.5301)\n" unless defined $new;

my $root    = File::Spec->catdir( dirname( File::Spec->rel2abs( __FILE__ ) ), File::Spec->updir );
my $pm      = "$root/lib/DBD/ClickhouseNG.pm";
my $metaf   = "$root/META.json";
my $changes = "$root/Changes";

my $old = MM->parse_version( $pm );
die "release: new version $new must be higher than the current $old\n"
    unless version->parse( $new ) > version->parse( $old );

sub slurp( $file ) {
    open my $fh, '<:raw', $file or die "release: $file: $!\n";
    local $/;
    return scalar <$fh>;
}

sub spew( $file, $content ) {
    open my $fh, '>:raw', "$file.tmp" or die "release: $file.tmp: $!\n";
    print {$fh} $content or die "release: $file.tmp: $!\n";
    close $fh or die "release: $file.tmp: $!\n";
    rename "$file.tmp", $file or die "release: $file: $!\n";
}

# Compute all three edits first, write only if every one applies.
my $pm_src = slurp( $pm );
1 == ( $pm_src =~ s/^(our \$VERSION = )'[^']*';/$1'$new';/mg )
    or die "release: no unique \"our \$VERSION = '...';\" line in $pm\n";

my $meta_src = slurp( $metaf );
$meta_src =~ s/^(   "version" : )"[^"]*"/$1"$new"/m
    or die "release: no top-level \"version\" line in $metaf\n";
JSON::PP->new->decode( $meta_src )->{version} eq $new
    or die "release: edited the wrong \"version\" in $metaf\n";

my $today       = strftime( '%Y-%m-%d', localtime );
my $heading     = sprintf "%-6s %s", $new, $today;
my $changes_src = slurp( $changes );
if( $amend ) {
    $changes_src =~ s/\A(.*\n\n)\S+[ \t]+\S+[ \t]*$/$1$heading/m
        or die "release: no top entry heading found in $changes\n";
}
else {
    $changes_src =~ s/\A(.*\n\n)/$1$heading\n\n/
        or die "release: unexpected header in $changes\n";
}

spew( $pm, $pm_src );
spew( $metaf, $meta_src );
spew( $changes, $changes_src );

say "release: version $old -> $new (lib/DBD/ClickhouseNG.pm, META.json, Changes)";
say $amend
    ? "release: renamed the top Changes entry to '$heading'"
    : "release: added Changes heading '$heading' -- write its entries";
