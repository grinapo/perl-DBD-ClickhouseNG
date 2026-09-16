use v5.40;
use Test::More;
use DBI;

BEGIN {
    use_ok( 'DBD::ClickhouseNG' );
    use_ok( 'DBD::ClickhouseNG::HTTP' );
}

subtest 'unreachable host fails cleanly' => sub {
    my $dbh = DBI->connect(
        'dbi:ClickhouseNG:host=127.0.0.1;port=1;timeout=1', '', '',
        { RaiseError => 0, PrintError => 0 },
    );
    ok( !defined $dbh, 'connect fails' );
    is( $DBI::err, 1 );
    is( $DBI::state, '08001' );
    ok( length $DBI::errstr, 'errstr populated' );
};

subtest 'unreachable host raises with RaiseError' => sub {
    eval {
        DBI->connect(
            'dbi:ClickhouseNG:host=127.0.0.1;port=1;timeout=1', '', '',
            { RaiseError => 1, PrintError => 0 },
        );
    };
    ok( $@, 'died' );
};

done_testing;
