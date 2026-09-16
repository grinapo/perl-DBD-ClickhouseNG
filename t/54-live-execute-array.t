use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $dbh = DBI->connect( $dsn, $ENV{CHNG_TEST_USER}, $ENV{CHNG_TEST_PASS},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );

my $table = 'dbd_chng_test_54_' . $$;

END {
    $dbh->do( "DROP TABLE IF EXISTS $table" ) if $dbh;
}

$dbh->do( "CREATE TABLE $table (id UInt32, name String) ENGINE = Memory" );

subtest 'execute_array fast path: real batch insert via bind_param_array' => sub {
    my $sth = $dbh->prepare( "INSERT INTO $table (id, name) VALUES (?, ?)" );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );
    $sth->bind_param_array( 2, [ 'alice', 'bob', q{o'brien} ] );
    my @tuple_status;
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );
    is( $tuples, 3 );
    is_deeply( \@tuple_status, [ -1, -1, -1 ] );

    my( $count ) = $dbh->selectrow_array( "SELECT count(*) FROM $table" );
    is( $count, 3 );
    my $rows = $dbh->selectall_arrayref( "SELECT id, name FROM $table ORDER BY id" );
    is_deeply( $rows, [ [ 1, 'alice' ], [ 2, 'bob' ], [ 3, q{o'brien} ] ],
        q{quote-escaped value round-trips correctly through the batched literal SQL} );
};

subtest 'non-ASCII characters survive the fast path\'s distinct encoding route (literal embedding, not param_*)' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my $sth = $dbh->prepare( "INSERT INTO $table (id, name) VALUES (?, ?)" );
    my @values = ( "h\x{e9}llo", "caf\x{e9} \x{4e2d}\x{6587}", 'plain' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );
    $sth->bind_param_array( 2, \@values );
    my $tuples = $sth->execute_array( {} );
    is( $tuples, 3 );

    my $rows = $dbh->selectall_arrayref( "SELECT name FROM $table ORDER BY id" );
    is_deeply( [ map { $_->[0] } @$rows ], \@values,
        'non-ASCII characters round-trip correctly through the batched literal SQL (a distinct encoding path from param_*)' );
};

subtest 'malicious string values are inserted as inert data, never executed as SQL' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my $sth = $dbh->prepare( "INSERT INTO $table (id, name) VALUES (?, ?)" );
    my @tricky = (
        q{'; DROP TABLE users; --},
        q{x' OR '1'='1},
        "line\nbreak",
        "back\\slash",
    );
    $sth->bind_param_array( 1, [ 1 .. scalar @tricky ] );
    $sth->bind_param_array( 2, \@tricky );
    my $tuples = $sth->execute_array( {} );
    is( $tuples, scalar @tricky );

    # If any of these had been executed as SQL, the table itself would be
    # gone (or corrupted) by now -- so simply being able to query it back
    # with the exact original values is the real assertion here.
    my $rows = $dbh->selectall_arrayref( "SELECT name FROM $table ORDER BY id" );
    is_deeply( [ map { $_->[0] } @$rows ], \@tricky );

    my( $exists ) = $dbh->selectrow_array(
        "SELECT count(*) FROM system.tables WHERE database = currentDatabase() AND name = '$table'" );
    is( $exists, 1, 'the target table itself is unharmed' );
};

subtest 'atomicity: a batch with one uncastable value rejects as a whole (uniform failure mode)' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    # id is UInt32; 'not-a-number' cannot cast, forcing a genuine
    # server-side rejection of the whole batched INSERT.
    my $sth = $dbh->prepare( "INSERT INTO $table (id, name) VALUES (?, ?)" );
    $sth->bind_param_array( 1, [ 1, 2, 'not-a-number' ] );
    $sth->bind_param_array( 2, [ 'ok1', 'ok2', 'ok3' ] );

    my @tuple_status;
    local $sth->{RaiseError} = 0;
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );
    ok( !defined $tuples, 'execute_array reports failure' );
    is( scalar @tuple_status, 3 );
    ok( ( ref $tuple_status[0] and ref $tuple_status[1] and ref $tuple_status[2] ),
        'every tuple carries the same shared failure status' );

    my( $count ) = $dbh->selectrow_array( "SELECT count(*) FROM $table" );
    is( $count, 0, 'nothing was committed -- the whole batch was rejected atomically' );
};

subtest 'retry-on-error mode isolates exactly the bad row and keeps the good ones' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my $sth = $dbh->prepare( "INSERT INTO $table (id, name) VALUES (?, ?)" );
    $sth->bind_param_array( 1, [ 1, 2, 'not-a-number' ] );
    $sth->bind_param_array( 2, [ 'ok1', 'ok2', 'ok3' ] );

    my @tuple_status;
    local $sth->{RaiseError} = 0;
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );
    ok( !defined $tuples, 'overall result still reports failure (one row genuinely failed)' );
    is( $tuple_status[0], -1, 'row 1 succeeded on retry' );
    is( $tuple_status[1], -1, 'row 2 succeeded on retry' );
    ok( ref $tuple_status[2], 'row 3 (the bad one) carries its own specific error' );

    my( $count ) = $dbh->selectrow_array( "SELECT count(*) FROM $table" );
    is( $count, 2, 'the two good rows were retried and committed individually' );
};

done_testing;
