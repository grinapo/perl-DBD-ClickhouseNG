use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests (e.g. dbi:ClickhouseNG:host=localhost)'
    unless $dsn;

my $user = $ENV{CHNG_TEST_USER};
my $pass = $ENV{CHNG_TEST_PASS};

my $dbh = DBI->connect( $dsn, $user, $pass, { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
ok( $dbh, 'connected' ) or BAIL_OUT( "cannot connect: $DBI::errstr" );

ok( $dbh->ping, 'ping' );

my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
is( $one, 1, 'SELECT 1' );

ok( $dbh->disconnect, 'disconnect' );

subtest 'wrong password fails connect with server exception code' => sub {
    my $bad = DBI->connect( $dsn, $user // 'default', ( $pass // '' ) . 'wrong-suffix-xyz',
        { RaiseError => 0, PrintError => 0 } );
    ok( !defined $bad, 'connect refused' );
    ok( $DBI::err, 'err set' );
    isnt( $DBI::err, 1, 'not a transport-level error' );
};

done_testing;
