use v5.38;
use Test::More;
use DBI qw(:sql_types);
use JSON::PP ();

use DBD::ClickhouseNG;

sub map_type { DBD::ClickhouseNG::_map_ch_type( shift ) }

my @cases = (
    [ 'Int8',    SQL_INTEGER,  undef, undef, 0 ],
    [ 'Int16',   SQL_INTEGER,  undef, undef, 0 ],
    [ 'Int32',   SQL_INTEGER,  undef, undef, 0 ],
    [ 'UInt8',   SQL_INTEGER,  undef, undef, 0 ],
    [ 'UInt16',  SQL_INTEGER,  undef, undef, 0 ],
    [ 'UInt32',  SQL_INTEGER,  undef, undef, 0 ],
    [ 'Int64',   SQL_BIGINT,   undef, undef, 0 ],
    [ 'UInt64',  SQL_BIGINT,   undef, undef, 0 ],
    [ 'Int128',  SQL_BIGINT,   undef, undef, 0 ],
    [ 'UInt128', SQL_BIGINT,   undef, undef, 0 ],
    [ 'Int256',  SQL_BIGINT,   undef, undef, 0 ],
    [ 'UInt256', SQL_BIGINT,   undef, undef, 0 ],
    [ 'Float32', SQL_FLOAT,    undef, undef, 0 ],
    [ 'Float64', SQL_DOUBLE,   undef, undef, 0 ],
    [ 'Decimal(10,2)',   SQL_DECIMAL, 10, 2, 0 ],
    [ 'Decimal32(4)',    SQL_DECIMAL, undef, 4, 0 ],
    [ 'Decimal64(4)',    SQL_DECIMAL, undef, 4, 0 ],
    [ 'Decimal128(4)',   SQL_DECIMAL, undef, 4, 0 ],
    [ 'Decimal256(4)',   SQL_DECIMAL, undef, 4, 0 ],
    [ 'Bool',    SQL_BOOLEAN, undef, undef, 0 ],
    [ 'String',  SQL_VARCHAR, undef, undef, 0 ],
    [ 'FixedString(16)', SQL_VARCHAR, 16, undef, 0 ],
    [ 'Date',    SQL_TYPE_DATE, undef, undef, 0 ],
    [ 'Date32',  SQL_TYPE_DATE, undef, undef, 0 ],
    [ 'DateTime',          SQL_TYPE_TIMESTAMP, undef, undef, 0 ],
    [ "DateTime('UTC')",   SQL_TYPE_TIMESTAMP, undef, undef, 0 ],
    [ 'DateTime64(3)',     SQL_TYPE_TIMESTAMP, undef, undef, 0 ],
    [ "DateTime64(3,'UTC')", SQL_TYPE_TIMESTAMP, undef, undef, 0 ],
    [ "Enum8('a' = 1, 'b' = 2)", SQL_VARCHAR, undef, undef, 0 ],
    [ "Enum16('a' = 1)",         SQL_VARCHAR, undef, undef, 0 ],
    [ 'UUID',    SQL_VARCHAR, undef, undef, 0 ],
    [ 'Array(String)',      SQL_ARRAY, undef, undef, 0 ],
    [ 'Tuple(String, Int8)', SQL_ARRAY, undef, undef, 0 ],
    [ 'Map(String, Int8)',   SQL_ARRAY, undef, undef, 0 ],
    [ 'SomethingWeird',      SQL_VARCHAR, undef, undef, 0 ],
);

for my $c ( @cases ) {
    my( $type, @expect ) = @$c;
    my @got = map_type( $type );
    is_deeply( \@got, \@expect, "map $type" );
}

subtest 'Nullable wrapper' => sub {
    my @got = map_type( 'Nullable(String)' );
    is_deeply( \@got, [ SQL_VARCHAR, undef, undef, 1 ] );
};

subtest 'LowCardinality wrapper is transparent' => sub {
    my @got = map_type( 'LowCardinality(String)' );
    is_deeply( \@got, [ SQL_VARCHAR, undef, undef, 0 ] );
};

subtest 'Nullable(LowCardinality(String))' => sub {
    my @got = map_type( 'Nullable(LowCardinality(String))' );
    is_deeply( \@got, [ SQL_VARCHAR, undef, undef, 1 ] );
};

subtest 'Nullable(Decimal(P,S))' => sub {
    my @got = map_type( 'Nullable(Decimal(18,4))' );
    is_deeply( \@got, [ SQL_DECIMAL, 18, 4, 1 ] );
};

subtest '64-bit lossless conversion boundary values' => sub {
    is( DBD::ClickhouseNG::_coerce_bigint( '9223372036854775807' ),  9223372036854775807, 'IV_MAX' );
    is( DBD::ClickhouseNG::_coerce_bigint( '9223372036854775808' ),  9223372036854775808, 'IV_MAX+1' );
    is( DBD::ClickhouseNG::_coerce_bigint( '18446744073709551615' ), 18446744073709551615, 'UV_MAX' );
    is( DBD::ClickhouseNG::_coerce_bigint( '-9223372036854775808' ), -9223372036854775808, 'IV_MIN' );
    is( DBD::ClickhouseNG::_coerce_bigint( '99999999999999999999999999999' ),
        '99999999999999999999999999999', 'beyond 64-bit falls back to string' );
    is( DBD::ClickhouseNG::_coerce_bigint( undef ), undef, 'undef passes through' );
};

subtest 'Bool coercion' => sub {
    is( DBD::ClickhouseNG::_coerce_bool( 1 ), 1 );
    is( DBD::ClickhouseNG::_coerce_bool( 0 ), 0 );
    is( DBD::ClickhouseNG::_coerce_bool( JSON::PP::true ),  1 );
    is( DBD::ClickhouseNG::_coerce_bool( JSON::PP::false ), 0 );
    is( DBD::ClickhouseNG::_coerce_bool( undef ), undef );
};

subtest 'Bool coercion works for whichever JSON class actually decoded the response' => sub {
    my $json = $DBD::ClickhouseNG::JSON_CLASS->new->utf8->decode( '[true,false]' );
    is( DBD::ClickhouseNG::_coerce_bool( $json->[0] ), 1 );
    is( DBD::ClickhouseNG::_coerce_bool( $json->[1] ), 0 );
};

done_testing;
