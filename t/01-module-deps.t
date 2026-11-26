use v5.40;
use Test::More;

# Enforces the module dependency rules from "Module map" in CLAUDE.md:
# every reference to another DBD::ClickhouseNG::* package (use lines and
# fully-qualified calls/variables) must be on the referring module's
# allowed list. Root-package variables ($JSON_CLASS, $VERSION) are listed
# per module too. A module missing from %ALLOWED fails, so new modules
# must be added here (and to the module map) deliberately.

my %ALLOWED = (
    ''           => [ qw(dr db st) ],
    dr           => [ qw(HTTP Error) ],
    db           => [ qw(Placeholders Types Error Catalog JSON_CLASS) ],
    st           => [ qw(Placeholders Types Error JSON_CLASS) ],
    Catalog      => [ qw(Types VERSION) ],
    Placeholders => [],
    Types        => [],
    Error        => [],
    HTTP         => [],
);

my @files = ( 'lib/DBD/ClickhouseNG.pm', sort glob 'lib/DBD/ClickhouseNG/*.pm' );

for my $file ( @files ) {
    my( $mod ) = $file =~ m{\Alib/DBD/ClickhouseNG(?:/(\w+))?\.pm\z};
    $mod //= '';
    my $label = length $mod ? $mod : 'DBD::ClickhouseNG';

    ok( exists $ALLOWED{$mod}, "$label has a dependency rule" ) or next;
    my %ok = map { $_ => 1 } $mod, @{ $ALLOWED{$mod} };

    open my $fh, '<:encoding(UTF-8)', $file or die "$file: $!";
    my( %bad, $in_pod );
    while( my $line = <$fh> ) {
        last if $line =~ /\A__END__\b/;
        if( $line =~ /\A=(\w+)/ ) { $in_pod = ( $1 ne 'cut' ); next; }
        next if $in_pod || $line =~ /\A\s*#/;
        while( $line =~ /\bDBD::ClickhouseNG::(\w+)/g ) {
            push @{ $bad{$1} }, $. unless $ok{$1};
        }
    }
    close $fh;

    ok( !%bad, "$label references only allowed modules" )
        or diag map { "  $label -> $_ (line @{ $bad{$_} })\n" } sort keys %bad;
}

done_testing;
