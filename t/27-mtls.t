use v5.40;
use Test::More;
use DBI;
use DBD::ClickhouseNG::HTTP;

my %base = ( host => 'h', port => 443, tls => 1, timeout => 5, user => 'u', password => '', database => 'd' );
my %files = ( tls_cert_file => $0, tls_key_file => $0, tls_ca_file => $0 );

subtest 'client cert/key/CA reach both transports' => sub {
    my $c = DBD::ClickhouseNG::HTTP->new( %base, %files );
    is_deeply( $c->{http}{SSL_options},
        { SSL_cert_file => $0, SSL_key_file => $0, SSL_ca_file => $0 }, 'HTTP::Tiny SSL_options' );
    my %s = $c->_stream_tls_args;
    is( $s{SSL_cert_file}, $0, 'stream SSL_cert_file' );
    is( $s{SSL_key_file},  $0, 'stream SSL_key_file' );
    is( $s{SSL_ca_file},   $0, 'stream SSL_ca_file' );
};

subtest 'no files => no SSL_options; tls=0 ignores them' => sub {
    my $c = DBD::ClickhouseNG::HTTP->new( %base );
    ok( !$c->{http}{SSL_options}, 'SSL_options not set' );
    my $p = DBD::ClickhouseNG::HTTP->new( %base, tls => 0, %files );
    is_deeply( { $p->_stream_tls_args }, {}, 'plain: none' );
};

subtest 'DSN validation' => sub {
    my %t = (
        "tls=1;tls_cert_file=$0"                         => qr/tls_cert_file.*together/,
        "tls=1;tls_cert_file=$0;tls_key_file=/nonexist"  => qr/tls_key_file.*not a readable/,
        "tls_ca_file=$0"                                 => qr/tls_ca_file.*requires.*tls=1/,
    );
    for my $dsn ( sort keys %t ) {
        my $dbh = DBI->connect( "dbi:ClickhouseNG:host=nowhere;$dsn", 'x', 'y', { PrintError => 0, RaiseError => 0 } );
        ok( !$dbh, 'rejected' );
        like( $DBI::errstr, $t{$dsn}, $dsn );
    }
};

subtest 'auth headers with a client certificate' => sub {
    my $c = DBD::ClickhouseNG::HTTP->new( %base, %files, user => 'click_test' );
    is_deeply( $c->_auth_headers,
        { 'X-ClickHouse-User' => 'click_test', 'X-ClickHouse-SSL-Certificate-Auth' => 'on' },
        'user + cert-auth header, no password header' );
    my $w = DBD::ClickhouseNG::HTTP->new( %base, %files, user => 'u', password => 'pw' );
    is( $w->_auth_headers->{'X-ClickHouse-Key'}, 'pw', 'explicit password still sent' );
    my $d = DBD::ClickhouseNG::HTTP->new( %base, %files, user => 'default' );
    is_deeply( $d->_auth_headers, { 'X-ClickHouse-SSL-Certificate-Auth' => 'on' }, 'default user: no user header' );
    my $n = DBD::ClickhouseNG::HTTP->new( %base, user => 'u' );
    is_deeply( $n->_auth_headers, { 'X-ClickHouse-User' => 'u', 'X-ClickHouse-Key' => '' }, 'no cert: unchanged' );
};

done_testing;
