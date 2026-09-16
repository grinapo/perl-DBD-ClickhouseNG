use v5.40;
use Test::More;
use DBI qw(:sql_types);

my $dsn = $ENV{CHNG_TEST_DSN};
plan skip_all => 'set CHNG_TEST_DSN to run live integration tests'
    unless $dsn;

my $dbh = DBI->connect( $dsn, $ENV{CHNG_TEST_USER}, $ENV{CHNG_TEST_PASS},
    { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );

my $table = 'dbd_chng_test_51_' . $$;

END {
    $dbh->do( "DROP TABLE IF EXISTS $table" ) if $dbh;
}

$dbh->do( <<"SQL" );
CREATE TABLE $table (
    c_int8    Int8,
    c_int64   Int64,
    c_uint64  UInt64,
    c_float64 Float64,
    c_decimal Decimal(10,2),
    c_bool    Bool,
    c_string  String,
    c_fixed   FixedString(8),
    c_date    Date,
    c_dt      DateTime,
    c_nullstr Nullable(String)
) ENGINE = Memory
SQL

subtest 'insert via placeholders, select back, compare values and metadata' => sub {
    my $ins = $dbh->prepare( "INSERT INTO $table VALUES (?,?,?,?,?,?,?,?,?,?,?)" );
    $ins->bind_param( 5, '123.45', SQL_DECIMAL );
    $ins->bind_param( 9, '2026-07-19', SQL_TYPE_DATE );
    $ins->bind_param( 10, '2026-07-19 12:34:56', SQL_TYPE_TIMESTAMP );
    ok( $ins->execute( -5, -12345, 12345, 3.5, '123.45', 1, 'hello', 'abcdefgh',
        '2026-07-19', '2026-07-19 12:34:56', 'notnull' ) );

    my $sel = $dbh->prepare( "SELECT * FROM $table" );
    $sel->execute;
    is_deeply( $sel->{NAME}, [ qw(c_int8 c_int64 c_uint64 c_float64 c_decimal c_bool
        c_string c_fixed c_date c_dt c_nullstr) ] );
    is( $sel->{TYPE}[0], SQL_INTEGER );
    is( $sel->{TYPE}[1], SQL_BIGINT );
    is( $sel->{TYPE}[2], SQL_BIGINT );
    is( $sel->{TYPE}[6], SQL_VARCHAR );
    is( $sel->{TYPE}[8], SQL_TYPE_DATE );
    is( $sel->{TYPE}[9], SQL_TYPE_TIMESTAMP );
    ok( $sel->{NULLABLE}[10], 'c_nullstr is nullable' );

    my $row = $sel->fetch;
    is( $row->[0], -5 );
    is( $row->[1], -12345 );
    is( $row->[2], 12345 );
    is( $row->[6], 'hello' );
    is( $row->[8], '2026-07-19' );
    is( $row->[10], 'notnull' );
};

subtest 'NULL round-trip through Nullable(String) (\\N encoding)' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my $ins = $dbh->prepare( "INSERT INTO $table VALUES (?,?,?,?,?,?,?,?,?,?,?)" );
    $ins->bind_param( 11, undef, SQL_VARCHAR );
    $ins->execute( 1, 1, 1, 1.0, '0.00', 0, 'x', 'abcdefgh', '2026-01-01', '2026-01-01 00:00:00', undef );

    my $row = $dbh->selectrow_arrayref( "SELECT c_nullstr FROM $table" );
    ok( !defined $row->[0], 'NULL round-tripped as undef' );
};

subtest 'TSV-escaping round-trip: tab, newline, backslash, quotes, UTF-8' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my $tricky = "a\tb\nc\\d'e\"f`g h\x{e9}llo";
    my $ins = $dbh->prepare( "INSERT INTO $table VALUES (?,?,?,?,?,?,?,?,?,?,?)" );
    $ins->execute( 1, 1, 1, 1.0, '0.00', 0, $tricky, 'abcdefgh',
        '2026-01-01', '2026-01-01 00:00:00', undef );

    my $row = $dbh->selectrow_arrayref( "SELECT c_string FROM $table" );
    is( $row->[0], $tricky, 'special characters and UTF-8 survive the round trip' );
};

subtest '64-bit boundary values' => sub {
    $dbh->do( "TRUNCATE TABLE $table" );
    my @boundaries = ( 9223372036854775807, -9223372036854775808 );
    for my $v ( @boundaries ) {
        $dbh->do( "TRUNCATE TABLE $table" );
        my $ins = $dbh->prepare( "INSERT INTO $table VALUES (?,?,?,?,?,?,?,?,?,?,?)" );
        $ins->bind_param( 2, "$v", SQL_BIGINT );
        $ins->execute( 1, "$v", 1, 1.0, '0.00', 0, 'x', 'abcdefgh',
            '2026-01-01', '2026-01-01 00:00:00', undef );
        my $row = $dbh->selectrow_arrayref( "SELECT c_int64 FROM $table" );
        is( $row->[0], $v, "Int64 boundary $v round-trips" );
    }

    $dbh->do( "TRUNCATE TABLE $table" );
    my $ins = $dbh->prepare( "INSERT INTO $table VALUES (?,?,?,?,?,?,?,?,?,?,?)" );
    $ins->bind_param( 3, '18446744073709551615', SQL_BIGINT );
    $ins->execute( 1, 1, '18446744073709551615', 1.0, '0.00', 0, 'x', 'abcdefgh',
        '2026-01-01', '2026-01-01 00:00:00', undef );
    my $row = $dbh->selectrow_arrayref( "SELECT c_uint64 FROM $table" );
    is( $row->[0], 18446744073709551615, 'UInt64 max round-trips' );
};

done_testing;
