use v5.40;
use Test::More;
use ExtUtils::MakeMaker ();
use JSON::PP ();

# The version is written in three places; release/bump-version.pl updates
# all of them. They must agree, and $VERSION must be a plain decimal
# (0.52, 0.5201, ...): a dotted 0.52.03 sorts *below* 0.51 for Perl/CPAN.

my $version = MM->parse_version( 'lib/DBD/ClickhouseNG.pm' );
like( $version, qr/\A[0-9]+\.[0-9]+\z/, "\$VERSION '$version' is a plain decimal" );

my $meta = do {
    open my $fh, '<:raw', 'META.json' or die "META.json: $!";
    local $/;
    JSON::PP->new->decode( <$fh> );
};
is( $meta->{version}, $version, 'META.json version matches $VERSION' );

my( $changes ) = do {
    open my $fh, '<:encoding(UTF-8)', 'Changes' or die "Changes: $!";
    <$fh>;    # "Revision history for ..."
    my $top;
    while( my $line = <$fh> ) {
        if( $line =~ /\A(\S+)\s/ ) { $top = $1; last }
    }
    $top;
};
is( $changes, $version, 'top Changes entry matches $VERSION' );

done_testing;
