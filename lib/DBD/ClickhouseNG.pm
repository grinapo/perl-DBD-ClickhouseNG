package DBD::ClickhouseNG;

use v5.40;
use DBI qw(:sql_types);
use Scalar::Util qw(looks_like_number);
use Carp ();

use DBD::ClickhouseNG::HTTP;

our $VERSION = '0.50';
our $drh;

# Cpanel::JSON::XS is a drop-in-compatible, actively-maintained XS
# accelerator for the same ->new->utf8->decode API JSON::PP provides;
# prefer it when installed, but never require it -- JSON::PP is core and
# always available as the correctness baseline.
our $JSON_CLASS = eval { require Cpanel::JSON::XS; 'Cpanel::JSON::XS' }
    // do { require JSON::PP; 'JSON::PP' };

sub driver( $class, $attr = undef ) {
    return $drh if $drh;
    $class .= '::dr';
    ( $drh ) = DBI::_new_drh( $class, {
        Name        => 'ClickhouseNG',
        Version     => $VERSION,
        Attribution => 'DBD::ClickhouseNG',
    } );
    return $drh;
}

sub CLONE {
    undef $drh;
}

# ---------------------------------------------------------------------------
# §7 placeholder scanning
# ---------------------------------------------------------------------------

sub _scan_quoted( $sql, $i, $len, $q ) {
    my $start = $i;
    $i++;
    while( $i < $len ) {
        my $c = substr( $sql, $i, 1 );
        if( $c eq '\\' && $i + 1 < $len ) {
            $i += 2;
            next;
        }
        if( $c eq $q ) {
            if( $i + 1 < $len && substr( $sql, $i + 1, 1 ) eq $q ) {
                $i += 2;
                next;
            }
            $i++;
            return ( substr( $sql, $start, $i - $start ), $i, 1 );
        }
        $i++;
    }
    return ( substr( $sql, $start ), $len, 0 );
}

# ClickHouse heredoc string literals: $tag$...$tag$, tag is \w* (REF).
# Recognized only when the full open+close pair is present; a lone '$' that
# doesn't start such a pair is ordinary text (ClickHouse has no other use of
# bare '$', but being permissive here costs nothing).
sub _scan_dollar_quoted( $sql, $i, $len ) {
    return undef unless substr( $sql, $i ) =~ /\A\$(\w*)\$/;
    my $tag   = $1;
    my $open  = "\$$tag\$";
    my $start = $i + length( $open );
    my $close = index( $sql, $open, $start );
    die "unterminated quote in statement\n" if $close == -1;
    my $end = $close + length( $open );
    return [ substr( $sql, $i, $end - $i ), $end ];
}

sub _scan_placeholders( $sql ) {
    my @segments;
    my $n   = 0;
    my $cur = '';
    my $i   = 0;
    my $len = length $sql;

    while( $i < $len ) {
        my $c  = substr( $sql, $i, 1 );
        my $c2 = substr( $sql, $i, 2 );

        if( $c eq "'" || $c eq '"' || $c eq '`' ) {
            my( $text, $new_i, $closed ) = _scan_quoted( $sql, $i, $len, $c );
            die "unterminated quote in statement\n" unless $closed;
            $cur .= $text;
            $i = $new_i;
        }
        elsif( $c eq '$' && ( my $dq = _scan_dollar_quoted( $sql, $i, $len ) ) ) {
            my( $text, $new_i ) = @$dq;
            $cur .= $text;
            $i = $new_i;
        }
        elsif( $c2 eq '--' || $c eq '#' ) {
            my $nl = index( $sql, "\n", $i );
            if( $nl == -1 ) {
                $cur .= substr( $sql, $i );
                $i = $len;
            }
            else {
                $cur .= substr( $sql, $i, $nl - $i + 1 );
                $i = $nl + 1;
            }
        }
        elsif( $c2 eq '/*' ) {
            my $end = index( $sql, '*/', $i + 2 );
            if( $end == -1 ) {
                $cur .= substr( $sql, $i );
                $i = $len;
            }
            else {
                $cur .= substr( $sql, $i, $end - $i + 2 );
                $i = $end + 2;
            }
        }
        elsif( $c2 eq '??' ) {
            # Escape for a literal '?' (e.g. ClickHouse's ternary `cond ? a
            # : b`, which would otherwise be misread as a placeholder):
            # '??' in the source collapses to one literal '?', uncounted.
            $cur .= '?';
            $i += 2;
        }
        elsif( $c eq '?' ) {
            push @segments, $cur;
            $cur = '';
            $n++;
            $i++;
        }
        else {
            $cur .= $c;
            $i++;
        }
    }
    push @segments, $cur;

    return ( \@segments, $n );
}

# A statement is eligible for the execute_array() fast (batched) path only
# when every placeholder sits inside one literal "VALUES(...)" tuple with
# nothing but bare commas between them and nothing but the closing paren
# (and optional trailing ";") after it. This is deliberately conservative:
# segments preserve quoted text verbatim (unparsed), so anything looser
# risks miscounting parens hidden inside a string literal. A statement that
# fails this check simply falls back to one execute() per tuple -- a missed
# optimization, never a correctness risk.
sub _is_batchable_insert( $segments, $n ) {
    return 0 if $n < 1;
    return 0 unless $segments->[0] =~ /\bVALUES\s*\(\s*\z/i;
    for my $i ( 1 .. $n - 1 ) {
        return 0 unless $segments->[$i] =~ /\A\s*,\s*\z/;
    }
    return 0 unless $segments->[$n] =~ /\A\s*\)\s*;?\s*\z/;
    return 1;
}

# ---------------------------------------------------------------------------
# §7 type inference for bound values
# ---------------------------------------------------------------------------

my %EXPLICIT_TYPE = (
    SQL_TINYINT()        => 'Int64',
    SQL_SMALLINT()       => 'Int64',
    SQL_INTEGER()        => 'Int64',
    SQL_BIGINT()         => 'Int64',
    SQL_FLOAT()          => 'Float64',
    SQL_REAL()           => 'Float64',
    SQL_DOUBLE()         => 'Float64',
    SQL_NUMERIC()        => 'Float64',
    SQL_DECIMAL()        => 'Float64',
    SQL_BOOLEAN()        => 'Bool',
    SQL_TYPE_DATE()      => 'Date',
    SQL_DATE()           => 'Date',
    SQL_TYPE_TIMESTAMP() => 'DateTime',
    SQL_TIMESTAMP()      => 'DateTime',
    SQL_VARCHAR()        => 'String',
    SQL_CHAR()           => 'String',
);

sub _extract_bind_type( $attr ) {
    return $attr->{TYPE} if ref $attr eq 'HASH';
    return $attr if defined $attr;
    return undef;
}

sub _infer_ch_type( $value, $sql_type ) {
    if( defined $sql_type ) {
        my $type = $EXPLICIT_TYPE{$sql_type} // 'String';
        return defined $value ? $type : "Nullable($type)";
    }

    return 'Nullable(String)' unless defined $value;
    if( looks_like_number( $value ) ) {
        return $value =~ /\A-?\d+\z/ ? 'Int64' : 'Float64';
    }
    return 'String';
}

sub _encode_param( $value, $ch_type ) {
    return '\N' unless defined $value;

    ( my $base_type = $ch_type ) =~ s/\ANullable\((.*)\)\z/$1/;
    return $value if $base_type =~ /\A(?:Int64|Float64|Bool|Date|DateTime)/;

    my $s = $value;
    $s =~ s/\\/\\\\/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    return $s;
}

# ---------------------------------------------------------------------------
# Literal SQL text embedding (execute_array's batched-INSERT fast path).
#
# Unlike _encode_param, whose output only ever travels as a separate
# param_pN HTTP value (never textually inside the SQL), _sql_literal's
# output is spliced directly into SQL text -- so it must be safe against
# injection on its own, independent of any type hint. The rule: only ever
# emit a hardcoded constant, a value we computed ourselves (the '1'/'0' for
# Bool), or the value's own text when it strictly matches a whole-string
# numeric regex; anything else always goes through _quote_string, which
# backslash/quote-escapes it. A bind type is never trusted enough by itself
# to justify unquoted interpolation of caller-supplied text.
# ---------------------------------------------------------------------------

sub _quote_string( $value ) {
    return 'NULL' unless defined $value;
    my $s = $value;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    return "'$s'";
}

my $STRICT_NUMBER_RE = qr/\A-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\z/;

sub _sql_literal( $value, $sql_type = undef ) {
    return 'NULL' unless defined $value;

    if( defined $sql_type && $sql_type == SQL_BOOLEAN() ) {
        return $value ? '1' : '0';
    }

    return $value if $value =~ $STRICT_NUMBER_RE;

    return _quote_string( $value );
}

# ---------------------------------------------------------------------------
# §8 result-column type mapping
# ---------------------------------------------------------------------------

sub _map_base_ch_type( $t ) {
    return ( SQL_INTEGER, undef, undef )
        if $t =~ /\A(?:U?Int(?:8|16|32))\z/;
    return ( SQL_BIGINT, undef, undef )
        if $t =~ /\A(?:U?Int(?:64|128|256))\z/;

    return ( SQL_FLOAT, undef, undef )  if $t eq 'Float32';
    return ( SQL_DOUBLE, undef, undef ) if $t eq 'Float64';

    if( $t =~ /\ADecimal\((\d+)\s*,\s*(\d+)\)\z/ ) {
        return ( SQL_DECIMAL, $1, $2 );
    }
    if( $t =~ /\ADecimal(?:32|64|128|256)\((\d+)\)\z/ ) {
        return ( SQL_DECIMAL, undef, $1 );
    }

    return ( SQL_BOOLEAN, undef, undef ) if $t eq 'Bool';

    if( $t =~ /\AFixedString\((\d+)\)\z/ ) {
        return ( SQL_VARCHAR, $1, undef );
    }
    return ( SQL_VARCHAR, undef, undef ) if $t eq 'String';

    return ( SQL_TYPE_DATE, undef, undef ) if $t =~ /\ADate(?:32)?\z/;
    return ( SQL_TYPE_TIMESTAMP, undef, undef )
        if $t =~ /\ADateTime(?:64)?(?:\(.*\))?\z/;

    return ( SQL_VARCHAR, undef, undef ) if $t =~ /\AEnum(?:8|16)\(.*\)\z/;
    return ( SQL_VARCHAR, undef, undef ) if $t eq 'UUID';

    return ( SQL_ARRAY, undef, undef )
        if $t =~ /\A(?:Array|Tuple|Map)\(.*\)\z/;

    return ( SQL_VARCHAR, undef, undef );
}

sub _unwrap_ch_type( $ch_type ) {
    my $nullable = 0;
    while( 1 ) {
        if( $ch_type =~ /\ANullable\((.*)\)\z/ ) {
            $ch_type = $1;
            $nullable = 1;
            next;
        }
        if( $ch_type =~ /\ALowCardinality\((.*)\)\z/ ) {
            $ch_type = $1;
            next;
        }
        last;
    }
    return ( $ch_type, $nullable );
}

sub _map_ch_type( $ch_type ) {
    my( $bare, $nullable ) = _unwrap_ch_type( $ch_type );
    my( $sql_type, $precision, $scale ) = _map_base_ch_type( $bare );
    return ( $sql_type, $precision, $scale, $nullable );
}

# FixedString(N) is ClickHouse's only fixed-width string type; it's padded
# with NUL bytes (not spaces) to its declared width. ChopBlanks support
# targets this padding, not literal ASCII spaces (which are legitimate
# FixedString content) -- see _chop_nul below.
sub _is_fixedstring_ch_type( $ch_type ) {
    my( $bare ) = _unwrap_ch_type( $ch_type );
    return $bare =~ /\AFixedString\(\d+\)\z/;
}

sub _chop_nul( $s ) {
    return $s unless defined $s;
    $s =~ s/\0+\z//;
    return $s;
}

sub _coerce_bigint( $s ) {
    return $s unless defined $s;
    no warnings 'numeric';
    my $n = 0 + $s;
    return "$n" eq $s ? $n : $s;
}

sub _coerce_bool( $v ) {
    return undef unless defined $v;
    return $v ? 1 : 0;
}

sub _value_converter( $sql_type ) {
    return \&_coerce_bigint if $sql_type == SQL_BIGINT;
    return \&_coerce_bool   if $sql_type == SQL_BOOLEAN;
    return undef;
}

# ---------------------------------------------------------------------------
# §9 error reporting
# ---------------------------------------------------------------------------

sub _utf8_bytes( $s ) {
    utf8::encode( my $bytes = $s );
    return $bytes;
}

sub _decode_error_body( $bytes ) {
    return $bytes unless defined $bytes;
    my $text = $bytes;
    utf8::decode( $text );
    return $text;
}

sub _report( $h, $res, $context ) {
    if( ( $res->{status} // 0 ) == 599 ) {
        my $state = ( $context eq 'connect' ) ? '08001' : '08S01';
        return $h->set_err( 1, _decode_error_body( $res->{body} ), $state );
    }

    if( defined $res->{exception_code} ) {
        my $msg = _decode_error_body( $res->{body} ) // '';
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

    my $msg = _decode_error_body( $res->{body} );
    $msg = $res->{status} unless defined $msg && length $msg;
    return $h->set_err( $res->{status}, $msg, 'S1000' );
}

# ---------------------------------------------------------------------------
# Catalog / introspection (table_info, column_info, type_info_all)
# ---------------------------------------------------------------------------

# Wraps a Perl array-of-arrays as a real DBI statement handle via the
# DBI-bundled DBD::Sponge driver -- the standard way catalog methods return
# an "active statement handle" over data queried through another means
# (here: our own system.tables/system.columns queries) rather than a fresh
# server round-trip of their own.
sub _sponge_sth( $dbh, $names, $rows ) {
    my $sponge = DBI->connect( 'dbi:Sponge:', '', '', { RaiseError => 0, PrintError => 0 } )
        or return $dbh->set_err( $DBI::stderr, "cannot create sponge handle for catalog method: $DBI::errstr" );
    my $sth = $sponge->prepare( '', { rows => $rows, NAME => $names } )
        or return $dbh->set_err( $DBI::stderr, "cannot create sponge statement for catalog method: " . $sponge->errstr );
    return $sth;
}

# table_info()'s $type argument: a comma-separated list of wanted
# TABLE_TYPE values, each optionally quoted (e.g. "'TABLE','VIEW'"). undef,
# empty, or '%' means "no filtering" (DBI/ODBC convention).
sub _parse_table_type_filter( $type ) {
    return undef unless defined $type && length $type;
    return undef if $type eq '%';
    my %wanted;
    for my $t ( split /,/, $type ) {
        $t =~ s/\A\s*'?//;
        $t =~ s/'?\s*\z//;
        $wanted{ uc $t } = 1;
    }
    return \%wanted;
}

# Splits ClickHouse's system.tables.primary_key text (e.g. "id, ts", or
# "id, toDate(ts)" for a functional key part) into its ordered key-part
# expressions. A naive split on ',' would break a key part that is itself a
# multi-argument function call (e.g. "id, someFunc(a, b)"); this respects
# parenthesis nesting instead. Each returned part is used as-is for
# primary_key_info's COLUMN_NAME -- a plain column name for a simple key,
# or the raw expression text for a functional one (DBI doesn't mandate a
# real column name here, and there is no other identifier to report).
sub _split_key_expr( $s ) {
    my @parts;
    my $depth = 0;
    my $cur   = '';
    for my $c ( split //, $s ) {
        if( $c eq '(' ) { $depth++; $cur .= $c; }
        elsif( $c eq ')' ) { $depth--; $cur .= $c; }
        elsif( $c eq ',' && $depth == 0 ) { push @parts, $cur; $cur = ''; }
        else { $cur .= $c; }
    }
    push @parts, $cur if length $cur;
    return map { ( my $t = $_ ) =~ s/\A\s+|\s+\z//g; $t } @parts;
}

# type_info_all() reference data: one row per ClickHouse scalar/compound
# type family, hand-derived from ClickHouse's documented value ranges (not
# queryable from the server itself). Fields:
#   [ TYPE_NAME, SQL_TYPE, COLUMN_SIZE, CASE_SENSITIVE, UNSIGNED_ATTRIBUTE, CREATE_PARAMS, QUOTED ]
# COLUMN_SIZE is the maximum precision/length the type can hold; undef where
# ClickHouse imposes no fixed bound (String, Array/Tuple/Map, and the
# parameterized FixedString/Enum families, whose actual per-column size
# comes from column_info instead). Int/UInt/Float families are given in
# bits (radix 2) and Decimal in decimal digits (radix 10), matching
# ClickHouse's own system.columns.numeric_precision/numeric_precision_radix
# convention verified live -- e.g. UInt32 reports precision=32, radix=2;
# Decimal(18,4) reports precision=18, radix=10.
# Within each DATA_TYPE group (e.g. Int8/Int16/Int32/UInt8/UInt16/UInt32 all
# map to SQL_INTEGER), the DBI spec requires ordering "closest first" --
# type_info() in scalar context returns only the first match, so the
# canonical/widest common width must lead its group (Int32/UInt32, not the
# 8-bit variant) or a caller doing scalar-context type_info(SQL_INTEGER)
# silently gets a truncating 8-bit type.
our @TYPE_INFO_SPEC = (
    [ 'Int32',       SQL_INTEGER,        32,    0, 0,     undef,                   0 ],
    [ 'Int16',       SQL_INTEGER,        16,    0, 0,     undef,                   0 ],
    [ 'Int8',        SQL_INTEGER,        8,     0, 0,     undef,                   0 ],
    [ 'UInt32',      SQL_INTEGER,        32,    0, 1,     undef,                   0 ],
    [ 'UInt16',      SQL_INTEGER,        16,    0, 1,     undef,                   0 ],
    [ 'UInt8',       SQL_INTEGER,        8,     0, 1,     undef,                   0 ],
    [ 'Int64',       SQL_BIGINT,         64,    0, 0,     undef,                   0 ],
    [ 'Int128',      SQL_BIGINT,         128,   0, 0,     undef,                   0 ],
    [ 'Int256',      SQL_BIGINT,         256,   0, 0,     undef,                   0 ],
    [ 'UInt64',      SQL_BIGINT,         64,    0, 1,     undef,                   0 ],
    [ 'UInt128',     SQL_BIGINT,         128,   0, 1,     undef,                   0 ],
    [ 'UInt256',     SQL_BIGINT,         256,   0, 1,     undef,                   0 ],
    [ 'Float32',     SQL_FLOAT,          32,    0, 0,     undef,                   0 ],
    [ 'Float64',     SQL_DOUBLE,         64,    0, 0,     undef,                   0 ],
    [ 'Decimal',     SQL_DECIMAL,        76,    0, 0,     'precision,scale',       0 ],
    [ 'Bool',        SQL_BOOLEAN,        1,     0, undef, undef,                   0 ],
    [ 'String',      SQL_VARCHAR,        undef, 1, undef, undef,                   1 ],
    [ 'FixedString', SQL_VARCHAR,        undef, 1, undef, 'length',                1 ],
    [ 'Date',        SQL_TYPE_DATE,      10,    0, undef, undef,                   1 ],
    [ 'Date32',      SQL_TYPE_DATE,      10,    0, undef, undef,                   1 ],
    [ 'DateTime',    SQL_TYPE_TIMESTAMP, 19,    0, undef, undef,                   1 ],
    [ 'DateTime64',  SQL_TYPE_TIMESTAMP, 29,    0, undef, 'precision',             1 ],
    [ 'Enum8',       SQL_VARCHAR,        undef, 1, undef, q{'value' = N, ...},     1 ],
    [ 'Enum16',      SQL_VARCHAR,        undef, 1, undef, q{'value' = N, ...},     1 ],
    [ 'UUID',        SQL_VARCHAR,        36,    1, undef, undef,                   1 ],
    [ 'Array',       SQL_ARRAY,          undef, 0, undef, 'type',                  0 ],
    [ 'Tuple',       SQL_ARRAY,          undef, 0, undef, 'type, ...',             0 ],
    [ 'Map',         SQL_ARRAY,          undef, 0, undef, 'key_type, value_type',  0 ],
);

# Minimal, curated subset of DBI's ~150 get_info() ODBC info codes -- only
# entries this driver can answer with a real, verifiable fact (see the
# get_info dispatch below for SQL_DBMS_VER, which is queried live rather
# than hardcoded). Everything else falls through to DBI's own undef
# default; deliberately not attempting ODBC-conformance-level completeness.
our %GET_INFO_TYPE = (
    6  => 'DBD::ClickhouseNG', # SQL_DRIVER_NAME
    7  => $VERSION,            # SQL_DRIVER_VER
    17 => 'ClickHouse',        # SQL_DBMS_NAME
    29 => '"',                 # SQL_IDENTIFIER_QUOTE_CHAR
    41 => '.',                 # SQL_CATALOG_NAME_SEPARATOR
    42 => 'database',          # SQL_CATALOG_TERM -- ClickHouse's one namespace level
    46 => 0,                   # SQL_TXN_CAPABLE = SQL_TC_NONE (no transactions)
);

1;

# ===========================================================================

{   package DBD::ClickhouseNG::dr;

    our $imp_data_size = 0;

    my %DSN_DEFAULT = (
        host             => 'localhost',
        port             => undef,
        database         => 'default',
        tls              => 0,
        tls_insecure     => 0,
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
            user         => $user,
            password     => $auth,
            database     => $opts{database},
            timeout      => $opts{timeout},
        );

        my $res = $client->query( 'SELECT 1' );
        unless( $res->{ok} ) {
            return DBD::ClickhouseNG::_report( $drh, $res, 'connect' );
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
}

# ===========================================================================

{   package DBD::ClickhouseNG::db;

    use DBI qw(:sql_types);

    our $imp_data_size = 0;

    sub prepare( $dbh, $statement, $attr = undef ) {
        my( $segments, $n_params );
        my $ok = eval {
            ( $segments, $n_params ) = DBD::ClickhouseNG::_scan_placeholders( $statement );
            1;
        };
        unless( $ok ) {
            ( my $msg = $@ ) =~ s/\s+\z//;
            return $dbh->set_err( $DBI::stderr, $msg );
        }

        my( $outer, $sth ) = DBI::_new_sth( $dbh, { Statement => $statement } );
        $sth->{chng_segments}          = $segments;
        $sth->{chng_params}            = [];
        $sth->{chng_param_types}       = [];
        $sth->{chng_param_bound}       = {};
        $sth->{chng_param_arrays}      = [];
        $sth->{chng_param_array_types} = [];
        $sth->{chng_param_array_bound} = {};
        $sth->{chng_rows}              = undef;
        $sth->{chng_data}              = undef;
        $outer->STORE( NUM_OF_PARAMS => $n_params );

        return $outer;
    }

    sub do( $dbh, $statement, $attr = undef, @bind_values ) {
        if( @bind_values || ( defined $attr && %$attr ) ) {
            my $sth = $dbh->prepare( $statement, $attr ) or return undef;
            return $sth->execute( @bind_values );
        }

        my $res = $dbh->{chng_client}->query( DBD::ClickhouseNG::_utf8_bytes( $statement ) );
        unless( $res->{ok} ) {
            return DBD::ClickhouseNG::_report( $dbh, $res, 'do' );
        }

        my $body = $res->{body};
        ( my $trimmed = $body ) =~ s/\s+\z//;
        return -1 if $trimmed eq '';

        my $json = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $body ) };
        unless( $json ) {
            return $dbh->set_err( $DBI::stderr,
                "malformed JSON response from server: " . substr( DBD::ClickhouseNG::_decode_error_body( $body ), 0, 200 ) );
        }
        my $rows = $json->{rows} // 0;
        return $rows || '0E0';
    }

    sub ping( $dbh ) {
        return 0 unless $dbh->FETCH( 'Active' );
        return $dbh->{chng_client}->ping ? 1 : 0;
    }

    sub disconnect( $dbh ) {
        $dbh->STORE( Active => 0 );
        return 1;
    }

    sub commit( $dbh ) {
        warn "commit ineffective with AutoCommit enabled" if $dbh->FETCH( 'Warn' );
        return 1;
    }

    sub rollback( $dbh ) {
        warn "rollback ineffective with AutoCommit enabled" if $dbh->FETCH( 'Warn' );
        return 1;
    }

    sub quote( $dbh, $value, $data_type = undef ) {
        return DBD::ClickhouseNG::_quote_string( $value );
    }

    sub get_info( $dbh, $info_type ) {
        if( $info_type == 18 ) {    # SQL_DBMS_VER -- varies by deployment, so queried live
            return $dbh->{chng_dbms_version} //= do {
                my $row = $dbh->selectrow_arrayref( 'SELECT version()' );
                $row ? $row->[0] : undef;
            };
        }
        return $DBD::ClickhouseNG::GET_INFO_TYPE{$info_type};
    }

    # Databases visible to the connected user, as DSNs reusing this handle's
    # own connection parameters (host/port/tls) so they're directly usable
    # with DBI->connect. No driver-level ($drh->data_sources) equivalent --
    # enumerating databases needs an actual connection, which the driver
    # handle doesn't have.
    sub data_sources( $dbh, $attr = undef ) {
        my $rows = $dbh->selectcol_arrayref( 'SHOW DATABASES' );
        return () unless $rows;

        my $client = $dbh->{chng_client};
        my $prefix = sprintf( 'dbi:ClickhouseNG:host=%s;port=%s;tls=%d;database=',
            $client->{host}, $client->{port}, $client->{tls} ? 1 : 0 );
        return map { "$prefix$_" } @$rows;
    }

    # ClickHouse has one namespace level (database), mapped to TABLE_CAT
    # per DBI/ODBC convention for single-level data sources; TABLE_SCHEM is
    # always undef ("not applicable"). $schema/$catalog='' therefore has a
    # specific DBI meaning: '' means "match rows where this level doesn't
    # apply", so a non-empty $schema can never match (no table has one),
    # while $catalog='' can never match either (every table has a database).
    # $catalog/$table accept SQL LIKE search patterns ('%', '_'), passed
    # through to ClickHouse's LIKE unchanged (same wildcard syntax).
    #
    # The ODBC special cases (catalog='%'+empty others => list catalogs;
    # schema='%'+empty others => list schemas; type='%'+empty others =>
    # list table types) are not implemented -- DBI marks them as only
    # "may... be supported by some drivers"; out of scope here.
    sub table_info( $dbh, $catalog, $schema, $table, $type = undef, $attr = undef ) {
        my @names = qw(TABLE_CAT TABLE_SCHEM TABLE_NAME TABLE_TYPE REMARKS);

        if( defined $schema && length $schema ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }
        if( defined $catalog && !length $catalog ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }

        my( @where, @bind );
        if( defined $catalog && length $catalog ) {
            push @where, 'database LIKE ?';
            push @bind, $catalog;
        }
        if( defined $table && length $table ) {
            push @where, 'name LIKE ?';
            push @bind, $table;
        }

        my $sql = 'SELECT database, name, engine, comment FROM system.tables';
        $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
        $sql .= ' ORDER BY database, name';

        my $rows = $dbh->selectall_arrayref( $sql, undef, @bind );
        return undef unless $rows;

        my $wanted = DBD::ClickhouseNG::_parse_table_type_filter( $type );

        my @out;
        for my $r ( @$rows ) {
            my( $db, $name, $engine, $comment ) = @$r;
            my $ttype = ( $engine eq 'View' ) ? 'VIEW' : 'TABLE';
            next if $wanted && !$wanted->{$ttype};
            push @out, [ $db, undef, $name, $ttype, ( length $comment ? $comment : undef ) ];
        }

        return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, \@out );
    }

    # See table_info's comment for the TABLE_CAT/TABLE_SCHEM mapping and
    # empty-string-vs-undef handling, which applies identically here.
    # DATA_TYPE/NULLABLE reuse _map_ch_type -- the same mapping the
    # non-catalog result-metadata path (st::execute) already uses -- so a
    # column's reported type here is always consistent with what a SELECT
    # of that column would report. COLUMN_SIZE/DECIMAL_DIGITS prefer
    # ClickHouse's own system.columns figures (more precise, e.g. actual
    # FixedString(N) length) over _map_ch_type's, falling back to it only
    # when the server didn't supply one.
    sub column_info( $dbh, $catalog, $schema, $table, $column ) {
        my @names = qw(
            TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME DATA_TYPE TYPE_NAME
            COLUMN_SIZE BUFFER_LENGTH DECIMAL_DIGITS NUM_PREC_RADIX NULLABLE
            REMARKS COLUMN_DEF SQL_DATA_TYPE SQL_DATETIME_SUB CHAR_OCTET_LENGTH
            ORDINAL_POSITION IS_NULLABLE
        );

        if( defined $schema && length $schema ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }
        if( defined $catalog && !length $catalog ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }

        my( @where, @bind );
        if( defined $catalog && length $catalog ) {
            push @where, 'database LIKE ?';
            push @bind, $catalog;
        }
        if( defined $table && length $table ) {
            push @where, 'table LIKE ?';
            push @bind, $table;
        }
        if( defined $column && length $column ) {
            push @where, 'name LIKE ?';
            push @bind, $column;
        }

        my $sql = 'SELECT database, table, name, type, position, default_kind, default_expression, '
                . 'comment, character_octet_length, numeric_precision, numeric_precision_radix, numeric_scale '
                . 'FROM system.columns';
        $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;
        $sql .= ' ORDER BY database, table, position';

        my $rows = $dbh->selectall_arrayref( $sql, undef, @bind );
        return undef unless $rows;

        my @out;
        for my $r ( @$rows ) {
            my( $db, $tbl, $name, $ch_type, $position, $default_kind, $default_expr,
                $comment, $char_octet_len, $num_prec, $num_prec_radix, $num_scale ) = @$r;

            my( $sql_type, $precision, $scale, $nullable ) = DBD::ClickhouseNG::_map_ch_type( $ch_type );

            push @out, [
                $db, undef, $tbl, $name,
                $sql_type, $ch_type,
                $num_prec // $precision // $char_octet_len,
                undef,
                $num_scale // $scale,
                $num_prec_radix,
                ( $nullable ? 1 : 0 ),    # DBI: SQL_NULLABLE=1 / SQL_NO_NULLS=0
                ( length $comment ? $comment : undef ),
                ( length $default_kind ? $default_expr : undef ),
                $sql_type,
                undef,
                $char_octet_len,
                $position,
                ( $nullable ? 'YES' : 'NO' ),
            ];
        }

        return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, \@out );
    }

    # ClickHouse has no PRIMARY KEY *constraint* the way DBI models one
    # (uniqueness-enforcing); what MergeTree-family tables have is an
    # ORDER BY/PRIMARY KEY *sorting* expression, exposed as
    # system.tables.primary_key. That's real, queryable metadata, so it's
    # reported here -- one row per top-level key-part expression (see
    # _split_key_expr), COLUMN_NAME being the plain column name for a
    # simple key part or the raw expression text for a functional one.
    # PK_NAME is always undef: ClickHouse sorting keys aren't named
    # constraints. A table with no ORDER BY (e.g. engine Memory, or
    # ORDER BY tuple()) reports no rows, same as DBI's "no primary key"
    # convention.
    #
    # Per DBI spec this method's arguments -- unlike table_info's -- don't
    # accept search patterns; exact match only (or undef for "no
    # restriction"). TABLE_CAT/TABLE_SCHEM semantics otherwise match
    # table_info/column_info (see their comments): TABLE_SCHEM is always
    # undef, and a non-empty $schema or an empty-string $catalog can never
    # match anything.
    sub primary_key_info( $dbh, $catalog, $schema, $table ) {
        my @names = qw(TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME KEY_SEQ PK_NAME);

        if( defined $schema && length $schema ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }
        if( defined $catalog && !length $catalog ) {
            return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, [] );
        }

        my @where = ( "primary_key != ''" );
        my @bind;
        if( defined $catalog && length $catalog ) {
            push @where, 'database = ?';
            push @bind, $catalog;
        }
        if( defined $table && length $table ) {
            push @where, 'name = ?';
            push @bind, $table;
        }

        my $sql = 'SELECT database, name, primary_key FROM system.tables WHERE '
                . join( ' AND ', @where ) . ' ORDER BY database, name';

        my $rows = $dbh->selectall_arrayref( $sql, undef, @bind );
        return undef unless $rows;

        my @out;
        for my $r ( @$rows ) {
            my( $db, $tbl, $pk ) = @$r;
            my $seq = 0;
            for my $part ( DBD::ClickhouseNG::_split_key_expr( $pk ) ) {
                push @out, [ $db, undef, $tbl, $part, ++$seq, undef ];
            }
        }

        return DBD::ClickhouseNG::_sponge_sth( $dbh, \@names, \@out );
    }

    # Static reference data (DBD::ClickhouseNG::TYPE_INFO_SPEC) -- no
    # server round-trip needed, ClickHouse's supported type list isn't
    # itself queryable.
    sub type_info_all( $dbh ) {
        my @idx_names = qw(
            TYPE_NAME DATA_TYPE COLUMN_SIZE LITERAL_PREFIX LITERAL_SUFFIX CREATE_PARAMS
            NULLABLE CASE_SENSITIVE SEARCHABLE UNSIGNED_ATTRIBUTE FIXED_PREC_SCALE
            AUTO_UNIQUE_VALUE LOCAL_TYPE_NAME MINIMUM_SCALE MAXIMUM_SCALE
            SQL_DATA_TYPE SQL_DATETIME_SUB NUM_PREC_RADIX INTERVAL_PRECISION
        );
        my %idx;
        @idx{@idx_names} = 0 .. $#idx_names;

        my %numeric_radix = (
            SQL_INTEGER() => 2,  SQL_BIGINT() => 2, SQL_DECIMAL() => 10,
            SQL_FLOAT()   => 2,  SQL_DOUBLE() => 2,
        );

        my @rows = ( \%idx );
        for my $spec ( @DBD::ClickhouseNG::TYPE_INFO_SPEC ) {
            my( $name, $sql_type, $col_size, $case_sensitive, $unsigned, $create_params, $quoted ) = @$spec;
            my $is_decimal = ( $name eq 'Decimal' );
            my $nullable   = ( $sql_type == SQL_ARRAY() ) ? 0 : 1;    # Nullable(Array(...)) etc. is rejected by ClickHouse

            push @rows, [
                $name, $sql_type, $col_size,
                ( $quoted ? "'" : undef ), ( $quoted ? "'" : undef ),
                $create_params,
                $nullable,
                $case_sensitive,
                3,                                  # SEARCHABLE: SQL_SEARCHABLE
                $unsigned,
                ( $is_decimal ? 1 : 0 ),             # FIXED_PREC_SCALE
                0,                                   # AUTO_UNIQUE_VALUE: no auto-increment in ClickHouse
                undef,                               # LOCAL_TYPE_NAME
                ( $is_decimal ? 0  : undef ),         # MINIMUM_SCALE
                ( $is_decimal ? 76 : undef ),         # MAXIMUM_SCALE
                $sql_type,                           # SQL_DATA_TYPE
                undef,                               # SQL_DATETIME_SUB
                $numeric_radix{$sql_type},
                undef,                                # INTERVAL_PRECISION
            ];
        }

        return \@rows;
    }

    sub STORE( $dbh, $attrib, $value ) {
        if( $attrib eq 'AutoCommit' ) {
            Carp::croak( 'DBD::ClickhouseNG does not support transactions (AutoCommit may not be disabled)' )
                unless $value;
            return $dbh->SUPER::STORE( $attrib, -901 );
        }
        if( $attrib =~ /\Achng_/ ) {
            $dbh->{$attrib} = $value;
            return 1;
        }
        return $dbh->SUPER::STORE( $attrib, $value );
    }

    sub FETCH( $dbh, $attrib ) {
        return 1 if $attrib eq 'AutoCommit';
        return $dbh->{$attrib} if $attrib =~ /\Achng_/;
        return $dbh->SUPER::FETCH( $attrib );
    }

    sub DESTROY( $dbh ) {
        $dbh->disconnect if $dbh->FETCH( 'Active' );
        return;
    }
}

# ===========================================================================

{   package DBD::ClickhouseNG::st;

    our $imp_data_size = 0;

    sub bind_param( $sth, $param, $value, $attr = undef ) {
        my $n = $sth->FETCH( 'NUM_OF_PARAMS' );
        return $sth->set_err( $DBI::stderr, "Cannot bind param $param, statement has $n parameters" )
            unless $param >= 1 && $param <= $n;

        my $type = DBD::ClickhouseNG::_extract_bind_type( $attr );

        $sth->{chng_params}[$param - 1] = $value;
        $sth->{chng_param_types}[$param - 1] = $type if defined $type;
        $sth->{chng_param_bound}{$param} = 1;
        return 1;
    }

    sub bind_param_array( $sth, $param, $value, $attr = undef ) {
        my $n = $sth->FETCH( 'NUM_OF_PARAMS' );
        return $sth->set_err( $DBI::stderr, "Cannot bind param $param, statement has $n parameters" )
            unless $param >= 1 && $param <= $n;

        my $type = DBD::ClickhouseNG::_extract_bind_type( $attr );

        $sth->{chng_param_arrays}[$param - 1] = $value;
        $sth->{chng_param_array_types}[$param - 1] = $type if defined $type;
        $sth->{chng_param_array_bound}{$param} = 1;
        return 1;
    }

    # Shared by the buffered and streaming execute() paths: apply a
    # {name,type} meta array to the sth's DBI/driver-private metadata
    # attributes and return the per-column value converters. Returns undef
    # (with $sth->err set) if the column count changed between executions
    # of a prepared statement.
    sub _apply_result_meta( $sth, $meta ) {
        if( !defined $sth->{chng_ch_types} ) {
            $sth->STORE( NUM_OF_FIELDS => scalar @$meta );
            $sth->STORE( NAME          => [ map { $_->{name} } @$meta ] );
        }
        else {
            return $sth->set_err( $DBI::stderr, "result column count changed between executions" )
                unless scalar( @$meta ) == $sth->FETCH( 'NUM_OF_FIELDS' );
        }

        my $chop_blanks = $sth->FETCH( 'ChopBlanks' );

        my( @types, @precision, @scale, @nullable, @converters );
        for my $col ( @$meta ) {
            my( $sql_type, $prec, $sc, $null ) = DBD::ClickhouseNG::_map_ch_type( $col->{type} );
            push @types, $sql_type;
            push @precision, $prec;
            push @scale, $sc;
            push @nullable, $null;
            push @converters, ( $chop_blanks && DBD::ClickhouseNG::_is_fixedstring_ch_type( $col->{type} ) )
                ? \&DBD::ClickhouseNG::_chop_nul
                : DBD::ClickhouseNG::_value_converter( $sql_type );
        }
        $sth->{chng_ch_types}  = [ map { $_->{type} } @$meta ];
        $sth->{chng_types}     = \@types;
        $sth->{chng_precision} = \@precision;
        $sth->{chng_scale}     = \@scale;
        $sth->{chng_nullable}  = \@nullable;

        return \@converters;
    }

    sub execute( $sth, @bind_values ) {
        if( @bind_values ) {
            for my $i ( 1 .. @bind_values ) {
                $sth->bind_param( $i, $bind_values[$i - 1] ) or return undef;
            }
        }

        my $n      = $sth->FETCH( 'NUM_OF_PARAMS' );
        my $params = $sth->{chng_params};
        return $sth->set_err( $DBI::stderr,
            "execute called with " . scalar( @$params ) . " bound values, statement has $n parameters" )
            unless @$params == $n;

        my $bound = $sth->{chng_param_bound} // {};
        for my $i ( 1 .. $n ) {
            return $sth->set_err( $DBI::stderr, "bind_param not called for parameter $i" )
                unless $bound->{$i};
        }

        my $segments = $sth->{chng_segments};
        my $types    = $sth->{chng_param_types};

        my $sql = $segments->[0];
        my %url_params;
        for my $i ( 1 .. $n ) {
            my $value = $params->[$i - 1];
            my $type  = DBD::ClickhouseNG::_infer_ch_type( $value, $types->[$i - 1] );
            $sql .= "{p$i:$type}" . $segments->[$i];
            $url_params{"param_p$i"} = DBD::ClickhouseNG::_encode_param( $value, $type );
        }

        # A re-execute is a clean slate: any streaming error left un-surfaced
        # by an abandoned previous result (caller stopped fetching without
        # exhausting the stream or calling finish()) belongs to that old
        # result, not this new execute() -- discard it before finish()
        # (below) gets a chance to resurface it against this execute.
        delete $sth->{chng_stream_error};
        $sth->finish;

        my $batch_rows = $sth->{chng_fetch_batch_rows} // $sth->{Database}{chng_fetch_batch_rows};
        if( $batch_rows ) {
            return $sth->set_err( $DBI::stderr, 'chng_fetch_batch_rows must be a positive integer' )
                unless $batch_rows =~ /\A[1-9][0-9]*\z/;
            return _execute_streaming( $sth, $sql, \%url_params, $batch_rows );
        }

        my $res = $sth->{Database}{chng_client}->query( DBD::ClickhouseNG::_utf8_bytes( $sql ), \%url_params );
        unless( $res->{ok} ) {
            return DBD::ClickhouseNG::_report( $sth, $res, 'execute' );
        }

        my $body = $res->{body};
        ( my $trimmed = $body ) =~ s/\s+\z//;
        if( $trimmed eq '' ) {
            $sth->{chng_rows} = -1;
            $sth->{chng_data} = undef;
            $sth->STORE( Active => 0 );
            return -1;
        }

        my $json = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $body ) };
        unless( $json ) {
            return $sth->set_err( $DBI::stderr,
                "malformed JSON response from server: " . substr( DBD::ClickhouseNG::_decode_error_body( $body ), 0, 200 ) );
        }

        my $meta       = $json->{meta} // [];
        my $converters = _apply_result_meta( $sth, $meta ) or return undef;

        my $data = $json->{data} // [];
        for my $row ( @$data ) {
            for my $i ( 0 .. $#$converters ) {
                next unless $converters->[$i];
                next unless defined $row->[$i];
                $row->[$i] = $converters->[$i]->( $row->[$i] );
            }
        }

        $sth->{chng_data} = $data;
        $sth->{chng_pos}  = 0;
        $sth->{chng_rows} = $json->{rows} // scalar @$data;
        $sth->STORE( Active => 1 );

        return $sth->{chng_rows} || '0E0';
    }

    # LineReader::next_line dies on a transport-level read failure (a
    # connection reset mid-body is a real failure mode even under
    # wait_end_of_query=1 -- the body is server-buffered, but still travels
    # over a fragile socket). Both streaming callers below go through this
    # instead of calling next_line directly, so such a failure becomes a
    # normal set_err()/undef return like every other transport failure in
    # this driver, rather than an uncaught die escaping fetch()/execute()
    # regardless of RaiseError.
    sub _reader_next_line( $reader ) {
        my $line = eval { $reader->next_line };
        if( $@ ) {
            ( my $msg = $@ ) =~ s/\s+\z//;
            return ( 0, $msg );
        }
        return ( 1, $line );
    }

    # Streaming counterpart of execute(): requests
    # JSONCompactEachRowWithNamesAndTypes over a dedicated Net::HTTP(S)
    # connection (see HTTP::query_stream) and reads only the two header
    # lines (names, types) up front -- data rows are pulled in
    # chng_fetch_batch_rows-sized batches by fetch()/_refill_streaming_batch
    # below, so client memory stays bounded to roughly one batch regardless
    # of result size. Row count is unknown ahead of the full scan, so rows()
    # returns -1 for a streamed statement, same as DBI's "not known" convention.
    sub _execute_streaming( $sth, $sql, $url_params, $batch_rows ) {
        my $res = $sth->{Database}{chng_client}->query_stream( DBD::ClickhouseNG::_utf8_bytes( $sql ), $url_params );
        unless( $res->{ok} ) {
            return DBD::ClickhouseNG::_report( $sth, $res, 'execute' );
        }

        my $reader = $res->{reader};

        my( $ok1, $names_line ) = _reader_next_line( $reader );
        unless( $ok1 ) {
            $reader->close;
            return $sth->set_err( $DBI::stderr, "streaming transport error: $names_line" );
        }
        my( $ok2, $types_line ) = _reader_next_line( $reader );
        unless( $ok2 ) {
            $reader->close;
            return $sth->set_err( $DBI::stderr, "streaming transport error: $types_line" );
        }

        # A statement with no result set (INSERT, DDL, ...) gets a clean
        # empty body -- no header lines at all -- same as the buffered
        # path's `$trimmed eq ''` case. Only *one* header line present is
        # the genuine truncation/malformed case.
        if( !defined $names_line && !defined $types_line ) {
            $reader->close;
            $sth->{chng_rows} = -1;
            $sth->{chng_data} = undef;
            $sth->STORE( Active => 0 );
            return -1;
        }
        unless( defined $names_line && defined $types_line ) {
            $reader->close;
            return $sth->set_err( $DBI::stderr, 'malformed streaming response: missing header lines' );
        }

        my $names     = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $names_line ) };
        my $types_raw = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $types_line ) };
        unless( $names && $types_raw ) {
            $reader->close;
            return $sth->set_err( $DBI::stderr, 'malformed JSON response from server (streaming header)' );
        }

        my $meta       = [ map { { name => $names->[$_], type => $types_raw->[$_] } } 0 .. $#$names ];
        my $converters = _apply_result_meta( $sth, $meta );
        unless( $converters ) {
            $reader->close;
            return undef;
        }

        $sth->{chng_reader}     = $reader;
        $sth->{chng_converters} = $converters;
        $sth->{chng_batch_rows} = $batch_rows;
        $sth->{chng_data}       = [];
        $sth->{chng_pos}        = 0;
        $sth->{chng_rows}       = -1;
        $sth->STORE( Active => 1 );

        return -1;
    }

    # Pull up to chng_batch_rows more decoded/converted rows from the
    # streaming reader into chng_data. Closes and clears chng_reader once
    # the stream is exhausted (or a malformed row/transport error forces an
    # early stop), so a subsequent fetch() sees a plain empty-buffer EOF.
    #
    # A transport error mid-batch is stashed in chng_stream_error rather
    # than reported via set_err() here: DBI resets err/errstr at the start
    # of every new top-level method dispatch, so if this batch already has
    # good rows to deliver, set_err() here would be invisibly wiped out
    # before the *next* fetch() call (the one that actually returns undef)
    # ever runs -- an error that fires but is never observable by the
    # caller. fetch() re-applies the stashed error via set_err() on the
    # call where it actually has nothing left to return.
    sub _refill_streaming_batch( $sth ) {
        my $reader     = $sth->{chng_reader};
        my $converters = $sth->{chng_converters};
        my $batch_rows = $sth->{chng_batch_rows};

        # A blank line (if the server ever emits one) is skipped without
        # counting toward the batch, so end-of-stream is detected only from
        # next_line() itself returning undef (or a malformed row forcing an
        # early stop) -- never inferred from an under-filled batch, which a
        # skipped blank line could otherwise cause spuriously.
        my @rows;
        my $done = 0;
        while( @rows < $batch_rows ) {
            my( $ok, $line ) = _reader_next_line( $reader );
            unless( $ok ) {
                $sth->{chng_stream_error} = [ $DBI::stderr, "streaming transport error: $line", 'S1000' ];
                $done = 1;
                last;
            }
            unless( defined $line ) {
                $done = 1;
                last;
            }
            next unless length $line;

            my $row = eval { $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( $line ) };
            unless( $row ) {
                $sth->{chng_stream_error} =
                    [ $DBI::stderr, 'malformed JSON response from server (streaming row)', 'S1000' ];
                $done = 1;
                last;
            }

            for my $i ( 0 .. $#$converters ) {
                next unless $converters->[$i];
                next unless defined $row->[$i];
                $row->[$i] = $converters->[$i]->( $row->[$i] );
            }
            push @rows, $row;
        }

        if( $done ) {
            $reader->close;
            $sth->{chng_reader} = undef;
        }

        $sth->{chng_data} = \@rows;
        $sth->{chng_pos}  = 0;
        return;
    }

    # execute_array: DBI's own array-binding idiom, optimized where it's
    # safe to be. Eligible shape (single-tuple "INSERT ... VALUES (?,...)",
    # see _is_batchable_insert) -> one batched raw-SQL INSERT, one HTTP
    # request regardless of tuple count. Anything else -> the same
    # per-tuple execute() loop DBI's own default implementation would use;
    # never silently skipped or mishandled.
    #
    # ArrayTupleFetch (row-wise supply via callback/sth) is deliberately
    # rejected with a clear error rather than silently ignored -- this
    # driver only implements the column-wise bind_param_array/@bind_values
    # forms.
    #
    # ArrayTupleStatus granularity: ClickHouse reports one pass/fail for
    # the whole batched statement, not per row. Default: on failure, every
    # tuple's status entry gets the same [err, errstr, state] (one HTTP
    # request either way). Opt in to per-row diagnosis with
    # chng_retry_on_error => 1 (in \%attr, or set beforehand on the
    # handle): only on a fast-path failure, retry once, looping execute()
    # per tuple so every row gets its own accurate status. Both modes
    # always populate a status entry for every tuple -- never left undef.
    sub execute_array( $sth, $attr, @bind_values ) {
        return $sth->set_err( $DBI::stderr, 'execute_array requires a hashref as its first argument' )
            unless ref $attr eq 'HASH';
        return $sth->set_err( $DBI::stderr,
            'ArrayTupleFetch is not supported by DBD::ClickhouseNG; use bind_param_array or column-wise @bind_values instead' )
            if $attr->{ArrayTupleFetch};

        if( @bind_values ) {
            for my $i ( 1 .. @bind_values ) {
                $sth->bind_param_array( $i, $bind_values[$i - 1] ) or return undef;
            }
        }

        my $n     = $sth->FETCH( 'NUM_OF_PARAMS' );
        my $bound = $sth->{chng_param_array_bound} // {};
        for my $i ( 1 .. $n ) {
            return $sth->set_err( $DBI::stderr, "bind_param_array not called for parameter $i" )
                unless $bound->{$i};
        }

        my $arrays = $sth->{chng_param_arrays}      // [];
        my $types  = $sth->{chng_param_array_types} // [];

        my $tuple_count = 0;
        my $any_array   = 0;
        for my $i ( 0 .. $n - 1 ) {
            my $v = $arrays->[$i];
            if( ref $v eq 'ARRAY' ) {
                $any_array = 1;
                $tuple_count = @$v if @$v > $tuple_count;
            }
        }
        $tuple_count = 1 if $n == 0 || !$any_array;

        # Every array-bound param must supply exactly one value per tuple; a
        # shorter array would otherwise silently pad missing tuples with
        # undef instead of erroring, per DBI's array-bind convention (only
        # bound scalars broadcast to every tuple).
        for my $i ( 0 .. $n - 1 ) {
            my $v = $arrays->[$i];
            next unless ref $v eq 'ARRAY';
            return $sth->set_err( $DBI::stderr,
                "bind_param_array for parameter @{[ $i + 1 ]} has " . scalar( @$v )
                    . " values, expected $tuple_count" )
                unless @$v == $tuple_count;
        }

        $sth->finish;

        if( $tuple_count == 0 ) {
            @{ $attr->{ArrayTupleStatus} } = () if ref $attr->{ArrayTupleStatus} eq 'ARRAY';
            return '0E0';
        }

        my $extract_tuple = sub( $idx ) {
            return [ map {
                my $v = $arrays->[$_];
                ref $v eq 'ARRAY' ? $v->[$idx] : $v;
            } 0 .. $n - 1 ];
        };

        my @tuple_status;
        my $ok;
        if( DBD::ClickhouseNG::_is_batchable_insert( $sth->{chng_segments}, $n ) ) {
            my $retry_safe;
            ( $ok, $retry_safe ) = _execute_array_fast_path( $sth, $tuple_count, $arrays, $types, \@tuple_status );
            if( !$ok && $attr->{chng_retry_on_error} && $retry_safe ) {
                @tuple_status = ();
                $ok = _execute_array_looped( $sth, $tuple_count, $extract_tuple, \@tuple_status );
            }
        }
        else {
            $ok = _execute_array_looped( $sth, $tuple_count, $extract_tuple, \@tuple_status );
        }

        @{ $attr->{ArrayTupleStatus} } = @tuple_status if ref $attr->{ArrayTupleStatus} eq 'ARRAY';

        unless( $ok ) {
            # If retry-on-error ran and the *last* attempted tuple happened
            # to succeed, that success would otherwise leave $sth->err
            # cleared -- silently hiding the fact that the batch overall
            # failed (RaiseError/PrintError would never fire, and a caller
            # checking $sth->err after a failed execute_array would
            # wrongly see "no error"). Re-assert a representative failure
            # (the first failing tuple found) so err/errstr/state always
            # reflect the true outcome before returning.
            my( $first_error ) = grep { ref $_ } @tuple_status;
            $sth->set_err( @$first_error ) if $first_error;
        }

        return $ok ? $tuple_count : undef;
    }

    sub _execute_array_fast_path( $sth, $tuple_count, $arrays, $types, $tuple_status ) {
        my $segments = $sth->{chng_segments};
        my $n        = scalar @$arrays;

        my @tuple_inner;
        for my $idx ( 0 .. $tuple_count - 1 ) {
            my @literals;
            for my $i ( 0 .. $n - 1 ) {
                my $v     = $arrays->[$i];
                my $value = ref $v eq 'ARRAY' ? $v->[$idx] : $v;
                push @literals, DBD::ClickhouseNG::_sql_literal( $value, $types->[$i] );
            }
            push @tuple_inner, join( ',', @literals );
        }

        my $sql = $segments->[0] . join( '),(', @tuple_inner ) . $segments->[$n];

        my $res = $sth->{Database}{chng_client}->query( DBD::ClickhouseNG::_utf8_bytes( $sql ) );
        unless( $res->{ok} ) {
            DBD::ClickhouseNG::_report( $sth, $res, 'execute_array' );
            my $status = [ $sth->err, $sth->errstr, $sth->state ];
            @$tuple_status = ($status) x $tuple_count;
            # A transport failure (599) means the batch's actual effect on
            # the server is unknown -- retrying row-by-row here could
            # silently duplicate data that was already written before the
            # response was lost. Only a definitive server-side rejection
            # is safe to retry (see DESIGN.md's no-retry rationale, §9).
            my $retry_safe = ( ($res->{status} // 0) != 599 );
            return ( 0, $retry_safe );
        }

        @$tuple_status = (-1) x $tuple_count;
        $sth->{chng_rows} = -1;
        return ( 1, 1 );
    }

    sub _execute_array_looped( $sth, $tuple_count, $extract_tuple, $tuple_status ) {
        my $all_ok = 1;
        for my $idx ( 0 .. $tuple_count - 1 ) {
            my $tuple = $extract_tuple->( $idx );
            my $rv    = $sth->execute( @$tuple );
            if( defined $rv ) {
                push @$tuple_status, $rv;
            }
            else {
                $all_ok = 0;
                push @$tuple_status, [ $sth->err, $sth->errstr, $sth->state ];
            }
        }
        return $all_ok;
    }

    sub fetch( $sth ) {
        my $data = $sth->{chng_data}
            or return $sth->set_err( $DBI::stderr, 'fetch without successful execute' );

        if( $sth->{chng_pos} >= @$data && $sth->{chng_reader} ) {
            _refill_streaming_batch( $sth );
            $data = $sth->{chng_data};
        }

        if( $sth->{chng_pos} >= @$data ) {
            # finish() (below) is itself a dispatched DBI call, and DBI
            # clears err/errstr at the start of every dispatch -- so any
            # set_err() here, before calling finish(), would be wiped out
            # by finish()'s own dispatch before fetch() ever returns.
            # finish() itself applies any stashed chng_stream_error last,
            # which survives since nothing dispatches after it.
            $sth->finish;
            return undef;
        }
        return $sth->_set_fbav( $data->[ $sth->{chng_pos}++ ] );
    }
    no warnings 'once';
    *fetchrow_arrayref = \&fetch;
    use warnings 'once';

    sub rows( $sth ) {
        return $sth->{chng_rows} // -1;
    }

    sub finish( $sth ) {
        if( my $reader = delete $sth->{chng_reader} ) {
            $reader->close;
        }
        $sth->{chng_data} = undef;
        $sth->{chng_pos}  = undef;
        $sth->STORE( Active => 0 );
        $sth->SUPER::finish();

        # Surface (rather than silently drop) a transport error hit
        # mid-batch but not yet reported -- e.g. the caller finishing
        # directly instead of exhausting fetch() (see
        # _refill_streaming_batch's comment on why this can't be reported
        # at the point it happened). Must be the last thing finish() does:
        # DBI clears err/errstr at the start of every dispatched call, so
        # set_err() has to run after STORE/SUPER::finish() above, not
        # before, or those dispatches would wipe it out again.
        if( my $err = delete $sth->{chng_stream_error} ) {
            $sth->set_err( @$err );
        }
        return 1;
    }

    sub FETCH( $sth, $attrib ) {
        return $sth->{chng_types}     if $attrib eq 'TYPE';
        return $sth->{chng_precision} if $attrib eq 'PRECISION';
        return $sth->{chng_scale}     if $attrib eq 'SCALE';
        return $sth->{chng_nullable}  if $attrib eq 'NULLABLE';
        if( $attrib eq 'ParamValues' ) {
            my $params = $sth->{chng_params} || [];
            return { map { $_ + 1 => $params->[$_] } 0 .. $#$params };
        }
        if( $attrib eq 'ParamTypes' ) {
            my $types = $sth->{chng_param_types} || [];
            return { map { $_ + 1 => $types->[$_] } 0 .. $#$types };
        }
        if( $attrib eq 'ParamArrays' ) {
            my $arrays = $sth->{chng_param_arrays};
            return undef unless $arrays && @$arrays;
            return { map { $_ + 1 => $arrays->[$_] } 0 .. $#$arrays };
        }
        return $sth->{$attrib} if $attrib =~ /\Achng_/;
        return $sth->SUPER::FETCH( $attrib );
    }

    sub STORE( $sth, $attrib, $value ) {
        return $sth->{NAME} = $value if $attrib eq 'NAME';
        if( $attrib =~ /\Achng_/ ) {
            $sth->{$attrib} = $value;
            return 1;
        }
        return $sth->SUPER::STORE( $attrib, $value );
    }
}

__END__

=head1 NAME

DBD::ClickhouseNG - DBI driver for ClickHouse over its HTTP interface

=head1 SYNOPSIS

    use DBI;

    my $dbh = DBI->connect(
        'dbi:ClickhouseNG:host=db1;port=8123;database=default;tls=0;timeout=30',
        $user, $password,
        { RaiseError => 1, AutoCommit => 1 },
    );

    my $sth = $dbh->prepare( 'SELECT id, name FROM users WHERE id = ?' );
    $sth->execute( 42 );
    while( my $row = $sth->fetchrow_arrayref ) {
        ...
    }

    $dbh->do( 'INSERT INTO users (id, name) VALUES (?, ?)', undef, 1, 'alice' );

=head1 DESCRIPTION

C<DBD::ClickhouseNG> is a DBI driver for ClickHouse's HTTP interface. It is a
minimal, DBI-compliant reimplementation of the ideas behind the old
C<DBD::Clickhouse> distribution.

The driver name is C<ClickhouseNG>, not C<Clickhouse::NG>: DBI parses the
driver name out of a DSN with a C<\w+> match, so a driver name cannot contain
C<::>.

=head1 DSN

    dbi:ClickhouseNG:host=db1;port=8123;database=default;tls=0;timeout=30

Recognized keys (unknown keys make C<connect> fail):

=over 4

=item host

Default C<localhost>. Must not be empty, and must not contain C</> or
whitespace. For an IPv6 literal, supply your own brackets (e.g.
C<host=[::1]>) -- the driver passes C<host> through into the URL unchanged.

=item port

Default C<8123>, or C<8443> if C<tls=1>. Must be a positive integer if given.

=item database

Default C<default>.

=item tls

C<0> (default) for HTTP, C<1> for HTTPS. No other value is accepted (e.g.
C<tls=false> is rejected rather than silently treated as true).

=item tls_insecure

C<0> (default) or C<1>; requires C<tls=1> (an error otherwise). C<1>
disables both certificate and hostname verification on the TLS connection
-- for a self-signed or otherwise unverifiable certificate in a dev/test
environment. Explicitly turns verification off (C<HTTP::Tiny>'s
C<verify_SSL => 0>, C<Net::HTTPS>'s C<SSL_verify_mode => SSL_VERIFY_NONE>)
rather than merely omitting it, so behavior doesn't depend on library
defaults. B<Security note:> this accepts any certificate, including an
expired, self-signed, or actively substituted one -- only use it against a
server and network you trust, e.g. a local/private development instance.

=item timeout

Seconds, default C<30>. Must be a positive number if given.

=item fetch_batch_rows

Undefined (off) by default. If set, must be a positive integer; turns on
bounded-batch streaming fetch for every statement on this connection (see
L</STREAMING LARGE RESULT SETS>). Overridable per statement via
C<< $sth->{chng_fetch_batch_rows} >>.

=back

Any of the above failing validation makes C<connect> fail with a driver-detected
usage error (see L</ERROR HANDLING>) rather than a confusing later transport
failure.

Username and password are passed as the normal 2nd/3rd arguments to
C<DBI-E<gt>connect>, not as DSN keys. An undefined username defaults to
C<default>; an undefined password defaults to the empty string. Both are sent
as HTTP header values (C<X-ClickHouse-User> / C<X-ClickHouse-Key>); a value
containing a CR or LF is rejected by the underlying HTTP client rather than
risking header injection.

=head1 SUPPORTED METHODS

C<connect>, C<prepare>, C<do>, C<ping>, C<disconnect>, C<commit>,
C<rollback>, C<quote>, C<bind_param>, C<execute>, C<bind_param_array>,
C<execute_array>, C<fetch> / C<fetchrow_arrayref> (and everything DBI derives
from it: C<fetchrow_array>, C<fetchrow_hashref>, C<fetchall_arrayref>,
C<selectall_arrayref>, etc.), C<rows>, C<finish>, C<table_info>,
C<column_info>, C<type_info_all>, C<primary_key_info> (and
C<tables>/C<type_info>/C<primary_key>, which DBI derives from those),
C<get_info>, C<data_sources>.

ClickHouse has no transactions: C<AutoCommit> can never be disabled (attempting
to do so croaks), and C<commit>/C<rollback> are no-ops that warn when C<Warn>
is set, per the DBI convention for non-transactional drivers.

C<foreign_key_info> and C<statistics_info> are not applicable; DBI's
defaults apply, since ClickHouse has no foreign-key concept and no directly
analogous index-statistics model to report. See L</CATALOG METHODS> for
C<table_info>/C<column_info>/C<type_info_all>/C<primary_key_info>. Column
C<NAME>/C<TYPE> metadata for an ordinary query result comes from the
result set's own metadata (unrelated to the catalog methods).

A driver-private attribute, C<< $sth->{chng_ch_types} >>, exposes the raw
ClickHouse type strings (e.g. C<Nullable(String)>) for each result column,
alongside the standard DBI C<TYPE>/C<PRECISION>/C<SCALE>/C<NULLABLE>.

=head1 PLACEHOLDERS AND PARAMETER BINDING

ClickHouse has no native positional C<?> placeholder; it has typed named
query parameters (C<{name:Type}> passed as C<param_name=value>). This driver
translates DBI's C<?> convention into that form transparently: the type is
inferred from the bound Perl value, or taken from an explicit
C<bind_param($n, $value, $sql_type)> call.

Only one row of placeholder values is sent per C<execute()> call -- one HTTP
round-trip each. See L</BULK LOADING> below for why this is unsuitable for
loading large amounts of data, and what to use instead.

Native C<{name:Type}> parameters written directly in SQL pass through
untouched, but this driver provides no way to bind their values from Perl;
use C<?> placeholders instead.

C<execute()> and C<execute_array()> both require every declared placeholder to
have been bound (via C<bind_param>/C<bind_param_array>, or positionally via
C<execute(@bind_values)>/the array-bind C<@bind_values> form) -- a statement
with an unbound placeholder is a driver-detected usage error, not silently
sent as C<NULL>.

=head2 Literal C<?> in SQL text (ternary, JSON operators, etc.)

ClickHouse's ternary operator (C<cond ? a : b>) uses a bare C<?>, which is
indistinguishable from a DBI placeholder by lexical scanning alone. Write
C<??> to get one literal, uncounted C<?> in the statement actually sent to
the server:

    $dbh->prepare( 'SELECT x ?? 7 : 8' );   # sent to ClickHouse as: SELECT x ? 7 : 8

C<??> is only recognized outside quoted/comment/dollar-quoted regions, same
as C<?> itself.

=head2 Dollar-quoted strings

ClickHouse heredoc-style string literals (C<$tag$...$tag$>, C<$tag> any
run of word characters or empty, e.g. C<$$...$$>) are recognized by the
placeholder scanner the same way C<'>/C<">/C<`> quoting is: their contents
pass through verbatim, so a C<?> or an unbalanced quote character inside one
is not misread. An opening C<$tag$> with no matching closing C<$tag$> is a
driver-detected "unterminated quote" error, same as an unterminated C<'>/C<">/C<`>.

=head1 BULK LOADING

C<execute(@bind_values)> binds and sends exactly B<one row> of placeholder
values per call. ClickHouse's own operational guidance is the opposite of
one-row-per-request: each C<INSERT> creates one MergeTree part, and many
small inserts cause part explosion and C<Too many parts> throttling. ClickHouse
recommends batching on the order of thousands to hundreds of thousands of rows
per C<INSERT>.

B<Do not call C<execute()> in a loop to bulk-load data.> That reproduces the
row-per-request pattern ClickHouse advises against, with an added HTTP
round-trip per row on top.

Two ways to bulk-load instead:

=head2 execute_array (the DBI-idiomatic way)

    my $sth = $dbh->prepare( 'INSERT INTO users (id, name) VALUES (?, ?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );
    $sth->bind_param_array( 2, [ 'alice', 'bob', 'carol' ] );
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \my @status } );

For a statement shaped exactly like the example above -- a single C<?>-tuple
immediately after C<VALUES>, nothing else -- this sends the B<whole batch as
one HTTP request>, regardless of row count, by building one raw multi-row
C<INSERT> internally (values are safely quoted the same way C<< $dbh->quote
>> would). Anything else (C<UPDATE>, multiple C<VALUES> tuples, mixed
literal/placeholder tuples, etc.) transparently falls back to one
C<execute()> call per row -- correct DBI behavior, just not accelerated.

Every array bound via C<bind_param_array> must have the same length (a bound
scalar broadcasts to every tuple instead, per the DBI convention); a
shorter/longer array is a driver-detected usage error, not silently
C<NULL>-padded.

B<ArrayTupleStatus> granularity: ClickHouse reports one pass/fail for the
I<whole> batched statement, not per row. By default, on failure every
tuple's status entry gets the same C<[err, errstr, state]> and
C<execute_array> returns C<undef> -- one HTTP request either way. Pass
C<< chng_retry_on_error => 1 >> (in the C<\%attr> hashref, or set
beforehand as C<< $sth->{chng_retry_on_error} = 1 >>) to opt into precise
per-row diagnosis: only when the batched attempt fails with a definite
server-side rejection, it retries once, looping C<execute()> per tuple so
every row gets its own accurate status.

That retry never happens after an ambiguous B<transport> failure (a dropped
connection, a timeout) -- in that case the batch's actual effect on the
server is unknown, and retrying could silently duplicate rows that were
already written before the response was lost. Those failures always use the
uniform (same status for every tuple) reporting, regardless of
C<chng_retry_on_error>.

C<ArrayTupleFetch> (row-wise supply via a callback or another statement
handle) is not supported and is rejected with a clear error rather than
silently ignored; use C<bind_param_array> or column-wise C<@bind_values>
instead.

C<< $sth->{ParamArrays} >> reflects whatever's currently bound via
C<bind_param_array>/C<execute_array>'s column-wise C<@bind_values>, keyed by
1-based parameter number (per DBI convention). It's C<undef> if no arrays
are bound.

=head2 Raw multi-row SQL (for anything execute_array can't accelerate)

Sent with no bind parameters through C<do($sql)> or
C<< prepare($sql)->execute() >>. SQL text is always sent as the POST body, so
a single call can carry a very large statement in one HTTP request:

    my @rows = ( [ 1, 'alice' ], [ 2, 'bob' ], ... );   # thousands of rows

    my $sql = 'INSERT INTO users (id, name) VALUES '
        . join( ',', map {
            '(' . join( ',', $_->[0], $dbh->quote( $_->[1] ) ) . ')'
        } @rows );

    $dbh->do( $sql );

Quote every scalar with C<< $dbh->quote >> (or C<quote_identifier> for
identifiers); never interpolate untrusted values directly into the SQL text.

Parameterized C<execute()> remains correct for single-row INSERT/DML and
ordinary parameterized SELECT; it must not be used in a loop for bulk
loading.

=head2 Bulk read-back

By default, result sets are parsed from a single buffered C<JSONCompact>
HTTP response -- the whole response is held in memory before any row is
available via C<fetch>. This is simple and avoids partial-row/chunk-boundary
parsing, but it means a very-large-row-count C<SELECT> costs memory
proportional to the whole result. For read-heavy access to very large
tables, see L</STREAMING LARGE RESULT SETS> for the opt-in bounded-batch
alternative.

=head1 STREAMING LARGE RESULT SETS

Opt-in, off by default (see the C<fetch_batch_rows> DSN key under L</DSN>).
When enabled -- connection-wide via the DSN, or per statement via
C<< $sth->{chng_fetch_batch_rows} >> set any time after C<prepare> and
before C<execute> -- C<execute()> requests
C<JSONCompactEachRowWithNamesAndTypes> over a dedicated C<Net::HTTP>/
C<Net::HTTPS> connection (line-oriented: one JSON array per column-name
line, one per column-type line, then one per data row) instead of
C<HTTP::Tiny>'s buffered C<JSONCompact>. C<fetch()> reads and decodes rows
in batches of C<fetch_batch_rows> rows at a time, so client memory stays
bounded to roughly one batch rather than the whole result.

With C<tls=1>, this connects via C<Net::HTTPS> with certificate and
hostname verification requested explicitly (C<SSL_verify_mode>,
C<SSL_verifycn_scheme => 'http'>), matching the buffered path's
C<verify_SSL => 1> (see also C<tls_insecure> under L</DSN>). Verified live,
for both the buffered and streaming transports: a valid certificate
connects and queries successfully with verification on; a hostname
mismatch is correctly refused with verification on; and C<tls_insecure=1>
connects successfully despite that same mismatch.

C<wait_end_of_query=1> (see L</ERROR HANDLING>) still applies in this mode:
the server still buffers the complete result before responding, so errors
are still reported cleanly via the HTTP status/headers before any row data,
never mid-stream. This means streaming here bounds client memory only, not
server memory.

Two behavioral differences from the buffered path:

=over 4

=item *

C<< $sth->rows >> returns C<-1> (unknown) for a streamed C<SELECT> -- the
row count isn't known until the scan completes, per DBI's "not known"
convention.

=item *

The streaming connection does not request response compression; only the
default buffered path does (see L</TRANSPORT COMPRESSION>).

=back

C<finish()> closes the underlying streaming connection if it hasn't been
fully read yet, so it's safe to abandon a partially-fetched streamed
statement and reuse the C<$dbh> for other queries.

The memory bound only holds when rows are consumed one at a time via
C<fetch>/C<fetchrow_*>. C<fetchall_arrayref>, C<selectall_arrayref>,
C<selectall_hashref>, and similar DBI generic helpers are built on top of
C<fetch> -- they still read the transport in bounded batches, but then
accumulate every row into the single arrayref/hashref they return, so the
result as a whole is unbounded again.

=head1 CATALOG METHODS

C<table_info>, C<column_info>, and C<type_info_all> are implemented,
querying C<system.tables>/C<system.columns> over the same HTTP interface as
any other statement, and wrapping the results as a real statement handle
via the DBI-bundled C<DBD::Sponge>. C<tables()>, C<type_info()>, and
C<primary_key()> work automatically on top of these via DBI's generic
layer.

ClickHouse has one namespace level (the database), so:

=over 4

=item *

C<TABLE_CAT> is the ClickHouse database name; C<TABLE_SCHEM> is always
C<undef> ("not applicable" -- ClickHouse has no schema level).

=item *

A non-empty C<$schema> argument to C<table_info>/C<column_info> can never
match anything (no table has one); an empty-string C<$catalog> argument
can never match anything either (every table has a database) -- per DBI's
documented convention that C<''> means "match rows where this level
doesn't apply." C<undef> means "no restriction" for both, as usual.

=item *

C<$catalog>/C<$table>/C<$column> accept SQL C<LIKE> search patterns
(C<%>, C<_>), passed through to ClickHouse's C<LIKE> unchanged. This means a
literal name containing C<_> (e.g. C<user_sessions>) also matches names
that differ in that position (C<userXsessions>) -- a caller that needs an
exact match, not a pattern, must escape it (C<user\_sessions>) or filter
the returned rows themselves.

=item *

The ODBC catalog-function special cases (C<$catalog='%'> with the other
arguments empty to list catalogs; C<$schema='%'> to list schemas;
C<$type='%'> to list table types) are not implemented -- DBI marks these as
only optionally supported.

=back

C<DATA_TYPE>/C<NULLABLE> in C<column_info> reuse C<_map_ch_type>, the same
mapping ordinary result-set metadata uses (see L</SUPPORTED METHODS>), so a
column's reported type is always consistent with what a C<SELECT> of that
column would report. C<COLUMN_SIZE>/C<DECIMAL_DIGITS>/C<NUM_PREC_RADIX>
prefer ClickHouse's own C<system.columns> figures when available (e.g. the
actual length of a C<FixedString(N)> column, or a C<Decimal(P,S)> column's
precision/scale) over falling back to C<_map_ch_type>'s more approximate
values.

C<type_info_all> is static reference data (ClickHouse's own type list isn't
itself queryable); C<COLUMN_SIZE> is given in bits with C<NUM_PREC_RADIX=2>
for integer/float families and in decimal digits with C<NUM_PREC_RADIX=10>
for C<Decimal>, matching what C<system.columns> itself reports for real
columns of those types.

=head2 primary_key_info

ClickHouse has no PRIMARY KEY I<constraint> the way DBI models one
(uniqueness-enforcing); what MergeTree-family tables have instead is a real,
queryable ORDER BY/PRIMARY KEY I<sorting> expression
(C<system.tables.primary_key>), which is what this reports -- one row per
top-level key-part expression, ordered by C<KEY_SEQ>. C<COLUMN_NAME> is the
plain column name for a simple key part, or the raw expression text (e.g.
C<toDate(ts)>) for a functional one -- splitting on commas respects
parenthesis nesting, so a multi-argument function in a key part (e.g.
C<someFunc(a, b)>) isn't broken into two rows. C<PK_NAME> is always
C<undef>: ClickHouse sorting keys aren't named constraints. A table with no
C<ORDER BY> (e.g. a C<Memory>-engine table) returns no rows, per DBI's "no
primary key" convention.

Unlike C<table_info>/C<column_info>, C<$catalog>/C<$schema>/C<$table> here
do B<not> accept search patterns (per DBI spec) -- exact match only, or
C<undef> for "no restriction". The C<TABLE_CAT>/C<TABLE_SCHEM>
empty-string-vs-undef handling is otherwise identical to C<table_info>'s
(see above).

C<foreign_key_info> and C<statistics_info> remain not applicable --
unlike C<primary_key_info>, ClickHouse genuinely has no foreign-key concept
and no directly analogous index-statistics model, so there is nothing to
query.

=head1 DRIVER METADATA

=head2 get_info

Only a small, curated set of DBI's ~150 ODBC info codes is implemented --
ones this driver can answer with a real, verifiable fact rather than a
guess: C<SQL_DRIVER_NAME>, C<SQL_DRIVER_VER>, C<SQL_DBMS_NAME>,
C<SQL_DBMS_VER> (queried from the server via C<SELECT version()> and cached
on the handle), C<SQL_IDENTIFIER_QUOTE_CHAR> (C<">),
C<SQL_CATALOG_NAME_SEPARATOR> (C<.>), C<SQL_CATALOG_TERM> (C<database> --
ClickHouse's one namespace level), and C<SQL_TXN_CAPABLE>
(C<SQL_TC_NONE> -- no transactions). Every other info type returns C<undef>,
DBI's own default for unimplemented codes.

=head2 data_sources

C<< $dbh->data_sources >> lists the databases visible to the connected
user (via C<SHOW DATABASES>), returned as full C<dbi:ClickhouseNG:...> DSNs
that reuse the handle's own host/port/tls, so they're directly usable with
C<< DBI->connect >>. There is no driver-level C<< $drh->data_sources >>
equivalent -- enumerating databases needs an actual connection, which the
driver handle doesn't have; it continues to return an empty list.

=head2 ChopBlanks

C<FixedString(N)> is ClickHouse's only fixed-width string type, and it's
padded with NUL bytes (C<\0>), not spaces, to its declared width.
C<ChopBlanks> is interpreted accordingly: when true (inherited from C<$dbh>
or set per-statement, per the usual DBI convention), trailing C<\0> bytes
are stripped from C<FixedString> column values on fetch. Trailing space
characters are left untouched, since a space is legitimate C<FixedString>
content in ClickHouse, not padding. No other column type is affected.

=head1 JSON DECODING

C<Cpanel::JSON::XS> is used when installed (an XS-accelerated, API-compatible
drop-in for C<JSON::PP>); otherwise the driver falls back to C<JSON::PP>
(core, always available). Neither is a hard dependency beyond C<JSON::PP>
itself -- C<Cpanel::JSON::XS> is purely an optional speed-up, selected once
at load time and exposed as C<$DBD::ClickhouseNG::JSON_CLASS> for
inspection/testing.

=head1 TRANSPORT COMPRESSION

Every request is sent gzip-compressed (C<Content-Encoding: gzip>) and asks
for a gzip-compressed response (C<Accept-Encoding: gzip>), using only core
modules (C<IO::Compress::Gzip> / C<IO::Uncompress::Gunzip>). This is
unconditional -- there is no DSN knob to disable it. ClickHouse also supports
several other codecs (zstd, lz4, br, ...) on this header, but none of them
has a corresponding pure-Perl or reliably-installable XS module that
produces the exact container format ClickHouse's HTTP server expects (in
particular, the C<Compress::LZ4> CPAN module emits its own non-standard
framing, not the LZ4 frame format ClickHouse requires); gzip was chosen
specifically because it is core and was verified working end-to-end against
a live server.

=head1 ERROR HANDLING

All failures go through C<< $h->set_err(...) >>, so C<RaiseError>,
C<PrintError>, and C<HandleError> behave per normal DBI semantics. Methods
return C<undef>/false after C<set_err> -- nothing dies except attempting to
disable C<AutoCommit>, which is a fatal usage error per DBI convention.

=over 4

=item Transport failure at connect time

C<err> is C<1>, C<state> is C<08001>.

=item Transport failure after connect

C<err> is C<1>, C<state> is C<08S01>.

=item Server exception (C<X-ClickHouse-Exception-Code> header present)

C<err> is the ClickHouse exception code, C<state> is C<S1000>.

=item Non-200 response without that header

C<err> is the HTTP status code, C<state> is C<S1000>.

=item 200 response but the body isn't valid JSON

C<err> is C<$DBI::stderr>, C<state> is C<S1000>.

=item Driver-detected usage error

C<err> is C<$DBI::stderr>, C<state> is C<S1000>.

=back

There is no retry logic: a dropped connection is not retried, because
retrying a possibly-already-executed statement (e.g. an INSERT) is unsafe.
HTTP keep-alive reconnects transparently for subsequent, fresh requests.

=head1 QUOTING

C<< $dbh->quote($value) >> escapes C<\> and C<'> and wraps the result in
single quotes (C<undef> becomes C<NULL>), matching ClickHouse string literal
escaping (backslash is an escape character there, unlike plain SQL
C<''>-doubling). C<quote_identifier> uses DBI's default double-quote-doubling
behavior, which is already correct for ClickHouse.

=head1 SEE ALSO

L<DBI>.

=head1 AUTHOR

Peter Gervai <grin@grin.hu>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the terms of either:

=over 4

=item *

the GNU General Public License as published by the Free Software
Foundation; either version 3, or (at your option) any later version, or

=item *

the "Artistic License".

=back

=cut
