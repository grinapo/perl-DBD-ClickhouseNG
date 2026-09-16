package DBD::ClickhouseNG::HTTP;

use v5.40;
use HTTP::Tiny 0.088;
use IO::Compress::Gzip   qw(gzip $GzipError);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Net::HTTP  ();
use Net::HTTPS ();
use IO::Socket::SSL qw(SSL_VERIFY_PEER SSL_VERIFY_NONE);

sub new( $class, %args ) {
    my $scheme = $args{tls} ? 'https' : 'http';
    my $user     = $args{user}     // 'default';
    my $password = $args{password} // '';
    utf8::encode( $user );
    utf8::encode( $password );
    my $self = bless {
        database     => $args{database},
        user         => $user,
        password     => $password,
        host         => $args{host},
        port         => $args{port},
        tls          => $args{tls},
        tls_insecure => $args{tls_insecure},
        timeout      => $args{timeout},
        base_url     => "$scheme://$args{host}:$args{port}/",
    }, $class;

    # tls_insecure => 1 (opt-in, DSN-level, requires tls => 1) disables
    # both certificate and hostname verification -- e.g. for a self-signed
    # or expired cert in a dev/test environment. Off by default: silently
    # accepting an unverified TLS connection is not a safe default.
    $self->{http} = HTTP::Tiny->new(
        timeout    => $args{timeout},
        keep_alive => 1,
        verify_SSL => $args{tls_insecure} ? 0 : 1,
    );

    return $self;
}

sub _auth_headers( $self ) {
    return {} if $self->{user} eq 'default' && $self->{password} eq '';
    return {
        'X-ClickHouse-User' => $self->{user},
        'X-ClickHouse-Key'  => $self->{password},
    };
}

sub query( $self, $sql, $params = {} ) {
    my %qs = (
        database           => $self->{database},
        default_format     => 'JSONCompact',
        wait_end_of_query  => 1,
        %$params,
    );
    my $url = $self->{base_url} . '?' . $self->{http}->www_form_urlencode( \%qs );

    my $body;
    unless( gzip( \$sql => \$body ) ) {
        return { ok => 0, status => 599, body => "gzip compression failed: $GzipError", headers => {} };
    }

    my %req_headers = ( %{ $self->_auth_headers }, 'Accept-Encoding' => 'gzip', 'Content-Encoding' => 'gzip' );

    my $resp = $self->{http}->request( 'POST', $url, {
        headers => \%req_headers,
        content => $body,
    } );

    my $headers  = $resp->{headers};
    my $content  = $resp->{content};

    if( defined $content && length $content && ( $headers->{'content-encoding'} // '' ) eq 'gzip' ) {
        my $plain;
        unless( gunzip( \$content => \$plain ) ) {
            return { ok => 0, status => 599, body => "gzip decompression failed: $GunzipError", headers => $headers };
        }
        $content = $plain;
    }

    if( $resp->{success} ) {
        return {
            ok      => 1,
            status  => $resp->{status},
            body    => $content,
            headers => $headers,
        };
    }

    return {
        ok             => 0,
        status         => $resp->{status},
        body           => $content,
        headers        => $headers,
        exception_code => $headers->{'x-clickhouse-exception-code'},
    };
}

sub ping( $self ) {
    my $resp = $self->{http}->request( 'GET', $self->{base_url} . 'ping', {
        headers => $self->_auth_headers,
    } );

    return $resp->{success} ? 1 : 0;
}

# The Net::HTTP(S)-constructor SSL options for query_stream(), split out so
# the tls/tls_insecure decision is directly unit-testable without opening a
# real socket (query_stream() itself needs a live server to exercise).
# Certificate + hostname verification is requested explicitly (rather than
# relying on IO::Socket::SSL's version-dependent default) to match
# HTTP::Tiny's verify_SSL posture on the buffered path; tls_insecure => 1
# explicitly disables it (SSL_verify_mode => SSL_VERIFY_NONE) rather than
# just omitting the options, so behavior doesn't depend on library defaults.
sub _stream_tls_args( $self ) {
    return () unless $self->{tls};

    if( $self->{tls_insecure} ) {
        return ( SSL_verify_mode => SSL_VERIFY_NONE, SSL_hostname => $self->{host} );
    }

    return (
        SSL_verify_mode => SSL_VERIFY_PEER,
        SSL_hostname    => $self->{host},
        # IO::Socket::SSL only *warns* on a hostname mismatch unless a
        # verification scheme is set explicitly (see SSL_verifycn_scheme in
        # its docs) -- 'http' makes a mismatch a hard connection failure,
        # matching HTTP::Tiny's verify_SSL => 1 on the buffered path
        # instead of silently degrading to cert-only verification.
        SSL_verifycn_scheme => 'http',
    );
}

# Streaming query path for bounded-memory fetch of large result sets
# (opt-in via the 'fetch_batch_rows' DSN key / chng_fetch_batch_rows
# attribute -- see st::execute in DBD::ClickhouseNG). Unlike query(), which
# buffers the whole response via HTTP::Tiny, this opens a dedicated Net::HTTP
# (or Net::HTTPS) connection and returns a line-at-a-time reader so the
# caller can pull rows in bounded batches instead of decoding one big JSON
# document upfront. wait_end_of_query=1 is kept (server still buffers, so
# errors always arrive cleanly via status/headers before any body -- no
# mid-stream exception parsing); only client-side memory is bounded here.
# No response compression is requested in this mode: incremental gunzip of a
# chunked body adds real complexity for a case that's already an opt-in,
# secondary path.
sub query_stream( $self, $sql, $params = {} ) {
    my %qs = (
        database           => $self->{database},
        default_format     => 'JSONCompactEachRowWithNamesAndTypes',
        wait_end_of_query  => 1,
        %$params,
    );
    my $path = '/?' . $self->{http}->www_form_urlencode( \%qs );

    my $body;
    unless( gzip( \$sql => \$body ) ) {
        return { ok => 0, status => 599, body => "gzip compression failed: $GzipError", headers => {} };
    }

    my %req_headers = ( %{ $self->_auth_headers }, 'Content-Encoding' => 'gzip' );

    my $sock_class = $self->{tls} ? 'Net::HTTPS' : 'Net::HTTP';
    my $sock = $sock_class->new(
        Host      => $self->{host},
        PeerPort  => $self->{port},
        Timeout   => $self->{timeout},
        KeepAlive => 0,
        $self->_stream_tls_args,
    );
    unless( $sock ) {
        return { ok => 0, status => 599, body => "connection failed: $@", headers => {} };
    }

    unless( $sock->write_request( POST => $path, %req_headers, $body ) ) {
        return { ok => 0, status => 599, body => "request failed: $!", headers => {} };
    }

    my( $code, $mess, %raw_headers ) = eval { $sock->read_response_headers };
    if( $@ ) {
        ( my $msg = $@ ) =~ s/\s+\z//;
        return { ok => 0, status => 599, body => "response failed: $msg", headers => {} };
    }

    my %headers = map { ( lc( $_ ), $raw_headers{$_} ) } keys %raw_headers;

    unless( $code == 200 ) {
        my $content = '';
        while( 1 ) {
            my $chunk;
            my $n = $sock->read_entity_body( $chunk, 65536 );
            last unless $n;
            $content .= $chunk;
        }
        $sock->close;
        return {
            ok             => 0,
            status         => $code,
            body           => $content,
            headers        => \%headers,
            exception_code => $headers{'x-clickhouse-exception-code'},
        };
    }

    return {
        ok     => 1,
        status => $code,
        reader => DBD::ClickhouseNG::HTTP::LineReader->new( $sock ),
    };
}

# ---------------------------------------------------------------------------
# Line-at-a-time reader over anything providing Net::HTTP's
# read_entity_body($buf, $size) semantics (undef => error, 0 => EOF, -1 =>
# no data yet/retry, otherwise bytes read into $buf). Kept independent of
# Net::HTTP itself so the buffering/line-splitting logic can be unit tested
# against a fake socket feeding canned chunks.
# ---------------------------------------------------------------------------
package DBD::ClickhouseNG::HTTP::LineReader;

use v5.40;

sub new( $class, $sock ) {
    return bless { sock => $sock, buf => '', eof => 0 }, $class;
}

sub next_line( $self ) {
    while( 1 ) {
        my $idx = index( $self->{buf}, "\n" );
        if( $idx >= 0 ) {
            my $line = substr( $self->{buf}, 0, $idx );
            substr( $self->{buf}, 0, $idx + 1, '' );
            $line =~ s/\r\z//;
            return $line;
        }

        if( $self->{eof} ) {
            return undef unless length $self->{buf};
            my $line = $self->{buf};
            $self->{buf} = '';
            $line =~ s/\r\z//;
            return $line;
        }

        my $chunk;
        my $n = $self->{sock}->read_entity_body( $chunk, 65536 );
        die "streaming read failed: $!\n" unless defined $n;
        if( $n == 0 ) {
            $self->{eof} = 1;
            next;
        }
        next if $n == -1;
        $self->{buf} .= $chunk;
    }
}

sub close( $self ) {
    $self->{sock}->close if $self->{sock};
    $self->{sock} = undef;
    return;
}

1;
