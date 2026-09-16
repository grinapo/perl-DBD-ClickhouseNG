use v5.40;
use Test::More;
use DBI;
use JSON::PP;

use DBD::ClickhouseNG;

# Mock transport for the streaming (bounded-batch fetch) path: query() drives
# connect(), query_stream() drives a streaming execute(). Both are queued
# canned responses, mirroring the style of t/20-dbi-glue.t / t/23-error-safety.t.

my @queue;
local *DBD::ClickhouseNG::HTTP::query = sub {
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

my @stream_queue;
my @stream_calls;
local *DBD::ClickhouseNG::HTTP::query_stream = sub {
    my( $self, $sql, $params ) = @_;
    push @stream_calls, [ $sql, $params ];
    return shift @stream_queue;
};

{   package FakeReader;
    sub new {
        my( $class, @lines ) = @_;
        return bless { lines => [ @lines ], closed => 0 }, $class;
    }
    sub next_line {
        my $self = shift;
        return shift @{ $self->{lines} };
    }
    sub close { my $self = shift; $self->{closed} = 1; return }
}

sub connect_ok {
    my %attr = @_;
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    my $dsn = 'dbi:ClickhouseNG:host=nowhere';
    $dsn .= ";fetch_batch_rows=$attr{fetch_batch_rows}" if $attr{fetch_batch_rows};
    return DBI->connect( $dsn, 'default', '', { RaiseError => 0, PrintError => 0 } );
}

sub reader_for {
    my( $meta, $rows ) = @_;
    my @lines = (
        JSON::PP->new->utf8->encode( [ map { $_->{name} } @$meta ] ),
        JSON::PP->new->utf8->encode( [ map { $_->{type} } @$meta ] ),
        map { JSON::PP->new->utf8->encode( $_ ) } @$rows,
    );
    chomp @lines;
    return FakeReader->new( @lines );
}

subtest 'streaming SELECT: rows delivered in batches smaller than the result' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 2 );
    my $meta = [ { name => 'id', type => 'Int64' }, { name => 'name', type => 'String' } ];
    my $rows = [ [ 1, 'a' ], [ 2, 'b' ], [ 3, 'c' ], [ 4, 'd' ], [ 5, 'e' ] ];
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, $rows ) } );

    my $sth = $dbh->prepare( 'SELECT id, name FROM t' );
    ok( $sth->execute, 'execute (streaming) succeeds' );
    is( $sth->{NUM_OF_FIELDS}, 2, 'NUM_OF_FIELDS from streamed header lines' );
    is_deeply( $sth->{NAME}, [ 'id', 'name' ], 'NAME from streamed header lines' );
    is( $sth->rows, -1, 'rows() is -1 (unknown) for a streamed SELECT' );

    my @got;
    while( my $row = $sth->fetch ) {
        push @got, [ @$row ];
    }
    is_deeply( \@got, $rows, 'all rows fetched across multiple internal batches, in order' );
    $dbh->disconnect;
};

subtest 'value converters (e.g. Bool) apply the same in streaming as buffered' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    my $meta = [ { name => 'flag', type => 'Bool' } ];
    my $rows = [ [ 1 ], [ 0 ] ];
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, $rows ) } );

    my $sth = $dbh->prepare( 'SELECT flag FROM t' );
    $sth->execute;
    is_deeply( $sth->fetch, [ 1 ] );
    is_deeply( $sth->fetch, [ 0 ] );
    $dbh->disconnect;
};

subtest 'Int64 beyond IV range round-trips as a real number, not just string-equal' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    my $meta = [ { name => 'big', type => 'Int64' } ];
    # ClickHouse's JSON formats quote 64-bit ints as strings on the wire
    # (output_format_json_quote_64bit_integers); the row is built directly
    # (not via reader_for's array-ref rows) to mimic that quoted-string shape.
    my @lines = (
        JSON::PP->new->utf8->encode( [ 'big' ] ),
        JSON::PP->new->utf8->encode( [ 'Int64' ] ),
        JSON::PP->new->utf8->encode( [ '9223372036854775807' ] ),
    );
    chomp @lines;
    @stream_queue = ( { ok => 1, reader => FakeReader->new( @lines ) } );

    my $sth = $dbh->prepare( 'SELECT big FROM t' );
    $sth->execute;
    my $row = $sth->fetch;
    cmp_ok( $row->[0], '==', 9223372036854775807, 'numeric equality, not merely string equality' );
    $dbh->disconnect;
};

subtest 'NULL round-trips as undef through the streaming path' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    my $meta = [ { name => 'x', type => 'Nullable(Int64)' } ];
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, [ [ undef ] ] ) } );

    my $sth = $dbh->prepare( 'SELECT x FROM t' );
    $sth->execute;
    is_deeply( $sth->fetch, [ undef ] );
    $dbh->disconnect;
};

{   package DyingReader;
    # A reader whose next_line() dies partway through, simulating a
    # connection reset mid-body -- a real failure mode even under
    # wait_end_of_query=1, since the response body still travels over a
    # fragile socket after the server has buffered it.
    sub new {
        my( $class, @good_lines ) = @_;
        return bless { lines => [ @good_lines ] }, $class;
    }
    sub next_line {
        my $self = shift;
        return shift @{ $self->{lines} } if @{ $self->{lines} };
        die "streaming read failed: Connection reset by peer\n";
    }
    sub close { return }
}

subtest 'a transport error while reading streaming header lines returns undef/set_err, not a raw die' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    @stream_queue = ( { ok => 1, reader => DyingReader->new() } );    # dies on the very first next_line

    my $sth = $dbh->prepare( 'SELECT x FROM t' );
    my $rv = eval { $sth->execute };
    ok( !$@, 'execute did not die' );
    ok( !defined $rv, 'execute reports failure via its return value' );
    like( $sth->errstr, qr/streaming transport error/ );
    $dbh->disconnect;
};

subtest 'a transport error mid-body (during fetch) returns undef/set_err, not a raw die' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 2 );
    my $meta = [ { name => 'id', type => 'Int64' } ];
    my @header_lines = (
        JSON::PP->new->utf8->encode( [ map { $_->{name} } @$meta ] ),
        JSON::PP->new->utf8->encode( [ map { $_->{type} } @$meta ] ),
        JSON::PP->new->utf8->encode( [ 1 ] ),
    );
    chomp @header_lines;
    @stream_queue = ( { ok => 1, reader => DyingReader->new( @header_lines ) } );

    my $sth = $dbh->prepare( 'SELECT id FROM t' );
    $sth->execute;
    is_deeply( $sth->fetch, [ 1 ], 'the one good row before the reset is delivered' );

    my $rv = eval { $sth->fetch };
    ok( !$@, 'fetch did not die' );
    ok( !defined $rv, 'fetch reports the reset via its return value' );
    like( $sth->errstr, qr/streaming transport error/ );
    $dbh->disconnect;
};

subtest 're-executing after an abandoned, un-surfaced streaming error does not resurrect it' => sub {
    my $meta = [ { name => 'id', type => 'Int64' } ];
    my @header_lines = (
        JSON::PP->new->utf8->encode( [ map { $_->{name} } @$meta ] ),
        JSON::PP->new->utf8->encode( [ map { $_->{type} } @$meta ] ),
        JSON::PP->new->utf8->encode( [ 1 ] ),
    );
    chomp @header_lines;

    subtest 'RaiseError => 1: re-execute does not die' => sub {
        my $dbh = connect_ok( fetch_batch_rows => 2 );
        $dbh->{RaiseError} = 1;
        @stream_queue = ( { ok => 1, reader => DyingReader->new( @header_lines ) } );
        my $sth = $dbh->prepare( 'SELECT id FROM t' );
        $sth->execute;
        $sth->fetch;    # gets the one good row; leaves chng_stream_error stashed, unfetched-to-exhaustion

        @stream_queue = ( { ok => 1, reader => reader_for( $meta, [ [ 2 ] ] ) } );
        my $rv = eval { $sth->execute };
        ok( !$@, 're-execute did not die despite the abandoned previous stream error' );
        ok( $rv, 're-execute succeeded' );
        is_deeply( $sth->fetch, [ 2 ], 'the new result is delivered, not the old error' );
        $dbh->disconnect;
    };

    subtest 'RaiseError => 0: re-execute leaves err clear' => sub {
        my $dbh = connect_ok( fetch_batch_rows => 2 );
        @stream_queue = ( { ok => 1, reader => DyingReader->new( @header_lines ) } );
        my $sth = $dbh->prepare( 'SELECT id FROM t' );
        $sth->execute;
        $sth->fetch;

        @stream_queue = ( { ok => 1, reader => reader_for( $meta, [ [ 2 ] ] ) } );
        my $rv = $sth->execute;
        ok( $rv, 're-execute succeeded' );
        ok( !$sth->err, 'err is not the stale error from the abandoned stream' );
        $dbh->disconnect;
    };
};

subtest 'metadata parity: streaming and buffered paths agree on NAME/TYPE/NUM_OF_FIELDS' => sub {
    my $meta = [ { name => 'x', type => 'Int64' }, { name => 'y', type => 'Nullable(String)' } ];

    my $dbh_buf = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body =>
        JSON::PP->new->utf8->encode( { meta => $meta, data => [ [ 1, 'a' ] ], rows => 1 } ) } );
    my $sth_buf = $dbh_buf->prepare( 'SELECT x, y FROM t' );
    $sth_buf->execute;

    my $dbh_stream = connect_ok( fetch_batch_rows => 100 );
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, [ [ 1, 'a' ] ] ) } );
    my $sth_stream = $dbh_stream->prepare( 'SELECT x, y FROM t' );
    $sth_stream->execute;

    is_deeply( $sth_stream->{NAME}, $sth_buf->{NAME}, 'NAME matches' );
    is_deeply( $sth_stream->{TYPE}, $sth_buf->{TYPE}, 'TYPE matches' );
    is( $sth_stream->{NUM_OF_FIELDS}, $sth_buf->{NUM_OF_FIELDS}, 'NUM_OF_FIELDS matches' );
    $dbh_buf->disconnect;
    $dbh_stream->disconnect;
};

subtest 'a resultset-less statement (INSERT/DDL) on a streaming connection succeeds cleanly' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    # A 200 with a completely empty body -- what INSERT/DDL actually returns
    # -- must not be mistaken for the "one header line, one missing" corrupt
    # case; it means "no result set", same as the buffered path.
    @stream_queue = ( { ok => 1, reader => FakeReader->new() } );

    my $sth = $dbh->prepare( 'INSERT INTO t VALUES (?)' );
    my $rv = eval { $sth->execute( 1 ) };
    ok( !$@, 'execute did not die' );
    is( $rv, -1, 'execute reports success (unknown row count), not a spurious "missing header lines" error' );
    ok( !$sth->err, 'no error set' );
    $dbh->disconnect;
};

subtest 'a zero-row streamed SELECT (header lines present, no data rows) is a clean empty result' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    my $meta = [ { name => 'x', type => 'Int64' } ];
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, [] ) } );

    my $sth = $dbh->prepare( 'SELECT x FROM t WHERE 0' );
    ok( $sth->execute, 'execute succeeds' );
    is( $sth->fetch, undef, 'fetch returns undef immediately, no rows' );
    ok( !$sth->err, 'no error set' );
    $dbh->disconnect;
};

subtest 'only one of the two streaming header lines present is still a genuine malformed-response error' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    @stream_queue = ( { ok => 1, reader => FakeReader->new( '["x"]' ) } );    # names line only, no types line

    my $sth = $dbh->prepare( 'SELECT x FROM t' );
    my $rv = $sth->execute;
    ok( !defined $rv, 'execute fails' );
    like( $sth->errstr, qr/malformed streaming response/ );
    $dbh->disconnect;
};

subtest 'a transport/server error on the streaming path is reported like the buffered path' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 10 );
    @stream_queue = ( { ok => 0, status => 500, exception_code => 60,
                        headers => { 'x-clickhouse-exception-code' => 60 }, body => 'no such table' } );

    my $sth = $dbh->prepare( 'SELECT x FROM missing' );
    my $rv = $sth->execute;
    ok( !defined $rv, 'execute fails' );
    is( $sth->err, 60 );
    like( $sth->errstr, qr/no such table/ );
    $dbh->disconnect;
};

subtest 'finish() mid-stream closes the reader' => sub {
    my $dbh = connect_ok( fetch_batch_rows => 2 );
    my $meta = [ { name => 'id', type => 'Int64' } ];
    my $rows = [ [ 1 ], [ 2 ], [ 3 ], [ 4 ] ];
    my $reader = reader_for( $meta, $rows );
    @stream_queue = ( { ok => 1, reader => $reader } );

    my $sth = $dbh->prepare( 'SELECT id FROM t' );
    $sth->execute;
    $sth->fetch;
    ok( !$reader->{closed}, 'reader still open after a partial fetch' );
    $sth->finish;
    ok( $reader->{closed}, 'finish() closed the reader' );
    $dbh->disconnect;
};

subtest 'per-statement chng_fetch_batch_rows overrides the connection-wide default' => sub {
    my $dbh = connect_ok();    # no DSN-level streaming
    my $meta = [ { name => 'id', type => 'Int64' } ];
    @stream_queue = ( { ok => 1, reader => reader_for( $meta, [ [ 1 ] ] ) } );

    my $sth = $dbh->prepare( 'SELECT id FROM t' );
    $sth->{chng_fetch_batch_rows} = 5;
    @stream_calls = ();
    $sth->execute;
    is( scalar( @stream_calls ), 1, 'query_stream was used for this statement despite no DSN default' );
    is_deeply( $sth->fetch, [ 1 ] );
    $dbh->disconnect;
};

subtest 'an invalid (truthy but non-positive-integer) chng_fetch_batch_rows is a driver-detected usage error' => sub {
    my $dbh = connect_ok();
    for my $bad ( -1, 'abc' ) {
        my $sth = $dbh->prepare( 'SELECT id FROM t' );
        $sth->{chng_fetch_batch_rows} = $bad;
        @stream_calls = ();
        my $rv = $sth->execute;
        ok( !defined $rv, "chng_fetch_batch_rows = '$bad' rejected" );
        like( $sth->errstr, qr/chng_fetch_batch_rows must be a positive integer/ );
        is( scalar( @stream_calls ), 0, 'no transport call was made' );
    }
    $dbh->disconnect;
};

subtest 'chng_fetch_batch_rows = 0 is treated as off (falsy), not an error' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body =>
        JSON::PP->new->utf8->encode( { meta => [ { name => 'id', type => 'Int64' } ], data => [ [ 1 ] ], rows => 1 } ) } );
    my $sth = $dbh->prepare( 'SELECT id FROM t' );
    $sth->{chng_fetch_batch_rows} = 0;
    @stream_calls = ();
    ok( $sth->execute, 'execute succeeds via the ordinary buffered path' );
    is( scalar( @stream_calls ), 0, 'query_stream was not used' );
    $dbh->disconnect;
};

done_testing;
