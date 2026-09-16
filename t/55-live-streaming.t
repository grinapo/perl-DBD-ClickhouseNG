use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $user = $ENV{CHNG_TEST_USER};
my $pass = $ENV{CHNG_TEST_PASS};

subtest 'bounded-batch streaming fetch reads a large result set correctly' => sub {
    my $dbh = DBI->connect( $dsn, $user, $pass,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
    my $sth = $dbh->prepare( 'SELECT number FROM numbers(100000)' );
    $sth->{chng_fetch_batch_rows} = 1000;
    $sth->execute;
    is( $sth->rows, -1, 'row count is unknown ahead of a full streamed scan' );

    my $n = 0;
    while( my $row = $sth->fetch ) {
        is( $row->[0], $n, "row $n in order" ) if $n < 5 || $n > 99994;
        $n++;
    }
    is( $n, 100000, 'all 100000 rows were fetched across many internal batches' );
    $dbh->disconnect;
};

subtest 'finish() after a partial streaming fetch leaves the connection usable' => sub {
    my $dbh = DBI->connect( $dsn, $user, $pass,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
    my $sth = $dbh->prepare( 'SELECT number FROM numbers(50000)' );
    $sth->{chng_fetch_batch_rows} = 500;
    $sth->execute;
    $sth->fetch for 1 .. 10;
    $sth->finish;

    my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
    is( $one, 1, 'a plain (non-streaming) query still works on the same handle after finish()' );
    $dbh->disconnect;
};

subtest 'an INSERT (no result set) on a streaming-enabled connection succeeds cleanly' => sub {
    my $dbh = DBI->connect( $dsn, $user, $pass,
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
    $dbh->{chng_fetch_batch_rows} = 1000;    # streaming on for every statement, including this INSERT
    my $table = 'dbd_chng_test_55_' . $$;
    $dbh->do( "CREATE TABLE $table (id UInt32) ENGINE = Memory" );

    my $sth = $dbh->prepare( "INSERT INTO $table (id) VALUES (?)" );
    my $rv = eval { $sth->execute( 42 ) };
    ok( !$@, 'execute did not die' )
        or diag $@;
    ok( $rv, 'execute reports success on an empty-body (no result set) response' );

    my( $count ) = $dbh->selectrow_array( "SELECT count(*) FROM $table" );
    is( $count, 1, 'the row was actually inserted' );

    $dbh->do( "DROP TABLE IF EXISTS $table" );
    $dbh->disconnect;
};

subtest 'an error on the streaming path is reported cleanly, not mid-stream' => sub {
    my $dbh = DBI->connect( $dsn, $user, $pass,
        { RaiseError => 0, PrintError => 0, AutoCommit => 1 } );
    my $sth = $dbh->prepare( 'SELECT * FROM this_table_does_not_exist_dbd_chng' );
    $sth->{chng_fetch_batch_rows} = 100;
    my $rv = $sth->execute;
    ok( !defined $rv, 'execute fails' );
    ok( $sth->err, 'err is set' );
    like( $sth->errstr, qr/this_table_does_not_exist_dbd_chng|UNKNOWN_TABLE|doesn.t exist/i );
    $dbh->disconnect;
};

done_testing;
