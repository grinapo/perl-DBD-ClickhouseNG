package DBD::ClickhouseNG::Error;

# Responsibility: UTF-8 byte conversion of outgoing SQL, decoding of server
# error bodies, and mapping of HTTP/ClickHouse failures onto DBI errors
# (err/errstr/state via set_err) (archive/DESIGN.md §9).
# Interface: utf8_bytes, decode_error_body, report.
# Internal deps: none. No state; report() only calls $h->set_err.

use v5.40;

# ---------------------------------------------------------------------------
# §9 error reporting
# ---------------------------------------------------------------------------

sub utf8_bytes( $s ) {
    utf8::encode( my $bytes = $s );
    return $bytes;
}

sub decode_error_body( $bytes ) {
    return $bytes unless defined $bytes;
    my $text = $bytes;
    utf8::decode( $text );
    return $text;
}

sub report( $h, $res, $context ) {
    if( ( $res->{status} // 0 ) == 599 ) {
        my $state = ( $context eq 'connect' ) ? '08001' : '08S01';
        return $h->set_err( 1, decode_error_body( $res->{body} ), $state );
    }

    if( defined $res->{exception_code} ) {
        my $msg = decode_error_body( $res->{body} ) // '';
        $msg =~ s/\s+\z//;
        if( my $qid = $res->{headers}{'x-clickhouse-query-id'} ) {
            $msg .= " (query_id: $qid)";
        }
        # A malformed/non-numeric exception code must never coerce down to
        # 0 -- DBI treats a defined-but-false err as a mere warning
        # (PrintWarn), not an error, which would misreport a definite
        # server-side failure as a non-fatal warning. Fall back to
        # $DBI::stderr (the same sentinel used for other driver-detected,
        # non-server-numbered errors) whenever the header isn't a clean
        # non-negative integer.
        my $code = $res->{exception_code};
        my $err  = ( $code =~ /\A[0-9]+\z/ ) ? $code + 0 : $DBI::stderr;
        return $h->set_err( $err, $msg, 'S1000' );
    }

    my $msg = decode_error_body( $res->{body} );
    $msg = $res->{status} unless defined $msg && length $msg;
    return $h->set_err( $res->{status}, $msg, 'S1000' );
}

1;
