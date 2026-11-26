use v5.40;
use Test::More;
use DBI;
use DBD::ClickhouseNG::HTTP;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $user = $ENV{CHNG_TEST_USER};
my $pass = $ENV{CHNG_TEST_PASS};

# TLS endpoint, from the environment (no hard-coded hosts; see t/README.md):
#   CHNG_TEST_TLS_HOST        server name; the certificate must be valid for
#                             exactly this name (required)
#   CHNG_TEST_TLS_PORT        HTTPS port (default 8443)
#   CHNG_TEST_TLS_CA          CA bundle for the server certificate (optional;
#                             default: system store)
#   CHNG_TEST_TLS_WRONG_HOST  another name reaching the same server/port/cert
#                             (e.g. localhost); enables the hostname-mismatch
#                             and tls_insecure subtests (optional)
# The DB name and credentials still come from CHNG_TEST_DSN/_USER/_PASS.
my $TLS_HOST       = $ENV{CHNG_TEST_TLS_HOST};
my $TLS_WRONG_HOST = $ENV{CHNG_TEST_TLS_WRONG_HOST};
my $TLS_PORT       = $ENV{CHNG_TEST_TLS_PORT} || 8443;
my $TLS_CA         = $ENV{CHNG_TEST_TLS_CA};
plan skip_all => 'set CHNG_TEST_TLS_HOST to run the live TLS test'
    unless defined $TLS_HOST && length $TLS_HOST;

# Cheap reachability probe so this file degrades to a skip (not a hang) on
# a network that can't resolve/reach the configured name(s).
sub _probe_reachable( $host, $port ) {
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new( PeerHost => $host, PeerPort => $port, Timeout => 3 );
    my $ok = defined $sock;
    $sock->close if $sock;
    return $ok;
}
my $reachable = eval { grep( { !_probe_reachable( $_, $TLS_PORT ) } grep { length } $TLS_HOST, $TLS_WRONG_HOST // () ) == 0 };
plan skip_all => "TLS test host(s) not reachable on port $TLS_PORT"
    unless $reachable;

my $ca_dsn  = $TLS_CA ? ";tls_ca_file=$TLS_CA" : '';
my %ca_args = $TLS_CA ? ( tls_ca_file => $TLS_CA ) : ();

# The TLS connections below use the same database as CHNG_TEST_DSN.
my( $db ) = DBI->connect( $dsn, $user, $pass, { RaiseError => 1, PrintError => 0 } )
    ->selectrow_array( 'SELECT currentDatabase()' );

subtest 'buffered path (HTTP::Tiny, verify_SSL => 1): a valid cert connects and queries' => sub {
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . $TLS_HOST . ';port=' . $TLS_PORT . ';tls=1' . $ca_dsn . ';database=' . $db;
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 1, PrintError => 0 } );
    ok( $dbh, 'connect succeeds' ) or diag $DBI::errstr;
    my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
    is( $one, 1 );
    $dbh->disconnect;
};

subtest 'streaming path (Net::HTTPS, explicit SSL_verify_mode/SSL_verifycn_scheme): a valid cert connects' => sub {
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => $TLS_HOST, port => $TLS_PORT, %ca_args, tls => 1, timeout => 5,
        user => $user, password => $pass, database => $db,
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( $res->{ok}, 'query_stream succeeds' ) or diag $res->{body};
    is( $res->{status}, 200 );
    $res->{reader}->close if $res->{reader};
};

subtest 'buffered path refuses a hostname mismatch (same cert/server, wrong name)' => sub {
    plan skip_all => 'set CHNG_TEST_TLS_WRONG_HOST to run this subtest' unless $TLS_WRONG_HOST;
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . $TLS_WRONG_HOST . ';port=' . $TLS_PORT . ';tls=1' . $ca_dsn . ';database=' . $db;
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh, 'connect refused' );
    like( $DBI::errstr, qr/hostname verification failed/i,
        'error mentions hostname verification, not some unrelated transport failure' );
    is( $DBI::state, '08001', 'connect-time transport failure state' );
};

subtest 'streaming path refuses a hostname mismatch (same cert/server, wrong name)' => sub {
    plan skip_all => 'set CHNG_TEST_TLS_WRONG_HOST to run this subtest' unless $TLS_WRONG_HOST;
    # connect() always does its initial SELECT 1 through the buffered
    # transport, so it already fails before ever reaching query_stream()'s
    # own TLS handshake -- exercise the streaming transport directly
    # instead, the same way t/14 unit-tests HTTP.pm's other internals
    # independent of a full DBI connect.
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => $TLS_WRONG_HOST, port => $TLS_PORT, %ca_args, tls => 1, timeout => 5,
        user => $user, password => $pass, database => $db,
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( !$res->{ok}, 'query_stream refuses the connection' );
    is( $res->{status}, 599, 'transport-level failure status' );
    like( $res->{body}, qr/hostname verification failed/i,
        'error mentions hostname verification, not some unrelated transport failure' );
};

subtest 'tls_insecure=1 (buffered path): connects despite the hostname mismatch' => sub {
    plan skip_all => 'set CHNG_TEST_TLS_WRONG_HOST to run this subtest' unless $TLS_WRONG_HOST;
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . $TLS_WRONG_HOST . ';port=' . $TLS_PORT
        . ';tls=1;tls_insecure=1' . $ca_dsn . ';database=' . $db;
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 1, PrintError => 0 } );
    ok( $dbh, 'connect succeeds' ) or diag $DBI::errstr;
    my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
    is( $one, 1 );
    $dbh->disconnect;
};

subtest 'tls_insecure=1 (streaming path): query_stream succeeds despite the hostname mismatch' => sub {
    plan skip_all => 'set CHNG_TEST_TLS_WRONG_HOST to run this subtest' unless $TLS_WRONG_HOST;
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => $TLS_WRONG_HOST, port => $TLS_PORT, %ca_args, tls => 1, tls_insecure => 1, timeout => 5,
        user => $user, password => $pass, database => $db,
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( $res->{ok}, 'query_stream succeeds' ) or diag $res->{body};
    is( $res->{status}, 200 );
    $res->{reader}->close if $res->{reader};
};

done_testing;
