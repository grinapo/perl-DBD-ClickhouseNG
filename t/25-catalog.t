use v5.40;
use Test::More;
use DBI;
use JSON::PP;

use DBD::ClickhouseNG;

# Catalog/introspection methods (table_info, column_info, type_info_all,
# and tables()/type_info() which DBI derives generically from them) query
# system.tables/system.columns internally through the same transport as any
# other statement, so they're mocked the same way as t/20-dbi-glue.t.

my @queue;
my @query_calls;
local *DBD::ClickhouseNG::HTTP::query = sub {
    my( $self, $sql, $params ) = @_;
    push @query_calls, [ $sql, $params ];
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

sub connect_ok {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    return DBI->connect( 'dbi:ClickhouseNG:host=nowhere', 'default', '',
        { RaiseError => 0, PrintError => 0 } );
}

sub jsoncompact {
    my( $meta, $rows ) = @_;
    return JSON::PP->new->utf8->encode( { meta => $meta, data => $rows, rows => scalar @$rows } );
}

sub tables_response {
    my( $rows ) = @_;
    return { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ map { { name => $_, type => 'String' } } qw(database name engine comment) ],
        $rows,
    ) };
}

subtest 'table_info returns TABLE_CAT/TABLE_SCHEM/TABLE_NAME/TABLE_TYPE/REMARKS from system.tables' => sub {
    my $dbh = connect_ok();
    @queue = ( tables_response( [ [ 'db1', 't1', 'MergeTree', '' ], [ 'db1', 'v1', 'View', 'a view' ] ] ) );

    my $sth = $dbh->table_info( undef, undef, undef );
    is_deeply( $sth->{NAME}, [ qw(TABLE_CAT TABLE_SCHEM TABLE_NAME TABLE_TYPE REMARKS) ] );
    is_deeply( $sth->fetchall_arrayref, [
        [ 'db1', undef, 't1', 'TABLE', undef ],
        [ 'db1', undef, 'v1', 'VIEW', 'a view' ],
    ] );
    $dbh->disconnect;
};

subtest 'table_info: a non-empty $schema always returns empty (ClickHouse has no schema level)' => sub {
    my $dbh = connect_ok();
    @query_calls = ();
    my $sth = $dbh->table_info( undef, 'someschema', undef );
    is_deeply( $sth->fetchall_arrayref, [] );
    is( scalar( @query_calls ), 0, 'short-circuited before touching the transport' );
    $dbh->disconnect;
};

subtest q{table_info: $catalog = '' matches nothing (every table has a database)} => sub {
    my $dbh = connect_ok();
    @query_calls = ();
    my $sth = $dbh->table_info( '', undef, undef );
    is_deeply( $sth->fetchall_arrayref, [] );
    is( scalar( @query_calls ), 0 );
    $dbh->disconnect;
};

subtest '$catalog/$table are passed through as LIKE search patterns' => sub {
    my $dbh = connect_ok();
    @queue = ( tables_response( [] ) );
    $dbh->table_info( 'db%', undef, 't_1' );
    my( $sql, $params ) = @{ $query_calls[-1] };
    like( $sql, qr/database LIKE \{p1:String\}/ );
    like( $sql, qr/name LIKE \{p2:String\}/ );
    is( $params->{param_p1}, 'db%' );
    is( $params->{param_p2}, 't_1' );
    $dbh->disconnect;
};

subtest '$type filters the result to the requested TABLE_TYPE values' => sub {
    my $dbh = connect_ok();
    @queue = ( tables_response( [ [ 'db1', 't1', 'MergeTree', '' ], [ 'db1', 'v1', 'View', '' ] ] ) );
    my $sth = $dbh->table_info( undef, undef, undef, 'VIEW' );
    is_deeply( $sth->fetchall_arrayref, [ [ 'db1', undef, 'v1', 'VIEW', undef ] ] );
    $dbh->disconnect;
};

subtest 'tables() works generically on top of table_info' => sub {
    my $dbh = connect_ok();
    @queue = ( tables_response( [ [ 'db1', 't1', 'MergeTree', '' ] ] ) );
    my @t = $dbh->tables( undef, undef, undef );
    # DBI's generic tables() quotes catalog.table via quote_identifier() once
    # SQL_IDENTIFIER_QUOTE_CHAR (get_info type 29) is non-empty -- see DBI.pm's
    # tables(). TABLE_SCHEM is always undef for us, so it's omitted.
    is_deeply( \@t, [ '"db1"."t1"' ] );
    $dbh->disconnect;
};

subtest 'a query failure during table_info is reported via set_err, not silently empty' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 497,
                 headers => { 'x-clickhouse-exception-code' => 497 }, body => 'Not enough privileges' } );
    my $sth = $dbh->table_info( undef, undef, undef );
    ok( !defined $sth, 'table_info returns undef on failure' );
    like( $dbh->errstr, qr/Not enough privileges/ );
    $dbh->disconnect;
};

subtest 'column_info returns column metadata consistent with the driver\'s own type mapping' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ map { { name => $_, type => 'String' } } qw(
            database table name type position default_kind default_expression
            comment character_octet_length numeric_precision numeric_precision_radix numeric_scale
        ) ],
        [ [ 'db1', 't1', 'id', 'UInt32', 1, '', '', '', undef, 32, 2, 0 ] ],
    ) } );

    my $sth = $dbh->column_info( undef, undef, 't1', undef );
    is_deeply( $sth->{NAME}, [ qw(
        TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME DATA_TYPE TYPE_NAME
        COLUMN_SIZE BUFFER_LENGTH DECIMAL_DIGITS NUM_PREC_RADIX NULLABLE
        REMARKS COLUMN_DEF SQL_DATA_TYPE SQL_DATETIME_SUB CHAR_OCTET_LENGTH
        ORDINAL_POSITION IS_NULLABLE
    ) ] );
    my $row = $sth->fetchall_arrayref->[0];
    is( $row->[0], 'db1',                'TABLE_CAT' );
    is( $row->[2], 't1',                 'TABLE_NAME' );
    is( $row->[3], 'id',                 'COLUMN_NAME' );
    is( $row->[4], DBI::SQL_INTEGER(),   'DATA_TYPE matches _map_ch_type(UInt32)' );
    is( $row->[5], 'UInt32',             'TYPE_NAME is the raw ClickHouse type string' );
    is( $row->[6], 32,                   'COLUMN_SIZE from system.columns.numeric_precision' );
    is( $row->[9], 2,                    'NUM_PREC_RADIX from system.columns.numeric_precision_radix' );
    is( $row->[10], 0,                   'NULLABLE = SQL_NO_NULLS (0), UInt32 is not Nullable' );
    is( $row->[16], 1,                   'ORDINAL_POSITION' );
    is( $row->[17], 'NO',                'IS_NULLABLE' );
    $dbh->disconnect;
};

subtest 'column_info: a Nullable column reports NULLABLE=1/IS_NULLABLE=YES' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ map { { name => $_, type => 'String' } } qw(
            database table name type position default_kind default_expression
            comment character_octet_length numeric_precision numeric_precision_radix numeric_scale
        ) ],
        [ [ 'db1', 't1', 'name', 'Nullable(String)', 2, '', '', '', undef, undef, undef, undef ] ],
    ) } );

    my $row = $dbh->column_info( undef, undef, 't1', undef )->fetchall_arrayref->[0];
    is( $row->[10], 1,    'NULLABLE = SQL_NULLABLE (1)' );
    is( $row->[17], 'YES' );
    $dbh->disconnect;
};

subtest 'type_info_all returns static reference data with a valid index hash, no server round-trip' => sub {
    my $dbh = connect_ok();
    @query_calls = ();
    my $tia = $dbh->type_info_all;
    is( scalar( @query_calls ), 0, 'purely static -- no query issued' );

    my $idx = $tia->[0];
    is( $idx->{TYPE_NAME}, 0 );
    is( $idx->{DATA_TYPE}, 1 );
    is( $idx->{COLUMN_SIZE}, 2 );

    my( $string_row ) = grep { $_->[0] eq 'String' } @$tia[ 1 .. $#$tia ];
    ok( $string_row, 'String type present' );
    is( $string_row->[1], DBI::SQL_VARCHAR() );

    my( $uint32_row ) = grep { $_->[0] eq 'UInt32' } @$tia[ 1 .. $#$tia ];
    is( $uint32_row->[2], 32, 'UInt32 COLUMN_SIZE is bit-width' );
    is( $uint32_row->[9], 1,  'UInt32 UNSIGNED_ATTRIBUTE' );
    $dbh->disconnect;
};

subtest 'type_info() works generically on top of type_info_all' => sub {
    my $dbh = connect_ok();
    my @ti = $dbh->type_info( DBI::SQL_VARCHAR() );
    ok( @ti > 0 );
    ok( ( grep { $_->{TYPE_NAME} eq 'String' } @ti ), 'String is among the SQL_VARCHAR matches' );
    $dbh->disconnect;
};

subtest 'type_info() in scalar context returns the canonical (widest) type per DATA_TYPE group, not a truncating one' => sub {
    my $dbh = connect_ok();
    # DBI: type_info_all's rows must be ordered "closest first" within a
    # DATA_TYPE group, because scalar-context type_info() returns only the
    # first match -- a caller picking "an integer column type" must not
    # silently get the 8-bit variant and truncate at 127.
    my $int = $dbh->type_info( DBI::SQL_INTEGER() );
    is( $int->{TYPE_NAME}, 'Int32', 'SQL_INTEGER group leads with Int32, not Int8/Int16' );

    my $big = $dbh->type_info( DBI::SQL_BIGINT() );
    is( $big->{TYPE_NAME}, 'Int64', 'SQL_BIGINT group leads with Int64, not Int128/Int256' );
    $dbh->disconnect;
};

sub pk_response {
    my( $rows ) = @_;
    return { ok => 1, status => 200, headers => {}, body => jsoncompact(
        [ map { { name => $_, type => 'String' } } qw(database name primary_key) ],
        $rows,
    ) };
}

subtest 'primary_key_info: one row per key part, split on top-level commas only' => sub {
    my $dbh = connect_ok();
    @queue = ( pk_response( [ [ 'db1', 't1', 'id, toDate(ts)' ] ] ) );

    my $sth = $dbh->primary_key_info( undef, undef, 't1' );
    is_deeply( $sth->{NAME}, [ qw(TABLE_CAT TABLE_SCHEM TABLE_NAME COLUMN_NAME KEY_SEQ PK_NAME) ] );
    is_deeply( $sth->fetchall_arrayref, [
        [ 'db1', undef, 't1', 'id', 1, undef ],
        [ 'db1', undef, 't1', 'toDate(ts)', 2, undef ],
    ] );
    $dbh->disconnect;
};

subtest 'primary_key_info: a function key part with a comma inside stays one part, not two' => sub {
    my $dbh = connect_ok();
    @queue = ( pk_response( [ [ 'db1', 't1', 'someFunc(a, b), id' ] ] ) );

    my $sth = $dbh->primary_key_info( undef, undef, 't1' );
    is_deeply( $sth->fetchall_arrayref, [
        [ 'db1', undef, 't1', 'someFunc(a, b)', 1, undef ],
        [ 'db1', undef, 't1', 'id', 2, undef ],
    ] );
    $dbh->disconnect;
};

subtest 'primary_key(): DBI\'s generic wrapper returns just the column names in order' => sub {
    my $dbh = connect_ok();
    @queue = ( pk_response( [ [ 'db1', 't1', 'id, ts' ] ] ) );
    my @pk = $dbh->primary_key( undef, undef, 't1' );
    is_deeply( \@pk, [ 'id', 'ts' ] );
    $dbh->disconnect;
};

subtest 'primary_key_info: a table with no ORDER BY/PRIMARY KEY returns no rows' => sub {
    my $dbh = connect_ok();
    @queue = ( pk_response( [] ) );
    my $sth = $dbh->primary_key_info( undef, undef, 't_no_pk' );
    is_deeply( $sth->fetchall_arrayref, [] );
    $dbh->disconnect;
};

subtest 'primary_key_info: a non-empty $schema always returns empty (ClickHouse has no schema level)' => sub {
    my $dbh = connect_ok();
    @query_calls = ();
    my $sth = $dbh->primary_key_info( undef, 'someschema', 't1' );
    is_deeply( $sth->fetchall_arrayref, [] );
    is( scalar( @query_calls ), 0, 'short-circuited before touching the transport' );
    $dbh->disconnect;
};

subtest q{primary_key_info: $catalog = '' matches nothing (every table has a database)} => sub {
    my $dbh = connect_ok();
    @query_calls = ();
    my $sth = $dbh->primary_key_info( '', undef, 't1' );
    is_deeply( $sth->fetchall_arrayref, [] );
    is( scalar( @query_calls ), 0 );
    $dbh->disconnect;
};

subtest 'primary_key_info: $catalog/$table are exact matches, not LIKE patterns' => sub {
    my $dbh = connect_ok();
    @queue = ( pk_response( [] ) );
    $dbh->primary_key_info( 'db1', undef, 't1' );
    my( $sql, $params ) = @{ $query_calls[-1] };
    like( $sql, qr/database = \{p1:String\}/ );
    like( $sql, qr/name = \{p2:String\}/ );
    unlike( $sql, qr/LIKE/ );
    is( $params->{param_p1}, 'db1' );
    is( $params->{param_p2}, 't1' );
    $dbh->disconnect;
};

subtest 'a query failure during primary_key_info is reported via set_err, not silently empty' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 497,
                 headers => { 'x-clickhouse-exception-code' => 497 }, body => 'Not enough privileges' } );
    my $sth = $dbh->primary_key_info( undef, undef, 't1' );
    ok( !defined $sth );
    like( $dbh->errstr, qr/Not enough privileges/ );
    $dbh->disconnect;
};

done_testing;
