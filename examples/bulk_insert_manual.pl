#!/usr/bin/env perl
# Manual bulk INSERT: build one raw multi-row SQL statement by hand and send
# it through a single do() call, instead of looping placeholder execute()
# one row at a time. See "BULK LOADING" in `perldoc DBD::ClickhouseNG` for
# why the loop form doesn't scale on ClickHouse (one MergeTree part per
# INSERT). For the same result without hand-building SQL, see
# examples/bulk_insert_auto.pl (bind_param_array/execute_array).
#
# Usage: perl examples/bulk_insert_manual.pl dbi:ClickhouseNG:host=localhost [user [password]]

use v5.38;
use DBI;

my( $dsn, $user, $password ) = @ARGV;
die "Usage: $0 <dsn> [user] [password]\n"
    . "Example: $0 dbi:ClickhouseNG:host=localhost;port=8123;database=default myuser mypassword\n"
    unless $dsn;

my $dbh = DBI->connect( $dsn, $user, $password, { RaiseError => 1, AutoCommit => 1 } );

$dbh->do( 'DROP TABLE IF EXISTS dbd_chng_example_bulk' );
$dbh->do( 'CREATE TABLE dbd_chng_example_bulk (id UInt32, name String) ENGINE = Memory' );

my @rows = map { [ $_, "row $_" ] } 1 .. 1000;

my $sql = 'INSERT INTO dbd_chng_example_bulk (id, name) VALUES '
    . join( ',', map {
        '(' . join( ',', $_->[0], $dbh->quote( $_->[1] ) ) . ')'
    } @rows );

$dbh->do( $sql );    # one HTTP request for all 1000 rows

my( $count ) = $dbh->selectrow_array( 'SELECT count(*) FROM dbd_chng_example_bulk' );
say "inserted $count rows in a single request";

$dbh->do( 'DROP TABLE dbd_chng_example_bulk' );
$dbh->disconnect;
