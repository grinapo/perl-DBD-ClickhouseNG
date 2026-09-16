use v5.40;
use Test::More;
use DBI;
use JSON::PP;

use DBD::ClickhouseNG;

# get_info, data_sources, ChopBlanks -- mocked the same way as t/20-dbi-glue.t.

my @queue;
my @query_calls;
local *DBD::ClickhouseNG::HTTP::query = sub {
    my( $self, $sql, $params ) = @_;
    push @query_calls, [ $sql, $params ];
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

sub connect_ok {
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    return DBI->connect( 'dbi:ClickhouseNG:host=nowhere;port=8123', 'default', '',
        { RaiseError => 0, PrintError => 0 } );
}

sub jsoncompact {
    my( $meta, $rows ) = @_;
    return JSON::PP->new->utf8->encode( { meta => $meta, data => $rows, rows => scalar @$rows } );
}

subtest 'get_info: curated codes answered' => sub {
    my $dbh = connect_ok();

    is( $dbh->get_info( 6 ), 'DBD::ClickhouseNG', 'SQL_DRIVER_NAME' );
    is( $dbh->get_info( 7 ), $DBD::ClickhouseNG::VERSION, 'SQL_DRIVER_VER' );
    is( $dbh->get_info( 17 ), 'ClickHouse', 'SQL_DBMS_NAME' );
    is( $dbh->get_info( 29 ), '"', 'SQL_IDENTIFIER_QUOTE_CHAR' );
    is( $dbh->get_info( 41 ), '.', 'SQL_CATALOG_NAME_SEPARATOR' );
    is( $dbh->get_info( 42 ), 'database', 'SQL_CATALOG_TERM' );
    is( $dbh->get_info( 46 ), 0, 'SQL_TXN_CAPABLE = SQL_TC_NONE' );
    $dbh->disconnect;
};

subtest 'get_info: SQL_DBMS_VER is queried live and cached' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact( [ { name => 'version()', type => 'String' } ], [ [ '24.8.1.1' ] ] ) } );

    is( $dbh->get_info( 18 ), '24.8.1.1' );
    my $before = scalar @query_calls;
    is( $dbh->get_info( 18 ), '24.8.1.1', 'second call uses the cached value' );
    is( scalar( @query_calls ), $before, 'no extra query on the cached call' );
    $dbh->disconnect;
};

subtest 'get_info: an unimplemented code returns undef, same as DBI\'s default' => sub {
    my $dbh = connect_ok();
    is( $dbh->get_info( 999999 ), undef );
    $dbh->disconnect;
};

subtest 'data_sources: lists databases as full DSNs reusing this handle\'s connection params' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact( [ { name => 'name', type => 'String' } ], [ [ 'default' ], [ 'DBD_dev' ] ] ) } );

    my @ds = $dbh->data_sources;
    is_deeply( \@ds, [
        'dbi:ClickhouseNG:host=nowhere;port=8123;tls=0;database=default',
        'dbi:ClickhouseNG:host=nowhere;port=8123;tls=0;database=DBD_dev',
    ] );
    like( $query_calls[-1][0], qr/\ASHOW DATABASES\z/ );
    $dbh->disconnect;
};

subtest 'data_sources: a query failure yields an empty list, not a die, under RaiseError => 0' => sub {
    my $dbh = connect_ok();
    @queue = ( { ok => 0, status => 500, exception_code => 1, headers => {}, body => 'boom' } );

    is_deeply( [ $dbh->data_sources ], [] );
    $dbh->disconnect;
};

subtest 'drh-level data_sources still returns an empty list' => sub {
    my $drh = DBI->install_driver( 'ClickhouseNG' );
    is_deeply( [ $drh->data_sources ], [] );
};

subtest 'ChopBlanks off (default): FixedString keeps its trailing NUL padding' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'SELECT a FROM t' );
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact( [ { name => 'a', type => 'FixedString(5)' } ], [ [ "ab\0\0\0" ] ] ) } );
    $sth->execute;
    my $row = $sth->fetch;
    is( $row->[0], "ab\0\0\0" );
    $dbh->disconnect;
};

subtest 'ChopBlanks on: trailing NUL padding is stripped from FixedString, not a real trailing space' => sub {
    my $dbh = connect_ok();
    $dbh->{ChopBlanks} = 1;
    my $sth = $dbh->prepare( 'SELECT a, b FROM t' );
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact(
            [ { name => 'a', type => 'FixedString(6)' }, { name => 'b', type => 'String' } ],
            [ [ "ab \0\0\0", "cd \0\0\0" ] ],
        ) } );
    $sth->execute;
    my $row = $sth->fetch;
    is( $row->[0], "ab ", 'trailing NUL bytes stripped, but the real embedded space is content, untouched' );
    is( $row->[1], "cd \0\0\0", 'a plain String column is never chopped, even with ChopBlanks on' );
    $dbh->disconnect;
};

subtest 'ChopBlanks on: Nullable(FixedString(N)) NULL values pass through untouched' => sub {
    my $dbh = connect_ok();
    $dbh->{ChopBlanks} = 1;
    my $sth = $dbh->prepare( 'SELECT a FROM t' );
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact( [ { name => 'a', type => 'Nullable(FixedString(5))' } ], [ [ undef ] ] ) } );
    $sth->execute;
    my $row = $sth->fetch;
    is( $row->[0], undef );
    $dbh->disconnect;
};

subtest 'ChopBlanks set directly on the sth (not inherited from dbh) still takes effect at execute' => sub {
    my $dbh = connect_ok();
    my $sth = $dbh->prepare( 'SELECT a FROM t' );
    $sth->{ChopBlanks} = 1;
    @queue = ( { ok => 1, status => 200, headers => {},
        body => jsoncompact( [ { name => 'a', type => 'FixedString(4)' } ], [ [ "hi\0\0" ] ] ) } );
    $sth->execute;
    my $row = $sth->fetch;
    is( $row->[0], 'hi' );
    $dbh->disconnect;
};

done_testing;
