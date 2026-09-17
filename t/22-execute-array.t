use v5.38;
use Test::More;
use DBI qw(:sql_types);

use DBD::ClickhouseNG;

my @queue;
my @query_calls;
local *DBD::ClickhouseNG::HTTP::query = sub {
    my( $self, $sql, $params ) = @_;
    push @query_calls, [ $sql, $params ];
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

sub connect_ok {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    return DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '',
        { RaiseError => 0, PrintError => 0 } );
}

subtest 'fast path: single batched request for an eligible VALUES(...) insert' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO staff (first_name, last_name) VALUES (?, ?)' );
    $sth->bind_param_array( 1, [ 'John', 'Mary', 'Tim' ] );
    $sth->bind_param_array( 2, [ 'Booth', 'Todd', 'Robinson' ] );

    my $before = scalar @query_calls;
    my @tuple_status;
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );

    is( $tuples, 3 );
    is( scalar( @query_calls ) - $before, 1, 'exactly one HTTP request for 3 rows' );
    is_deeply( \@tuple_status, [ -1, -1, -1 ] );
    like( $query_calls[-1][0], qr/VALUES \('John','Booth'\),\('Mary','Todd'\),\('Tim','Robinson'\)/ );
    ok( !defined $query_calls[-1][1], 'no param_* values -- pure literal SQL, like do()' );
    $dbh->disconnect;
};

subtest 'malicious string values are safely quoted inside the batched SQL, never break out' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ q{'; DROP TABLE users; --}, q{x' OR '1'='1} ] );
    $sth->execute_array( {} );
    my $sql = $query_calls[-1][0];
    like( $sql, qr/VALUES \('\\'; DROP TABLE users; --'\),\('x\\' OR \\'1\\'=\\'1'\)/ );
    $dbh->disconnect;
};

subtest 'non-batchable shape falls back to one execute() call per tuple' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'UPDATE t SET x = ? WHERE id = ?' );
    $sth->bind_param_array( 1, [ 'a', 'b' ] );
    $sth->bind_param_array( 2, [ 1, 2 ] );

    my $before = scalar @query_calls;
    my @tuple_status;
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );

    is( $tuples, 2 );
    is( scalar( @query_calls ) - $before, 2, 'one request per tuple, matching DBI default semantics' );
    is_deeply( \@tuple_status, [ -1, -1 ] );
    $dbh->disconnect;
};

subtest 'zero-length bound arrays: zero tuples, zero HTTP requests' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [] );

    my $before = scalar @query_calls;
    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );

    is( $rv, '0E0' );
    ok( $rv, 'true value' );
    is( scalar( @query_calls ) - $before, 0, 'no request made' );
    is_deeply( \@tuple_status, [] );
    $dbh->disconnect;
};

subtest 'mismatched array lengths: rejected, not silently NULL-padded' => sub {
    my $dbh   = connect_ok();
    my $sth   = $dbh->prepare( 'INSERT INTO t (a,b) VALUES (?,?)' );
    my $before = scalar @query_calls;
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );
    $sth->bind_param_array( 2, [ 'x' ] );
    my $rv = $sth->execute_array( {} );
    is( $rv, undef, 'execute_array fails' );
    like( $sth->errstr, qr/parameter 2 has 1 values, expected 3/ );
    is( scalar( @query_calls ) - $before, 0, 'no request made' );
    $dbh->disconnect;
};

subtest 'all-scalar bind values: exactly one tuple, acts like execute()' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a,b) VALUES (?,?)' );
    $sth->bind_param_array( 1, 42 );
    $sth->bind_param_array( 2, 'same' );
    my $tuples = $sth->execute_array( {} );
    is( $tuples, 1 );
    like( $query_calls[-1][0], qr/VALUES \(42,'same'\)/ );
    $dbh->disconnect;
};

subtest 'column-wise @bind_values argument (no prior bind_param_array calls)' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a,b) VALUES (?,?)' );
    my $tuples = $sth->execute_array( {}, [ 1, 2 ], [ 'x', 'y' ] );
    is( $tuples, 2 );
    like( $query_calls[-1][0], qr/VALUES \(1,'x'\),\(2,'y'\)/ );
    $dbh->disconnect;
};

subtest 'execute_array requires a hashref first argument' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [1] );
    my $rv = eval { $sth->execute_array( 'not-a-hashref' ) };
    ok( !defined $rv );
    like( $sth->errstr, qr/hashref/i );
    $dbh->disconnect;
};

subtest 'execute_array requires bind_param_array for every parameter' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a,b) VALUES (?,?)' );
    $sth->bind_param_array( 1, [1,2] );
    my $rv = $sth->execute_array( {} );
    ok( !defined $rv );
    like( $sth->errstr, qr/parameter 2/ );
    $dbh->disconnect;
};

subtest 'bind_param_array validates the parameter index' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    my $rv = $sth->bind_param_array( 2, [1] );
    ok( !defined $rv );
    like( $sth->errstr, qr/1 parameters/ );
    $rv = $sth->bind_param_array( 0, [1] );
    ok( !defined $rv );
    $dbh->disconnect;
};

subtest 'ArrayTupleFetch is explicitly rejected, never silently ignored' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [1,2] );
    my $rv = $sth->execute_array( { ArrayTupleFetch => sub { undef } } );
    ok( !defined $rv );
    like( $sth->errstr, qr/ArrayTupleFetch/ );
    $dbh->disconnect;
};

subtest 'uniform failure mode (default): one request, all tuples get the same error' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [1,2,3] );

    push @queue, { ok => 0, status => 500, exception_code => 241,
        headers => {}, body => 'Memory limit exceeded' };
    my $before = scalar @query_calls;
    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status } );

    ok( !defined $rv );
    is( scalar( @query_calls ) - $before, 1, 'exactly one request even on failure' );
    is( scalar @tuple_status, 3 );
    for my $s ( @tuple_status ) {
        ok( ref $s eq 'ARRAY', 'every tuple carries an error status' );
        is( $s->[0], 241 );
        like( $s->[1], qr/Memory limit/ );
        is( $s->[2], 'S1000' );
    }
    $dbh->disconnect;
};

subtest 'retry-on-error mode: precise per-row status after a definitive rejection' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );

    push @queue, { ok => 0, status => 500, exception_code => 241, headers => {}, body => 'batch failed' };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };                          # row 1 ok
    push @queue, { ok => 0, status => 500, exception_code => 999, headers => {}, body => 'row 2 bad' }; # row 2 bad
    push @queue, { ok => 1, status => 200, body => '', headers => {} };                          # row 3 ok

    my $before = scalar @query_calls;
    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );

    ok( !defined $rv );
    is( scalar( @query_calls ) - $before, 4, '1 batch attempt + 3 individual retries' );
    is( $tuple_status[0], -1, 'row 1 succeeded' );
    is( ref $tuple_status[1], 'ARRAY', 'row 2 failed, with its own status' );
    is( $tuple_status[1][0], 999 );
    is( $tuple_status[2], -1, 'row 3 succeeded' );
    $dbh->disconnect;
};

subtest 'retry-on-error mode: all tuples eventually succeed after the batch was rejected' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ 1, 2 ] );

    push @queue, { ok => 0, status => 500, exception_code => 62, headers => {}, body => 'syntax-ish' };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };

    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );
    is( $rv, 2, 'reports success once every retried tuple succeeds' );
    is_deeply( \@tuple_status, [ -1, -1 ] );
    $dbh->disconnect;
};

subtest 'RaiseError=1 with retry-on-error: dies with the real failing tuple, ArrayTupleStatus still fully populated' => sub {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 1, PrintError => 0 } );
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );

    push @queue, { ok => 0, status => 500, exception_code => 241, headers => {}, body => 'batch failed' };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };                              # row 1 ok
    push @queue, { ok => 0, status => 500, exception_code => 999, headers => {}, body => 'row 2 bad' }; # row 2 bad
    push @queue, { ok => 1, status => 200, body => '', headers => {} };                              # row 3 ok -- last tuple succeeds

    my @tuple_status;
    my $rv = eval {
        $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );
    };
    ok( $@, 'RaiseError=1 dies even though the last attempted tuple succeeded' );
    like( $@, qr/row 2 bad/, 'the die message reflects the real failure, not a stale/cleared state' );
    is( scalar @tuple_status, 3,
        'ArrayTupleStatus is still fully populated before the die -- not lost, not truncated' );
    is( $tuple_status[0], -1 );
    is( ref $tuple_status[1], 'ARRAY' );
    is( $tuple_status[1][0], 999 );
    is( $tuple_status[2], -1 );
    $dbh->disconnect;
};

subtest q{RaiseError=0 with retry-on-error: $sth->err reflects the real failure even after the last tuple succeeded} => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );

    push @queue, { ok => 0, status => 500, exception_code => 241, headers => {}, body => 'batch failed' };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    push @queue, { ok => 0, status => 500, exception_code => 999, headers => {}, body => 'row 2 bad' };
    push @queue, { ok => 1, status => 200, body => '', headers => {} };

    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );
    ok( !defined $rv );
    ok( $sth->err, q{$sth->err is true -- never silently cleared by the last tuple's success} );
    is( $sth->err, 999 );
    like( $sth->errstr, qr/row 2 bad/ );
    $dbh->disconnect;
};

subtest 'transport failure (599) is never retried, even with chng_retry_on_error -- avoids silent duplicate inserts' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );

    push @queue, { ok => 0, status => 599, headers => {}, body => 'Connection timed out' };

    my $before = scalar @query_calls;
    my @tuple_status;
    my $rv = $sth->execute_array( { ArrayTupleStatus => \@tuple_status, chng_retry_on_error => 1 } );

    ok( !defined $rv );
    is( scalar( @query_calls ) - $before, 1, 'no retry attempted after an ambiguous transport failure' );
    is( scalar @tuple_status, 3 );
    for my $s ( @tuple_status ) {
        is( $s->[0], 1 );
        is( $s->[2], '08S01' );
    }
    $dbh->disconnect;
};

subtest 'malformed JSON-shaped edge case does not apply to the fast path (no JSON expected), but a stray non-empty body is tolerated' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [1,2] );
    push @queue, { ok => 1, status => 200, body => "\n", headers => {} }; # whitespace-only body
    my $rv = $sth->execute_array( {} );
    is( $rv, 2, 'whitespace-only success body treated the same as empty' );
    $dbh->disconnect;
};

subtest 'RaiseError propagates execute_array failures like any other method' => sub {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 1, PrintError => 0 } );
    my $sth = $dbh->prepare( 'INSERT INTO t (a) VALUES (?)' );
    $sth->bind_param_array( 1, [1,2] );
    push @queue, { ok => 0, status => 500, exception_code => 1, headers => {}, body => 'boom' };
    eval { $sth->execute_array( {} ) };
    like( $@, qr/boom/ );
    $dbh->disconnect;
};

subtest 'ParamArrays reflects bound arrays, keyed by 1-based parameter number' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO staff (first_name, last_name) VALUES (?, ?)' );
    is( $sth->{ParamArrays}, undef, 'undef before any bind_param_array call' );

    $sth->bind_param_array( 1, [ 'John', 'Mary' ] );
    $sth->bind_param_array( 2, [ 'Booth', 'Todd' ] );
    is_deeply( $sth->{ParamArrays}, { 1 => [ 'John', 'Mary' ], 2 => [ 'Booth', 'Todd' ] } );

    $sth->execute_array( {} );
    is_deeply( $sth->{ParamArrays}, { 1 => [ 'John', 'Mary' ], 2 => [ 'Booth', 'Todd' ] },
        'still reflects the bound arrays after execute_array' );
    $dbh->disconnect;
};

done_testing;
