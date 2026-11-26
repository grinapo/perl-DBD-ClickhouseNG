package DBD::ClickhouseNG::Types;

# Responsibility: everything about value types -- bind-type extraction and
# inference, encoding of bound values as HTTP params, SQL literal/quoting
# for the batched-INSERT path, and mapping of ClickHouse result-column types
# to DBI SQL types plus their per-value converters (archive/DESIGN.md §7, §8).
# Interface: extract_bind_type, infer_ch_type, encode_param, quote_string,
#   sql_literal, map_ch_type, is_fixedstring_ch_type, chop_nul,
#   value_converter.
# Internal deps: none. Pure functions; only constant lexical tables.

use v5.40;
use DBI qw(:sql_types);
use Scalar::Util qw(looks_like_number);

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

sub extract_bind_type( $attr ) {
    return $attr->{TYPE} if ref $attr eq 'HASH';
    return $attr if defined $attr;
    return undef;
}

sub infer_ch_type( $value, $sql_type ) {
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

sub encode_param( $value, $ch_type ) {
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
# Unlike encode_param, whose output only ever travels as a separate
# param_pN HTTP value (never textually inside the SQL), sql_literal's
# output is spliced directly into SQL text -- so it must be safe against
# injection on its own, independent of any type hint. The rule: only ever
# emit a hardcoded constant, a value we computed ourselves (the '1'/'0' for
# Bool), or the value's own text when it strictly matches a whole-string
# numeric regex; anything else always goes through quote_string, which
# backslash/quote-escapes it. A bind type is never trusted enough by itself
# to justify unquoted interpolation of caller-supplied text.
# ---------------------------------------------------------------------------

sub quote_string( $value ) {
    return 'NULL' unless defined $value;
    my $s = $value;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    return "'$s'";
}

my $STRICT_NUMBER_RE = qr/\A-?[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?\z/;

sub sql_literal( $value, $sql_type = undef ) {
    return 'NULL' unless defined $value;

    if( defined $sql_type && $sql_type == SQL_BOOLEAN() ) {
        return $value ? '1' : '0';
    }

    return $value if $value =~ $STRICT_NUMBER_RE;

    return quote_string( $value );
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

sub map_ch_type( $ch_type ) {
    my( $bare, $nullable ) = _unwrap_ch_type( $ch_type );
    my( $sql_type, $precision, $scale ) = _map_base_ch_type( $bare );
    return ( $sql_type, $precision, $scale, $nullable );
}

# FixedString(N) is ClickHouse's only fixed-width string type; it's padded
# with NUL bytes (not spaces) to its declared width. ChopBlanks support
# targets this padding, not literal ASCII spaces (which are legitimate
# FixedString content) -- see chop_nul below.
sub is_fixedstring_ch_type( $ch_type ) {
    my( $bare ) = _unwrap_ch_type( $ch_type );
    return $bare =~ /\AFixedString\(\d+\)\z/;
}

sub chop_nul( $s ) {
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

sub value_converter( $sql_type ) {
    return \&_coerce_bigint if $sql_type == SQL_BIGINT;
    return \&_coerce_bool   if $sql_type == SQL_BOOLEAN;
    return undef;
}

1;
