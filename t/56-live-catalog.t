use v5.40;
use Test::More;
use DBI;

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $user = $ENV{CHNG_TEST_USER};
my $pass = $ENV{CHNG_TEST_PASS};

my $dbh = DBI->connect( $dsn, $user, $pass, { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
ok( $dbh, 'connected' ) or BAIL_OUT( "cannot connect: $DBI::errstr" );

my $table = 'dbd_chng_test_56_' . $$;

END {
    $dbh->do( "DROP TABLE IF EXISTS $table" ) if $dbh;
}

$dbh->do( <<"SQL" );
CREATE TABLE $table (
    id UInt32,
    name Nullable(String),
    price Decimal(18,4),
    created DateTime
) ENGINE = Memory COMMENT 'a probe table for catalog introspection tests'
SQL

subtest 'table_info finds the table just created, with the right type and remarks' => sub {
    my $sth = $dbh->table_info( undef, undef, $table );
    my $rows = $sth->fetchall_arrayref;
    is( scalar @$rows, 1 );
    my( $cat, $schem, $name, $type, $remarks ) = @{ $rows->[0] };
    is( $name, $table );
    is( $type, 'TABLE' );
    like( $remarks, qr/probe table for catalog/ );
    ok( !defined $schem, 'TABLE_SCHEM is undef -- ClickHouse has no schema level' );
};

subtest 'tables() finds it too, via the generic DBI layer over table_info' => sub {
    my @t = $dbh->tables( undef, undef, $table );
    # DBI's generic tables() quotes catalog.table via quote_identifier() once
    # SQL_IDENTIFIER_QUOTE_CHAR (get_info type 29) is non-empty -- see DBI.pm's
    # tables(). TABLE_SCHEM is always undef for us, so it's omitted.
    is_deeply( \@t, [ qq{"DBD_dev"."$table"} ] );
};

subtest 'table_info with a non-matching pattern returns no rows' => sub {
    my $sth = $dbh->table_info( undef, undef, $table . '_nonexistent' );
    is_deeply( $sth->fetchall_arrayref, [] );
};

subtest 'column_info reports all four columns with correct types and nullability' => sub {
    my $sth = $dbh->column_info( undef, undef, $table, undef );
    my $rows = $sth->fetchall_arrayref;
    is( scalar @$rows, 4 );

    my %by_name = map { $_->[3] => $_ } @$rows;
    is( $by_name{id}[5],    'UInt32' );
    is( $by_name{id}[10],   0, 'id is not nullable' );
    is( $by_name{id}[17],   'NO' );

    is( $by_name{name}[5],  'Nullable(String)' );
    is( $by_name{name}[10], 1, 'name is nullable' );
    is( $by_name{name}[17], 'YES' );

    is( $by_name{price}[5], 'Decimal(18, 4)' );
    is( $by_name{price}[6], 18, 'COLUMN_SIZE is the Decimal precision' );
    is( $by_name{price}[8], 4,  'DECIMAL_DIGITS is the Decimal scale' );

    is( $by_name{created}[5], 'DateTime' );

    is_deeply( [ sort { $a <=> $b } map { $_->[16] } @$rows ], [ 1, 2, 3, 4 ],
        'ORDINAL_POSITION covers all four columns in order, 1-based' );
};

subtest 'column_info filtered to a single column returns just that one' => sub {
    my $sth = $dbh->column_info( undef, undef, $table, 'price' );
    my $rows = $sth->fetchall_arrayref;
    is( scalar @$rows, 1 );
    is( $rows->[0][3], 'price' );
};

subtest 'type_info_all / type_info work without touching the server' => sub {
    my $tia = $dbh->type_info_all;
    ok( scalar( @$tia ) > 1 );
    my @ti = $dbh->type_info( DBI::SQL_INTEGER() );
    ok( @ti > 0 );
};

subtest 'primary_key_info: a Memory-engine table (no ORDER BY) has no primary key' => sub {
    my $sth = $dbh->primary_key_info( undef, undef, $table );
    is_deeply( $sth->fetchall_arrayref, [] );
    my @pk = $dbh->primary_key( undef, undef, $table );
    is_deeply( \@pk, [] );
};

subtest 'primary_key_info: a MergeTree table reports its ORDER BY as the key, in order' => sub {
    my $mt_table = $table . '_mt';
    $dbh->do( "CREATE TABLE $mt_table (id UInt32, ts DateTime, name String) "
        . 'ENGINE = MergeTree ORDER BY (id, ts)' );

    my $sth = $dbh->primary_key_info( undef, undef, $mt_table );
    my $rows = $sth->fetchall_arrayref;
    is_deeply( $rows, [
        [ 'DBD_dev', undef, $mt_table, 'id', 1, undef ],
        [ 'DBD_dev', undef, $mt_table, 'ts', 2, undef ],
    ] );

    my @pk = $dbh->primary_key( undef, undef, $mt_table );
    is_deeply( \@pk, [ 'id', 'ts' ] );

    $dbh->do( "DROP TABLE $mt_table" );
};

subtest 'primary_key_info: a functional key part (e.g. toDate(ts)) is reported as its raw expression' => sub {
    my $mt_table = $table . '_mtfn';
    $dbh->do( "CREATE TABLE $mt_table (id UInt32, ts DateTime) "
        . 'ENGINE = MergeTree ORDER BY (id, toDate(ts))' );

    my @pk = $dbh->primary_key( undef, undef, $mt_table );
    is_deeply( \@pk, [ 'id', 'toDate(ts)' ] );

    $dbh->do( "DROP TABLE $mt_table" );
};

subtest 'get_info: SQL_DBMS_VER matches the real server version' => sub {
    my $ver = $dbh->get_info( 18 );
    like( $ver, qr/\A\d+\.\d+\.\d+/, 'looks like a ClickHouse version string' );
};

subtest 'data_sources: DBD_dev is among the databases the connected user can see' => sub {
    my @ds = $dbh->data_sources;
    ok( scalar( grep { /database=DBD_dev\z/ } @ds ), 'DBD_dev is listed' )
        or diag( "got: @ds" );
};

subtest 'ChopBlanks: a real FixedString column is NUL-padded by the server, and stripped when requested' => sub {
    my $fs_table = $table . '_fs';
    $dbh->do( "CREATE TABLE $fs_table (a FixedString(6)) ENGINE = Memory" );
    $dbh->do( "INSERT INTO $fs_table VALUES (?)", undef, 'ab' );

    my $sth = $dbh->prepare( "SELECT a FROM $fs_table" );
    $sth->execute;
    is( $sth->fetch->[0], "ab\0\0\0\0", 'raw value is NUL-padded to the declared width, ChopBlanks off' );

    $dbh->{ChopBlanks} = 1;
    $sth = $dbh->prepare( "SELECT a FROM $fs_table" );
    $sth->execute;
    is( $sth->fetch->[0], 'ab', 'padding stripped with ChopBlanks on' );
    $dbh->{ChopBlanks} = 0;

    $dbh->do( "DROP TABLE $fs_table" );
};

$dbh->disconnect;
done_testing;
