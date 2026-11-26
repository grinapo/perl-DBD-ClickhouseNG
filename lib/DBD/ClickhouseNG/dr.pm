package DBD::ClickhouseNG::dr;

# Responsibility: DBI driver handle -- DSN parsing and connect(), which
# creates the HTTP client and the ::db handle (archive/DESIGN.md §3).
# Internal deps: HTTP, Error.
# Handle state: sets $dbh->{chng_client} (the HTTP client) and
#   $dbh->{chng_fetch_batch_rows} (DSN option, read by st).

use v5.40;
use Scalar::Util ();

use DBD::ClickhouseNG::HTTP;
use DBD::ClickhouseNG::Error;

our $imp_data_size = 0;

my %DSN_DEFAULT = (
    host             => 'localhost',
    port             => undef,
    database         => 'default',
    tls              => 0,
    tls_insecure     => 0,
    tls_cert_file    => undef,
    tls_key_file     => undef,
    tls_ca_file      => undef,
    timeout          => 30,
    fetch_batch_rows => undef,
);

sub connect( $drh, $dsn = undef, $user = undef, $auth = undef, $attr = undef ) {
    my %opts = %DSN_DEFAULT;
    for my $part ( split /;/, $dsn // '' ) {
        next unless length $part;
        my( $k, $v ) = split /=/, $part, 2;
        return $drh->set_err( $DBI::stderr, "Unknown DSN attribute '$k'" )
            unless exists $opts{$k};
        $opts{$k} = $v;
    }

    return $drh->set_err( $DBI::stderr, "DSN 'tls' must be 0 or 1" )
        unless $opts{tls} =~ /\A[01]\z/;
    return $drh->set_err( $DBI::stderr, "DSN 'tls_insecure' must be 0 or 1" )
        unless $opts{tls_insecure} =~ /\A[01]\z/;
    return $drh->set_err( $DBI::stderr, "DSN 'tls_insecure' requires 'tls=1'" )
        if $opts{tls_insecure} && !$opts{tls};
    for my $k ( qw(tls_cert_file tls_key_file tls_ca_file) ) {
        next unless defined $opts{$k};
        return $drh->set_err( $DBI::stderr, "DSN '$k' requires 'tls=1'" ) unless $opts{tls};
        return $drh->set_err( $DBI::stderr, "DSN '$k' is not a readable file" )
            unless length $opts{$k} && -f $opts{$k} && -r _;
    }
    return $drh->set_err( $DBI::stderr, "DSN 'tls_cert_file' and 'tls_key_file' must be given together" )
        if defined $opts{tls_cert_file} != defined $opts{tls_key_file};
    return $drh->set_err( $DBI::stderr, "DSN 'host' must not be empty" )
        unless length $opts{host};
    return $drh->set_err( $DBI::stderr, "DSN 'host' must not contain '/' or whitespace" )
        if $opts{host} =~ m{[/\s]};
    return $drh->set_err( $DBI::stderr, "DSN 'port' must be a positive integer" )
        if defined $opts{port} && $opts{port} !~ /\A[1-9][0-9]*\z/;
    return $drh->set_err( $DBI::stderr, "DSN 'timeout' must be a positive number" )
        unless Scalar::Util::looks_like_number( $opts{timeout} ) && $opts{timeout} > 0;
    return $drh->set_err( $DBI::stderr, "DSN 'fetch_batch_rows' must be a positive integer" )
        if defined $opts{fetch_batch_rows} && $opts{fetch_batch_rows} !~ /\A[1-9][0-9]*\z/;

    $opts{port} //= $opts{tls} ? 8443 : 8123;

    $user //= 'default';
    $auth //= '';

    my $client = DBD::ClickhouseNG::HTTP->new(
        host         => $opts{host},
        port         => $opts{port},
        tls          => $opts{tls},
        tls_insecure => $opts{tls_insecure},
        tls_cert_file => $opts{tls_cert_file},
        tls_key_file  => $opts{tls_key_file},
        tls_ca_file   => $opts{tls_ca_file},
        user         => $user,
        password     => $auth,
        database     => $opts{database},
        timeout      => $opts{timeout},
    );

    my $res = $client->query( 'SELECT 1' );
    unless( $res->{ok} ) {
        return DBD::ClickhouseNG::Error::report( $drh, $res, 'connect' );
    }

    my( $outer, $dbh ) = DBI::_new_dbh( $drh, {
        Name     => $dsn,
        Username => $user,
    } );
    $dbh->{chng_client}           = $client;
    $dbh->{chng_fetch_batch_rows} = $opts{fetch_batch_rows};
    $dbh->STORE( Active     => 1 );
    $dbh->STORE( AutoCommit => 1 );

    return $outer;
}

sub data_sources( $drh ) { return () }
1;
