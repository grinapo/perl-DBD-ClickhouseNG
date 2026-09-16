use v5.40;
use Test::More;

use DBD::ClickhouseNG;

sub scan { DBD::ClickhouseNG::_scan_placeholders( shift ) }

subtest 'plain placeholders' => sub {
    my( $segs, $n ) = scan( 'SELECT * FROM t WHERE a = ? AND b = ?' );
    is( $n, 2 );
    is( scalar @$segs, 3 );
    is( join( '?', @$segs ), 'SELECT * FROM t WHERE a = ? AND b = ?' );
};

subtest 'zero placeholders' => sub {
    my( $segs, $n ) = scan( 'SELECT 1' );
    is( $n, 0 );
    is_deeply( $segs, ['SELECT 1'] );
};

subtest 'adjacent placeholders (separated)' => sub {
    my( $segs, $n ) = scan( 'SELECT ?,?' );
    is( $n, 2 );
    is_deeply( $segs, [ 'SELECT ', ',', '' ] );
};

subtest '?? escapes a literal ? (ternary), uncounted' => sub {
    my( $segs, $n ) = scan( 'SELECT 1 ?? 7 : 8' );
    is( $n, 0 );
    is_deeply( $segs, ['SELECT 1 ? 7 : 8'] );
};

subtest '?? mixed with a real placeholder' => sub {
    my( $segs, $n ) = scan( 'SELECT ? ?? 1 : 0' );
    is( $n, 1 );
    is_deeply( $segs, [ 'SELECT ', ' ? 1 : 0' ] );
};

subtest 'single-quoted string hides ?' => sub {
    my( $segs, $n ) = scan( q{SELECT '?' FROM t WHERE a = ?} );
    is( $n, 1 );
    is( $segs->[0], q{SELECT '?' FROM t WHERE a = } );
};

subtest 'double-quoted identifier hides ?' => sub {
    my( $segs, $n ) = scan( q{SELECT "col?name" FROM t WHERE a = ?} );
    is( $n, 1 );
    is( $segs->[0], q{SELECT "col?name" FROM t WHERE a = } );
};

subtest 'backtick identifier hides ?' => sub {
    my( $segs, $n ) = scan( q{SELECT `col?name` FROM t WHERE a = ?} );
    is( $n, 1 );
    is( $segs->[0], q{SELECT `col?name` FROM t WHERE a = } );
};

subtest 'line comment -- hides ?' => sub {
    my( $segs, $n ) = scan( "SELECT 1 -- what about ?\nWHERE a = ?" );
    is( $n, 1 );
};

subtest 'line comment # hides ?' => sub {
    my( $segs, $n ) = scan( "SELECT 1 # what about ?\nWHERE a = ?" );
    is( $n, 1 );
};

subtest 'block comment hides ?' => sub {
    my( $segs, $n ) = scan( "SELECT 1 /* what about ? */ WHERE a = ?" );
    is( $n, 1 );
};

subtest 'unterminated block comment extends to EOF, no error' => sub {
    my( $segs, $n ) = scan( "SELECT 1 /* unterminated ? " );
    is( $n, 0 );
};

subtest 'escaped quote inside string (backslash)' => sub {
    my( $segs, $n ) = scan( q{SELECT 'it\'s ?' WHERE a = ?} );
    is( $n, 1 );
};

subtest 'doubled quote inside string' => sub {
    my( $segs, $n ) = scan( q{SELECT 'it''s ?' WHERE a = ?} );
    is( $n, 1 );
};

subtest 'unterminated single-quoted string dies' => sub {
    eval { scan( q{SELECT ? FROM t WHERE a = 'x} ) };
    like( $@, qr/unterminated quote in statement/ );
};

subtest 'unterminated double-quoted identifier dies' => sub {
    eval { scan( q{SELECT ? FROM t WHERE a = "x} ) };
    like( $@, qr/unterminated quote in statement/ );
};

subtest 'unterminated backtick identifier dies' => sub {
    eval { scan( q{SELECT ? FROM t WHERE a = `x} ) };
    like( $@, qr/unterminated quote in statement/ );
};

subtest 'utf-8 SQL text passes through' => sub {
    my( $segs, $n ) = scan( "SELECT 'héllo wörld' WHERE a = ?" );
    is( $n, 1 );
    like( $segs->[0], qr/héllo wörld/ );
};

subtest 'dollar-quoted string ($$...$$) hides ?' => sub {
    my( $segs, $n ) = scan( q{SELECT $$a?b$$ WHERE a = ?} );
    is( $n, 1 );
    is( $segs->[0], q{SELECT $$a?b$$ WHERE a = } );
};

subtest 'tagged dollar-quoted string ($tag$...$tag$) hides ? and quotes' => sub {
    my( $segs, $n ) = scan( q{SELECT $tag$it's a ?$tag$ WHERE a = ?} );
    is( $n, 1 );
    is( $segs->[0], q{SELECT $tag$it's a ?$tag$ WHERE a = } );
};

subtest 'unterminated dollar-quoted string dies' => sub {
    eval { scan( q{SELECT ? FROM t WHERE a = $tag$x} ) };
    like( $@, qr/unterminated quote in statement/ );
};

subtest 'bare $ that is not a dollar-quote pair passes through literally' => sub {
    my( $segs, $n ) = scan( q{SELECT price, ? WHERE a = $1} );
    is( $n, 1 );
    is( $segs->[1], q{ WHERE a = $1} );
};

done_testing;
