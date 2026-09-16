use v5.40;
use Test::More;
use DBI;
use JSON::PP;

use DBD::ClickhouseNG;

# Mock transport: queue of canned responses, returned in order for query();
# falls back to the last one once the queue is drained.
my @queue;
my @query_calls;
local *DBD::ClickhouseNG::HTTP::query = sub {
    my( $self, $sql, $params ) = @_;
    push @query_calls, [ $sql, $params ];
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};
my $ping_return = 1;
local *DBD::ClickhouseNG::HTTP::ping = sub { $ping_return };

sub connect_ok {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    return DBI->connect( 'dbi:ClickhouseNG:host=nowhere', 'default', '',
        { RaiseError => 0, PrintError => 0 } );
}

sub jsoncompact {
    my( $meta, $rows ) = @_;
    return JSON::PP->new->utf8->encode( {
        meta => $meta,
        data => $rows,
        rows => scalar @$rows,
    } );
}

subtest 'connect failure maps errors (t/00-load covers unreachable host separately)' => sub {
    @queue = ( { ok => 0, status => 500, exception_code => 516,
                 body => "Code: 516. DB::Exception: Auth failed\n",
                 headers => { 'x-clickhouse-exception-code' => 516 } } );
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', 'baduser', 'badpass',
        { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    is( $DBI::err, 516 );
    like( $DBI::errstr, qr/Auth failed/ );
    is( $DBI::state, 'S1000' );
};

subtest 'bad DSN key fails connect' => sub {
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:bogus=1', '', '', { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    like( $DBI::errstr, qr/Unknown DSN attribute/ );
};

subtest 'tls_insecure=1 without tls=1 is a driver-detected DSN usage error' => sub {
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere;tls_insecure=1', 'x', 'y',
        { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    like( $DBI::errstr, qr/tls_insecure.*requires.*tls=1/ );
};

subtest 'tls_insecure must be 0 or 1' => sub {
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere;tls=1;tls_insecure=maybe', 'x', 'y',
        { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    like( $DBI::errstr, qr/tls_insecure.*must be 0 or 1/ );
};

# These construct DBD::ClickhouseNG::HTTP directly (no ->query/->query_stream
# call, so no network I/O) to pin the actual security-relevant behavior --
# not just that the DSN parses, but that tls_insecure genuinely flips
# verification off on both transports, and stays on by default. A
# regression that inverted either ternary would pass every other test in
# this suite (t/57-live-tls.t only runs against a live, reachable server).
subtest 'tls_insecure controls HTTP::Tiny verify_SSL on the buffered transport' => sub {
    my $secure = DBD::ClickhouseNG::HTTP->new(
        host => 'h', port => 443, tls => 1, timeout => 5, user => 'u', password => 'p', database => 'd' );
    is( $secure->{http}->verify_SSL, 1, 'verification on by default with tls=1' );

    my $insecure = DBD::ClickhouseNG::HTTP->new(
        host => 'h', port => 443, tls => 1, tls_insecure => 1, timeout => 5,
        user => 'u', password => 'p', database => 'd' );
    is( $insecure->{http}->verify_SSL, 0, 'tls_insecure=1 disables verify_SSL' );
};

subtest 'tls_insecure controls the streaming transport\'s SSL args' => sub {
    my $secure = DBD::ClickhouseNG::HTTP->new(
        host => 'h', port => 443, tls => 1, timeout => 5, user => 'u', password => 'p', database => 'd' );
    my %args = $secure->_stream_tls_args;
    is( $args{SSL_verify_mode}, DBD::ClickhouseNG::HTTP::SSL_VERIFY_PEER(),
        'verification on by default with tls=1' );

    my $insecure = DBD::ClickhouseNG::HTTP->new(
        host => 'h', port => 443, tls => 1, tls_insecure => 1, timeout => 5,
        user => 'u', password => 'p', database => 'd' );
    %args = $insecure->_stream_tls_args;
    is( $args{SSL_verify_mode}, DBD::ClickhouseNG::HTTP::SSL_VERIFY_NONE(),
        'tls_insecure=1 disables SSL_verify_mode' );

    my $plain = DBD::ClickhouseNG::HTTP->new(
        host => 'h', port => 80, tls => 0, timeout => 5, user => 'u', password => 'p', database => 'd' );
    is_deeply( { $plain->_stream_tls_args }, {}, 'no SSL args at all when tls=0' );
};

subtest 'prepare/execute/fetch cycle with NAME/TYPE/NUM_OF_FIELDS/NULLABLE' => sub {
    my $dbh = connect_ok();
    ok( $dbh, 'connected' );

    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'id', type => 'UInt32' }, { name => 'name', type => 'Nullable(String)' } ],
        [ [ 1, 'alice' ], [ 2, undef ] ],
    ) } );

    my $sth = $dbh->prepare( 'SELECT id, name FROM t WHERE id = ?' );
    ok( $sth, 'prepared' );
    is( $sth->{NUM_OF_PARAMS}, 1 );

    my $rv = $sth->execute( 1 );
    is( $rv, 2, 'execute returns row count' );
    is( $sth->{NUM_OF_FIELDS}, 2 );
    is_deeply( $sth->{NAME}, [ 'id', 'name' ] );
    is_deeply( $sth->{NULLABLE}, [ 0, 1 ] );

    my $row1 = $sth->fetch;
    is_deeply( $row1, [ 1, 'alice' ] );
    my $row2 = $sth->fetch;
    is_deeply( $row2, [ 2, undef ] );
    my $row3 = $sth->fetch;
    ok( !defined $row3, 'no more rows' );

    is( $sth->rows, 2 );

    my $call = $query_calls[-1];
    like( $call->[0], qr/\{p1:Int64\}/, 'placeholder rewritten with inferred type' );
    is( $call->[1]{param_p1}, 1 );

    $dbh->disconnect;
};

subtest 'ParamValues / ParamTypes' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'String' } ], [ [ 'v' ] ],
    ) } );
    my $sth = $dbh->prepare( 'SELECT ? ' );
    $sth->bind_param( 1, 'hello', DBI::SQL_VARCHAR );
    $sth->execute;
    is_deeply( $sth->{ParamValues}, { 1 => 'hello' } );
    is_deeply( $sth->{ParamTypes}, { 1 => DBI::SQL_VARCHAR() } );
    $dbh->disconnect;
};

subtest 'chng_ch_types raw type strings' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Nullable(Int64)' } ], [ [ 5 ] ],
    ) } );
    my $sth = $dbh->prepare( 'SELECT ?' );
    $sth->execute( 1 );
    is_deeply( $sth->{chng_ch_types}, [ 'Nullable(Int64)' ] );
    $dbh->disconnect;
};

subtest 're-execute reuses sth, NUM_OF_FIELDS must stay stable' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' } ], [ [ 1 ] ],
    ) } );
    my $sth = $dbh->prepare( 'SELECT ?' );
    $sth->execute( 1 );
    is( $sth->{NUM_OF_FIELDS}, 1 );

    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' } ], [ [ 2 ], [ 3 ] ],
    ) } );
    $sth->execute( 2 );
    is( $sth->{NUM_OF_FIELDS}, 1, 'field count unchanged' );
    is( $sth->rows, 2 );
    $dbh->disconnect;
};

subtest 're-execute with different column count errors' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' } ], [ [ 1 ] ],
    ) } );
    my $sth = $dbh->prepare( 'SELECT ?' );
    $sth->execute( 1 );

    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' }, { name => 'y', type => 'Int64' } ], [ [ 1, 2 ] ],
    ) } );
    my $rv = $sth->execute( 1 );
    ok( !defined $rv );
    like( $dbh->errstr // $sth->errstr, qr/column count changed/ );
    $dbh->disconnect;
};

subtest 'fetch before execute errors' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'SELECT 1' );
    my $row = $sth->fetch;
    ok( !defined $row );
    like( $sth->errstr, qr/fetch without successful execute/ );
    $dbh->disconnect;
};

subtest 'bind-count mismatch on execute' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'SELECT ? , ?' );
    my $rv = $sth->execute( 1 );
    ok( !defined $rv );
    like( $sth->errstr, qr/execute called with 1 bound values, statement has 2 parameters/ );
    $dbh->disconnect;
};

subtest 'do() with no bind values, non-select (empty body)' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => '' } );
    my $rv = $dbh->do( 'INSERT INTO t VALUES (1)' );
    is( $rv, -1 );
    $dbh->disconnect;
};

subtest 'do() with no bind values, unexpectedly a result set' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' } ], [ [ 1 ], [ 2 ], [ 3 ] ],
    ) } );
    my $rv = $dbh->do( 'SELECT 1' );
    is( $rv, 3 );
    $dbh->disconnect;
};

subtest 'do() with no bind values, zero-row result set returns 0E0' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ { name => 'x', type => 'Int64' } ], [],
    ) } );
    my $rv = $dbh->do( 'SELECT 1 WHERE 0' );
    is( $rv, '0E0' );
    ok( $rv, 'true value' );
    $dbh->disconnect;
};

subtest 'do() with bind values goes through prepare/execute' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => '' } );
    my $rv = $dbh->do( 'INSERT INTO t VALUES (?)', undef, 42 );
    is( $rv, -1 );
    like( $query_calls[-1][0], qr/\{p1:Int64\}/ );
    $dbh->disconnect;
};

subtest 'commit/rollback warn under Warn, AutoCommit stays enabled' => sub {
    my $dbh = connect_ok();
    is( $dbh->{AutoCommit}, 1 );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    $dbh->{Warn} = 1;
    ok( $dbh->commit );
    ok( $dbh->rollback );
    is( scalar @warnings, 2 );
    like( $warnings[0], qr/commit ineffective/ );
    like( $warnings[1], qr/rollback ineffective/ );
    $dbh->disconnect;
};

subtest 'disabling AutoCommit croaks' => sub {
    my $dbh = connect_ok();
    eval { $dbh->{AutoCommit} = 0 };
    like( $@, qr/does not support transactions/ );
    $dbh->disconnect;
};

subtest 'error mapping: canned 500 with exception header' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 62,
                 headers => { 'x-clickhouse-exception-code' => 62, 'x-clickhouse-query-id' => 'abc-123' },
                 body => "Code: 62. Syntax error \n" } );
    my $sth = $dbh->prepare( 'SELECT ~~~' );
    my $rv = $sth->execute;
    ok( !defined $rv );
    is( $sth->err, 62 );
    like( $sth->errstr, qr/Syntax error/ );
    like( $sth->errstr, qr/query_id: abc-123/ );
    is( $sth->state, 'S1000' );
    $dbh->disconnect;
};

subtest 'error mapping: canned 599 transport failure after connect' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 599, headers => {}, body => 'Connection timed out' } );
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv );
    is( $dbh->err, 1 );
    like( $dbh->errstr, qr/Connection timed out/ );
    is( $dbh->state, '08S01' );
    $dbh->disconnect;
};

subtest 'error mapping: 599 transport failure at connect time -> 08001' => sub {
    @queue = ( { ok => 0, status => 599, headers => {}, body => 'connection refused' } );
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    is( $DBI::err, 1 );
    is( $DBI::state, '08001' );
};

subtest 'error mapping: malformed JSON body' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => '{not json' } );
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv );
    like( $dbh->errstr, qr/malformed JSON response/ );
    $dbh->disconnect;
};

subtest 'RaiseError dies on server error' => sub {
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '',
        { RaiseError => 1, PrintError => 0 } ) // do {
            @queue = ( { ok => 1, status => 200, body => '', headers => {} } );
            DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 1, PrintError => 0 } );
        };
    @queue = ( { ok => 0, status => 500, headers => { 'x-clickhouse-exception-code' => 1 }, body => 'boom' } );
    eval { $dbh->do( 'SELECT 1' ) };
    like( $@, qr/boom/ );
    $dbh->disconnect;
};

subtest 'bulk unit test: one execute() == one query() call' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'INSERT INTO t VALUES (?)' );
    @queue = ( { ok => 1, status => 200, headers => {}, body => '' } );
    my $before = scalar @query_calls;
    $sth->execute( 1 );
    is( scalar( @query_calls ) - $before, 1, 'single execute -> single query()' );
    $dbh->disconnect;
};

done_testing;
