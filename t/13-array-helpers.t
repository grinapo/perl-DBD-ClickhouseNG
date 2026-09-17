use v5.38;
use Test::More;
use DBI qw(:sql_types);

use DBD::ClickhouseNG;

sub literal { DBD::ClickhouseNG::_sql_literal( @_ ) }
sub batchable { DBD::ClickhouseNG::_is_batchable_insert( @_ ) }

subtest '_sql_literal: NULL' => sub {
    is( literal( undef, undef ),         'NULL' );
    is( literal( undef, SQL_INTEGER ),   'NULL' );
    is( literal( undef, SQL_BOOLEAN ),   'NULL' );
};

subtest '_sql_literal: plain numbers pass through bare' => sub {
    is( literal( '42', undef ),    42 );
    is( literal( '-3.14', undef ), '-3.14' );
    is( literal( '1e10', undef ),  '1e10' );
    is( literal( '0', undef ),     0 );
    is( literal( '-0', undef ),    '-0' );
};

subtest '_sql_literal: SQL injection attempts in string values are always quoted, never bare' => sub {
    my @malicious = (
        q{1 OR 1=1},
        q{'; DROP TABLE users; --},
        q{1); DROP TABLE users; --},
        q{\\'; DROP TABLE users; --},
        q{x' UNION SELECT password FROM users --},
        "line1\nDROP TABLE users",
        "tab\ttab",
        "back\\slash",
        "null\0byte",
    );
    for my $v ( @malicious ) {
        my $r = literal( $v, undef );
        like( $r, qr/\A'.*'\z/s, "quoted: " . ( $v =~ s/\n/\\n/gr ) );
        unlike( $r, qr/\A[-0-9.eE]+\z/, "never mistaken for a bare number" );
    }
};

subtest '_sql_literal: numeric-looking-but-dangerous strings are rejected as bare and quoted instead' => sub {
    for my $v ( qw(Inf -Inf NaN inf nan 0x1A +42), ' 42', '42 ', '4_2', '42.', '.42', '1,000' ) {
        my $r = literal( $v, undef );
        is( $r, DBD::ClickhouseNG::_quote_string( $v ), "quoted, not bare: [$v] -> $r" );
    }
};

subtest '_sql_literal: explicit numeric bind type never overrides the strict safety check' => sub {
    for my $type ( SQL_INTEGER, SQL_BIGINT, SQL_FLOAT, SQL_DOUBLE, SQL_DECIMAL, SQL_NUMERIC ) {
        my $r = literal( '1; DROP TABLE users; --', $type );
        is( $r, q{'1; DROP TABLE users; --'}, "type $type does not bypass quoting" );
    }
};

subtest '_sql_literal: SQL_BOOLEAN reduces to a hardcoded 1/0, ignoring the value content entirely' => sub {
    is( literal( "'; DROP TABLE x; --", SQL_BOOLEAN ), '1', 'truthy string -> 1, content never embedded' );
    is( literal( '', SQL_BOOLEAN ), '0' );
    is( literal( '0', SQL_BOOLEAN ), '0', 'the string "0" is Perl-falsy, like the number 0' );
    is( literal( 0, SQL_BOOLEAN ), '0', 'the number 0 is Perl-falsy' );
    is( literal( 1, SQL_BOOLEAN ), '1' );
};

subtest '_sql_literal: unicode and long strings quote safely' => sub {
    my $unicode = "héllo wörld \x{4e2d}\x{6587}";
    is( literal( $unicode, undef ), DBD::ClickhouseNG::_quote_string( $unicode ) );
    my $long = 'x' x 100_000;
    my $r = literal( $long, undef );
    is( length( $r ), 100_000 + 2, 'long string quoted, length preserved plus quotes' );
};

subtest '_sql_literal: hashref/arrayref garbage value never crashes, never bare' => sub {
    my $r = eval { literal( {}, undef ) };
    ok( !$@, 'does not die on a hashref value' ) or diag $@;
    like( $r, qr/\A'.*'\z/s, 'garbage ref stringified and quoted, not embedded bare' );
};

subtest '_is_batchable_insert: canonical shape' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'INSERT INTO t (a,b) VALUES (?, ?)' );
    ok( batchable( $segs, $n ), 'plain VALUES(?, ?) tuple' );
};

subtest '_is_batchable_insert: single placeholder' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'INSERT INTO t (a) VALUES(?)' );
    ok( batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: case-insensitive VALUES, trailing semicolon' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'insert into t values (?, ?);' );
    ok( batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects zero placeholders' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'INSERT INTO t VALUES (1, 2)' );
    ok( !batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects UPDATE-shaped statements' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'UPDATE t SET x = ? WHERE id = ?' );
    ok( !batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects trailing clauses after the tuple' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'INSERT INTO t VALUES (?, ?) SETTINGS async_insert=1' );
    ok( !batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects a second literal tuple after the placeholder tuple' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'INSERT INTO t VALUES (?, ?), (3, 4)' );
    ok( !batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects mixed literal+placeholder inside the tuple' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( q{INSERT INTO t VALUES (1, ?, 'x', ?)} );
    ok( !batchable( $segs, $n ) );
};

subtest '_is_batchable_insert: rejects a function call disguised as VALUES(' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( 'SELECT myvalues(?, ?)' );
    ok( !batchable( $segs, $n ), 'requires the literal word VALUES immediately before the paren' );
};

subtest '_is_batchable_insert: rejects a paren embedded in a quoted default before VALUES' => sub {
    my ( $segs, $n ) = DBD::ClickhouseNG::_scan_placeholders( q{INSERT INTO t (a) VALUES ( ?, ? )} );
    ok( batchable( $segs, $n ), 'whitespace around placeholders inside the tuple is fine' );
};

subtest '_quote_string: escaping' => sub {
    is( DBD::ClickhouseNG::_quote_string( undef ), 'NULL' );
    is( DBD::ClickhouseNG::_quote_string( q{a'b} ), q{'a\\'b'} );
    is( DBD::ClickhouseNG::_quote_string( 'a\\b' ), q{'a\\\\b'} );
    is( DBD::ClickhouseNG::_quote_string( q{'; DROP TABLE x; --} ), q{'\\'; DROP TABLE x; --'} );
};

subtest '_extract_bind_type' => sub {
    is( DBD::ClickhouseNG::_extract_bind_type( undef ), undef );
    is( DBD::ClickhouseNG::_extract_bind_type( SQL_INTEGER ), SQL_INTEGER );
    is( DBD::ClickhouseNG::_extract_bind_type( { TYPE => SQL_VARCHAR } ), SQL_VARCHAR );
    is( DBD::ClickhouseNG::_extract_bind_type( {} ), undef );
};

done_testing;
