use v5.40;
use Test::More;
use DBI;
use DBD::ClickhouseNG::HTTP;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $user = $ENV{CHNG_TEST_USER};
my $pass = $ENV{CHNG_TEST_PASS};

# Fixed TLS endpoint on the same dev server as CHNG_TEST_DSN, serving a
# certificate valid for this exact hostname (SAN: narya.grin.hu) -- not
# 'localhost' or an IP, so hostname verification requires connecting by
# this specific name for the positive path, and by a *wrong* name
# (localhost, same server/port/cert) for a durable negative path that
# doesn't depend on the certificate's expiry date.
use constant TLS_HOST       => 'narya.grin.hu';
use constant TLS_WRONG_HOST => 'localhost';
use constant TLS_PORT       => 8443;

# Cheap reachability probe so this file degrades to a skip (not a hang) on
# a network that can't resolve/reach either name -- the hostname-mismatch
# subtests specifically depend on TLS_WRONG_HOST:TLS_PORT serving the exact
# same server/certificate as TLS_HOST:TLS_PORT (true on the dev box this
# was written against), not merely being reachable on its own.
sub _probe_reachable( $host, $port ) {
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new( PeerHost => $host, PeerPort => $port, Timeout => 3 );
    my $ok = defined $sock;
    $sock->close if $sock;
    return $ok;
}
my $reachable = eval { _probe_reachable( TLS_HOST, TLS_PORT ) && _probe_reachable( TLS_WRONG_HOST, TLS_PORT ) };
plan skip_all => 'TLS test host(s) ' . TLS_HOST . '/' . TLS_WRONG_HOST . ':' . TLS_PORT . ' not reachable'
    unless $reachable;

subtest 'buffered path (HTTP::Tiny, verify_SSL => 1): a valid cert connects and queries' => sub {
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . TLS_HOST . ';port=' . TLS_PORT . ';tls=1;database=DBD_dev';
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 1, PrintError => 0 } );
    ok( $dbh, 'connect succeeds' ) or diag $DBI::errstr;
    my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
    is( $one, 1 );
    $dbh->disconnect;
};

subtest 'streaming path (Net::HTTPS, explicit SSL_verify_mode/SSL_verifycn_scheme): a valid cert connects' => sub {
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => TLS_HOST, port => TLS_PORT, tls => 1, timeout => 5,
        user => $user, password => $pass, database => 'DBD_dev',
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( $res->{ok}, 'query_stream succeeds' ) or diag $res->{body};
    is( $res->{status}, 200 );
    $res->{reader}->close if $res->{reader};
};

subtest 'buffered path refuses a hostname mismatch (same cert/server, wrong name)' => sub {
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . TLS_WRONG_HOST . ';port=' . TLS_PORT . ';tls=1;database=DBD_dev';
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 0, PrintError => 0 } );
    ok( !defined $dbh, 'connect refused' );
    like( $DBI::errstr, qr/hostname verification failed/i,
        'error mentions hostname verification, not some unrelated transport failure' );
    is( $DBI::state, '08001', 'connect-time transport failure state' );
};

subtest 'streaming path refuses a hostname mismatch (same cert/server, wrong name)' => sub {
    # connect() always does its initial SELECT 1 through the buffered
    # transport, so it already fails before ever reaching query_stream()'s
    # own TLS handshake -- exercise the streaming transport directly
    # instead, the same way t/14 unit-tests HTTP.pm's other internals
    # independent of a full DBI connect.
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => TLS_WRONG_HOST, port => TLS_PORT, tls => 1, timeout => 5,
        user => $user, password => $pass, database => 'DBD_dev',
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( !$res->{ok}, 'query_stream refuses the connection' );
    is( $res->{status}, 599, 'transport-level failure status' );
    like( $res->{body}, qr/hostname verification failed/i,
        'error mentions hostname verification, not some unrelated transport failure' );
};

subtest 'tls_insecure=1 (buffered path): connects despite the hostname mismatch' => sub {
    my $tls_dsn = 'dbi:ClickhouseNG:host=' . TLS_WRONG_HOST . ';port=' . TLS_PORT
        . ';tls=1;tls_insecure=1;database=DBD_dev';
    my $dbh = DBI->connect( $tls_dsn, $user, $pass, { RaiseError => 1, PrintError => 0 } );
    ok( $dbh, 'connect succeeds' ) or diag $DBI::errstr;
    my( $one ) = $dbh->selectrow_array( 'SELECT 1' );
    is( $one, 1 );
    $dbh->disconnect;
};

subtest 'tls_insecure=1 (streaming path): query_stream succeeds despite the hostname mismatch' => sub {
    my $client = DBD::ClickhouseNG::HTTP->new(
        host => TLS_WRONG_HOST, port => TLS_PORT, tls => 1, tls_insecure => 1, timeout => 5,
        user => $user, password => $pass, database => 'DBD_dev',
    );
    my $res = $client->query_stream( 'SELECT 1' );
    ok( $res->{ok}, 'query_stream succeeds' ) or diag $res->{body};
    is( $res->{status}, 200 );
    $res->{reader}->close if $res->{reader};
};

done_testing;
