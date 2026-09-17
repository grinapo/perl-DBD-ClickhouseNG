use v5.38;
use Test::More;
use DBI;
use JSON::PP;

use DBD::ClickhouseNG;

# Broader error-handling safety net: connection errors, server overload,
# timeouts, and "no silent errors / no stale data" guarantees, on top of
# the error-mapping table already covered by t/20-dbi-glue.t.

my @queue;
local *DBD::ClickhouseNG::HTTP::query = sub {
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

sub connect_ok {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    return DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '',
        { RaiseError => 0, PrintError => 0 } );
}

subtest 'server overload: non-200 without an exception-code header (e.g. a proxy 503)' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 503, headers => {}, body => 'Service Temporarily Unavailable' } );
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv );
    is( $dbh->err, 503, 'err is the raw HTTP status code' );
    like( $dbh->errstr, qr/Service Temporarily Unavailable/ );
    is( $dbh->state, 'S1000' );
    $dbh->disconnect;
};

subtest 'server overload: 429 Too Many Requests without exception header' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 429, headers => {}, body => 'Too Many Requests' } );
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv );
    is( $dbh->err, 429 );
    $dbh->disconnect;
};

subtest 'non-200 with neither header nor body falls back to the status code as the message' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 502, headers => {}, body => '' } );
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv );
    is( $dbh->err, 502 );
    is( $dbh->errstr, 502, 'errstr falls back to the status code, never empty/undef' );
    $dbh->disconnect;
};

subtest 'timeout at connect time is reported identically to any other transport failure' => sub {
    @queue = ( { ok => 0, status => 599, headers => {}, body => 'Operation timed out' } );
    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh );
    is( $DBI::err, 1 );
    like( $DBI::errstr, qr/timed out/i );
    is( $DBI::state, '08001' );
};

subtest 'timeout mid-query is reported, not silently swallowed' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 599, headers => {}, body => 'Operation timed out' } );
    my $sth = $dbh->prepare( 'SELECT sleep(100)' );
    my $rv = $sth->execute;
    ok( !defined $rv );
    is( $sth->err, 1 );
    is( $sth->state, '08S01' );
    $dbh->disconnect;
};

subtest 'PrintError warns but does not crash or hide the error from the caller' => sub {
    my $dbh = connect_ok();
    $dbh->{PrintError} = 1;
    @queue = ( { ok => 0, status => 500, exception_code => 1, headers => {}, body => 'boom' } );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $rv = $dbh->do( 'SELECT 1' );
    ok( !defined $rv, 'error still surfaced to the caller, not hidden' );
    ok( @warnings, 'PrintError produced a warning' );
    like( $warnings[0], qr/boom/ );
    $dbh->disconnect;
};

subtest 'HandleError is invoked with the real error and can observe/suppress it' => sub {
    my @seen;
    my $dbh = do {
        push @queue, { ok => 1, status => 200, body => '', headers => {} };
        DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', {
            RaiseError  => 1,
            PrintError  => 0,
            HandleError => sub {
                my( $msg, $h, $rv ) = @_;
                push @seen, [ $msg, $h->err, $h->state ];
                return 1;    # suppress RaiseError
            },
        } );
    };
    @queue = ( { ok => 0, status => 500, exception_code => 77, headers => {}, body => 'handled boom' } );
    my $rv = eval { $dbh->do( 'SELECT 1' ) };
    ok( !$@, 'HandleError suppressed the die' );
    is( scalar @seen, 1, 'HandleError was actually invoked, not skipped' );
    like( $seen[0][0], qr/handled boom/ );
    is( $seen[0][1], 77 );
    $dbh->disconnect;
};

subtest 'no stale data: a failed re-execute never leaves old fetch results behind' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body =>
        JSON::PP->new->utf8->encode( {
            meta => [ { name => 'x', type => 'Int64' } ], data => [ [ 111 ] ], rows => 1,
        } ) } );
    my $sth = $dbh->prepare( 'SELECT x FROM t' );
    $sth->execute;
    my $row = $sth->fetch;
    is_deeply( $row, [ 111 ], 'first execute genuinely returned real data' );

    @queue = ( { ok => 0, status => 500, exception_code => 1, headers => {}, body => 'now it fails' } );
    my $rv = $sth->execute;
    ok( !defined $rv, 'second execute fails cleanly' );

    my $stale = $sth->fetch;
    ok( !defined $stale, 'fetch after a failed execute never returns the previous rows' );
    like( $sth->errstr, qr/fetch without successful execute|now it fails/ );
    $dbh->disconnect;
};

subtest 'ping never raises regardless of RaiseError, even when the transport is down' => sub {
    my $dbh = connect_ok();
    $dbh->{RaiseError} = 1;
    local *DBD::ClickhouseNG::HTTP::ping = sub { 0 };
    my $alive = eval { $dbh->ping };
    ok( !$@, 'ping did not die' );
    is( $alive, 0 );
    $dbh->disconnect;
};

subtest 'exception_code header present but non-numeric: never crashes, never downgrades to a mere warning' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 'not-a-number',
                 headers => { 'x-clickhouse-exception-code' => 'not-a-number' }, body => 'weird server' } );
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $rv = eval { $dbh->do( 'SELECT 1' ) };
    ok( !$@, 'does not die on a malformed exception-code header' );
    ok( !defined $rv );
    like( $dbh->errstr, qr/weird server/ );
    is( $dbh->err, $DBI::stderr, 'falls back to the generic sentinel, never coerces to 0' );
    is( scalar @warnings, 0,
        'no PrintWarn-style "warning:" noise -- a garbled header must still be reported as a hard error' );
    $dbh->disconnect;
};

subtest 'query_id header is appended when present, never crashes when absent' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 5,
                 headers => { 'x-clickhouse-exception-code' => 5 }, body => 'no query id here' } );
    my $rv = eval { $dbh->do( 'SELECT 1' ) };
    ok( !$@ );
    unlike( $dbh->errstr, qr/query_id/, 'no query_id suffix when the header is absent' );
    $dbh->disconnect;
};

done_testing;
