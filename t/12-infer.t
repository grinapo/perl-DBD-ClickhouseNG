use v5.38;
use Test::More;
use DBI qw(:sql_types);

use DBD::ClickhouseNG;

sub infer  { DBD::ClickhouseNG::_infer_ch_type( @_ ) }
sub encode { DBD::ClickhouseNG::_encode_param( @_ ) }

subtest 'no explicit type: undef' => sub {
    is( infer( undef, undef ), 'Nullable(String)' );
};

subtest 'no explicit type: integer-looking string' => sub {
    is( infer( '42', undef ), 'Int64' );
    is( infer( -7, undef ), 'Int64' );
};

subtest 'no explicit type: float-looking value' => sub {
    is( infer( '3.14', undef ), 'Float64' );
    is( infer( '1e10', undef ), 'Float64' );
};

subtest 'no explicit type: non-numeric string' => sub {
    is( infer( 'hello', undef ), 'String' );
};

subtest 'explicit bind_param type overrides inference' => sub {
    is( infer( '42', SQL_VARCHAR ), 'String' );
    is( infer( 'x',  SQL_INTEGER ), 'Int64' );
    is( infer( 1,    SQL_BOOLEAN ), 'Bool' );
    is( infer( '2026-07-19', SQL_TYPE_DATE ), 'Date' );
    is( infer( '2026-07-19 00:00:00', SQL_TYPE_TIMESTAMP ), 'DateTime' );
};

subtest 'explicit type + undef value -> Nullable(T)' => sub {
    is( infer( undef, SQL_INTEGER ), 'Nullable(Int64)' );
    is( infer( undef, SQL_VARCHAR ), 'Nullable(String)' );
};

subtest 'unrecognized explicit type falls back to String' => sub {
    is( infer( 'x', 9999 ), 'String' );
};

subtest '_encode_param NULL' => sub {
    is( encode( undef, 'String' ), '\N' );
    is( encode( undef, 'Int64' ), '\N' );
};

subtest '_encode_param TSV escaping for strings' => sub {
    is( encode( "a\\b", 'String' ), 'a\\\\b' );
    is( encode( "a\tb", 'String' ), 'a\\tb' );
    is( encode( "a\nb", 'String' ), 'a\\nb' );
    is( encode( "a\rb", 'String' ), 'a\\rb' );
    is( encode( "x\ty", 'String' ), 'x\\ty' );
};

subtest '_encode_param passes numeric/date/bool types through untouched' => sub {
    is( encode( 42, 'Int64' ), 42 );
    is( encode( '3.14', 'Float64' ), '3.14' );
    is( encode( 1, 'Bool' ), 1 );
    is( encode( '2026-07-19', 'Date' ), '2026-07-19' );
    is( encode( '2026-07-19 00:00:00', 'DateTime' ), '2026-07-19 00:00:00' );
};

subtest '_encode_param strips Nullable() wrapper to decide encoding' => sub {
    is( encode( 42, 'Nullable(Int64)' ), 42 );
    is( encode( "a\tb", 'Nullable(String)' ), 'a\\tb' );
};

done_testing;
