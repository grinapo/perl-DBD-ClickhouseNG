use v5.40;
use Test::More;
use DBI;

# Live mutual-TLS test. Fully parameterized by environment (see .test-db-cert
# for a sample); skipped unless the required variables are set:
#   CHNG_TEST_MTLS_HOST  server name (must match the server certificate)
#   CHNG_TEST_MTLS_PORT  HTTPS port (default 8443)
#   CHNG_TEST_MTLS_USER  ClickHouse user identified by the client certificate
#                        (ssl_certificates); the password is empty
#   CHNG_TEST_MTLS_CERT / CHNG_TEST_MTLS_KEY  client certificate / key (PEM)
#   CHNG_TEST_MTLS_CA    CA bundle for the server certificate (optional)
#   CHNG_TEST_MTLS_DB    database (default 'default')
# The server must request client certificates (openSSL.server
# verificationMode other than 'none', caConfig = the issuing CA).

my %e = map { $_ => $ENV{"CHNG_TEST_MTLS_$_"} } qw(HOST PORT USER CERT KEY CA DB);
plan skip_all => 'set CHNG_TEST_MTLS_HOST/USER/CERT/KEY to run the live mTLS test'
    unless 4 == grep { defined $e{$_} && length $e{$_} } qw(HOST USER CERT KEY);

$e{PORT} ||= 8443;
$e{DB}   ||= 'default';

my $base = "dbi:ClickhouseNG:host=$e{HOST};port=$e{PORT};database=$e{DB};tls=1"
         . ( $e{CA} ? ";tls_ca_file=$e{CA}" : '' );
my $cert = ";tls_cert_file=$e{CERT};tls_key_file=$e{KEY}";
my %attr = ( RaiseError => 1, PrintError => 0 );

subtest 'buffered path: certificate authenticates the user' => sub {
    my $dbh = DBI->connect( $base . $cert, $e{USER}, '', \%attr );
    my( $who ) = $dbh->selectrow_array( 'SELECT currentUser()' );
    is( $who, $e{USER}, 'currentUser() is the certificate-mapped user' );
    $dbh->disconnect;
};

subtest 'streaming path: certificate authenticates the user' => sub {
    my $dbh = DBI->connect( $base . $cert . ';fetch_batch_rows=2', $e{USER}, '', \%attr );
    my $sth = $dbh->prepare( 'SELECT number, currentUser() FROM numbers(5)' );
    $sth->execute;
    my( $n, $who ) = ( 0 );
    while( my $row = $sth->fetchrow_arrayref ) { $n++; $who = $row->[1] }
    is( $n, 5, 'all rows streamed' );
    is( $who, $e{USER}, 'streamed as the certificate-mapped user' );
    $dbh->disconnect;
};

subtest 'without the client certificate the same user is rejected' => sub {
    my $dbh = eval { DBI->connect( $base, $e{USER}, '', \%attr ) };
    ok( !$dbh, 'connect refused' );
    like( $@, qr/Authentication failed|AUTHENTICATION_FAILED/, 'authentication error' );
};

done_testing;
