package DBD::ClickhouseNG::Catalog;

# Responsibility: DBI catalog and metadata methods -- get_info,
# data_sources (connected form), table_info, column_info, primary_key_info,
# type_info_all -- and their static reference data (archive/DESIGN.md §4,
# "Catalog methods"). Each function takes the ::db handle as its first
# argument; DBD::ClickhouseNG::db holds one-line delegates to them.
# Interface: get_info, data_sources, table_info, column_info,
#   primary_key_info, type_info_all.
# Internal deps: Types (map_ch_type). Reads $dbh->{chng_client} (data_sources)
#   and owns $dbh->{chng_dbms_version} (get_info cache).

use v5.40;
use DBI qw(:sql_types);

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
    17 => 'ClickHouse',        # SQL_DBMS_NAME
    29 => '"',                 # SQL_IDENTIFIER_QUOTE_CHAR
    41 => '.',                 # SQL_CATALOG_NAME_SEPARATOR
    42 => 'database',          # SQL_CATALOG_TERM -- ClickHouse's one namespace level
    46 => 0,                   # SQL_TXN_CAPABLE = SQL_TC_NONE (no transactions)
);

sub get_info( $dbh, $info_type ) {
    # SQL_DRIVER_VER -- read at call time: this module is loaded at compile
    # time of DBD::ClickhouseNG, before its runtime $VERSION assignment.
    return $DBD::ClickhouseNG::VERSION if $info_type == 7;

    if( $info_type == 18 ) {    # SQL_DBMS_VER -- varies by deployment, so queried live
        return $dbh->{chng_dbms_version} //= do {
            my $row = $dbh->selectrow_arrayref( 'SELECT version()' );
            $row ? $row->[0] : undef;
        };
    }
    return $GET_INFO_TYPE{$info_type};
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
        return _sponge_sth( $dbh, \@names, [] );
    }
    if( defined $catalog && !length $catalog ) {
        return _sponge_sth( $dbh, \@names, [] );
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

    my $wanted = _parse_table_type_filter( $type );

    my @out;
    for my $r ( @$rows ) {
        my( $db, $name, $engine, $comment ) = @$r;
        my $ttype = ( $engine eq 'View' ) ? 'VIEW' : 'TABLE';
        next if $wanted && !$wanted->{$ttype};
        push @out, [ $db, undef, $name, $ttype, ( length $comment ? $comment : undef ) ];
    }

    return _sponge_sth( $dbh, \@names, \@out );
}

# See table_info's comment for the TABLE_CAT/TABLE_SCHEM mapping and
# empty-string-vs-undef handling, which applies identically here.
# DATA_TYPE/NULLABLE reuse Types::map_ch_type -- the same mapping the
# non-catalog result-metadata path (st::execute) already uses -- so a
# column's reported type here is always consistent with what a SELECT
# of that column would report. COLUMN_SIZE/DECIMAL_DIGITS prefer
# ClickHouse's own system.columns figures (more precise, e.g. actual
# FixedString(N) length) over Types::map_ch_type's, falling back to it only
# when the server didn't supply one.
sub column_info( $dbh, $catalog, $schema, $table, $column ) {
    my @names = qw(
        TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME DATA_TYPE TYPE_NAME
        COLUMN_SIZE BUFFER_LENGTH DECIMAL_DIGITS NUM_PREC_RADIX NULLABLE
        REMARKS COLUMN_DEF SQL_DATA_TYPE SQL_DATETIME_SUB CHAR_OCTET_LENGTH
        ORDINAL_POSITION IS_NULLABLE
    );

    if( defined $schema && length $schema ) {
        return _sponge_sth( $dbh, \@names, [] );
    }
    if( defined $catalog && !length $catalog ) {
        return _sponge_sth( $dbh, \@names, [] );
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

        my( $sql_type, $precision, $scale, $nullable ) = DBD::ClickhouseNG::Types::map_ch_type( $ch_type );

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

    return _sponge_sth( $dbh, \@names, \@out );
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
        return _sponge_sth( $dbh, \@names, [] );
    }
    if( defined $catalog && !length $catalog ) {
        return _sponge_sth( $dbh, \@names, [] );
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
        for my $part ( _split_key_expr( $pk ) ) {
            push @out, [ $db, undef, $tbl, $part, ++$seq, undef ];
        }
    }

    return _sponge_sth( $dbh, \@names, \@out );
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
    for my $spec ( @TYPE_INFO_SPEC ) {
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

1;
