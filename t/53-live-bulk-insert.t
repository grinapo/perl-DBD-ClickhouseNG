use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $dbh = DBI->connect( $dsn, $ENV{CHNG_TEST_USER}, $ENV{CHNG_TEST_PASS},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );

my $table = 'dbd_chng_test_53_' . $$;

END {
    $dbh->do( "DROP TABLE IF EXISTS $table" ) if $dbh;
}

$dbh->do( "CREATE TABLE $table (id UInt32, name String) ENGINE = Memory" );

subtest 'bulk insert via raw multi-row SQL in a single do() call' => sub {
    my $n = 500;
    my @rows = map { [ $_, "row $_" ] } 1 .. $n;

    my $sql = "INSERT INTO $table VALUES " . join( ',', map {
        '(' . join( ',', $_->[0], $dbh->quote( $_->[1] ) ) . ')'
    } @rows );

    ok( $dbh->do( $sql ), 'bulk insert succeeded' );

    my( $count ) = $dbh->selectrow_array( "SELECT count(*) FROM $table" );
    is( $count, $n, 'row count matches' );

    my $got = $dbh->selectall_arrayref( "SELECT id, name FROM $table ORDER BY id" );
    is_deeply( $got, \@rows, 'values match' );
};

done_testing;
