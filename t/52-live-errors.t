use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $dbh = DBI->connect( $dsn, $ENV{CHNG_TEST_USER}, $ENV{CHNG_TEST_PASS},
    { RaiseError => 0, PrintError => 0, AutoCommit => 1 } );
ok( $dbh, 'connected' ) or BAIL_OUT( "cannot connect: $DBI::errstr" );

subtest 'syntax error' => sub {
    my $rv = $dbh->do( 'SELECT ~~~ FROM' );
    ok( !defined $rv );
    ok( $dbh->err, 'err is the ClickHouse exception code' );
    isnt( $dbh->err, 1, 'not a transport-level code' );
    ok( length $dbh->errstr, 'errstr has the server message' );
    is( $dbh->state, 'S1000' );
};

subtest 'unknown table' => sub {
    my $rv = $dbh->do( 'SELECT * FROM dbd_chng_test_no_such_table_xyz' );
    ok( !defined $rv );
    ok( $dbh->err );
    like( $dbh->errstr, qr/dbd_chng_test_no_such_table_xyz/ );
    is( $dbh->state, 'S1000' );
};

subtest 'RaiseError dies, RaiseError off returns undef' => sub {
    ok( !defined $dbh->do( 'SELECT ~~~ FROM' ), 'RaiseError off: returns undef' );

    $dbh->{RaiseError} = 1;
    eval { $dbh->do( 'SELECT ~~~ FROM' ) };
    ok( $@, 'RaiseError on: dies' );
    $dbh->{RaiseError} = 0;
};

$dbh->disconnect;
done_testing;
