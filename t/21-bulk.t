use v5.38;
use Test::More;
use DBI;

use DBD::ClickhouseNG;

# §12.4: placeholder execute() is one HTTP round-trip per row -- this test
# proves the shape of the problem, not just states it in prose.

my @queue;
my $query_calls = 0;
local *DBD::ClickhouseNG::HTTP::query = sub {
    $query_calls++;
    return @queue ? shift @queue : { ok => 1, status => 200, body => '', headers => {} };
};

push @queue, { ok => 1, status => 200, body => '', headers => {} };
my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=nowhere', '', '', { RaiseError => 1, PrintError => 0 } );
$query_calls = 0;

subtest 'one execute() call triggers exactly one query() call' => sub {
    my $sth = $dbh->prepare( 'INSERT INTO t VALUES (?)' );
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    $sth->execute( 1 );
    is( $query_calls, 1 );
};

subtest 'a loop of N execute() calls triggers N query() calls' => sub {
    $query_calls = 0;
    my $sth = $dbh->prepare( 'INSERT INTO t VALUES (?)' );
    my $n = 5;
    for my $i ( 1 .. $n ) {
        push @queue, { ok => 1, status => 200, body => '', headers => {} };
        $sth->execute( $i );
    }
    is( $query_calls, $n, 'N rows via looped execute() cost N HTTP round-trips -- not the bulk path' );
};

subtest 'a single do() with a multi-row raw-SQL statement is exactly one query() call' => sub {
    $query_calls = 0;
    push @queue, { ok => 1, status => 200, body => '', headers => {} };
    $dbh->do( 'INSERT INTO t VALUES ' . join( ',', map { "($_)" } 1 .. 100 ) );
    is( $query_calls, 1, '100 rows via raw multi-row SQL costs exactly one HTTP round-trip' );
};

$dbh->disconnect;
done_testing;
