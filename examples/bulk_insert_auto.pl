#!/usr/bin/env perl
# Automatic bulk INSERT: bind_param_array / execute_array, the DBI-idiomatic
# way to bulk-load. For a plain INSERT ... VALUES (?, ...) statement, this
# sends the whole batch as one HTTP request without hand-building any SQL
# (contrast with examples/bulk_insert_manual.pl). See "BULK LOADING" in
# `perldoc DBD::ClickhouseNG` for the fast-path shape requirement and the
# chng_retry_on_error option demonstrated below.
#
# Usage: perl examples/bulk_insert_auto.pl dbi:ClickhouseNG:host=localhost [user [password]]

use v5.40;
use DBI;

my( $dsn, $user, $password ) = @ARGV;
die "Usage: $0 <dsn> [user] [password]\n"
    . "Example: $0 dbi:ClickhouseNG:host=localhost;port=8123;database=default myuser mypassword\n"
    unless $dsn;

my $dbh = DBI->connect( $dsn, $user, $password, { RaiseError => 1, AutoCommit => 1 } );

$dbh->do( 'DROP TABLE IF EXISTS dbd_chng_example_array' );
$dbh->do( 'CREATE TABLE dbd_chng_example_array (id UInt32, name String) ENGINE = Memory' );

# One HTTP request for the whole batch, regardless of row count.
my $sth = $dbh->prepare( 'INSERT INTO dbd_chng_example_array (id, name) VALUES (?, ?)' );
$sth->bind_param_array( 1, [ 1 .. 5 ] );
$sth->bind_param_array( 2, [ qw( alice bob carol dave erin ) ] );

my @status;
my $tuples = $sth->execute_array( { ArrayTupleStatus => \@status } );
say "inserted $tuples rows in a single request";

my( $count ) = $dbh->selectrow_array( 'SELECT count(*) FROM dbd_chng_example_array' );
say "count(*) = $count";

# By default, ClickHouse only reports one pass/fail for the whole batch: if
# any row fails, every entry in ArrayTupleStatus gets the same error and
# execute_array returns undef -- no partial commit, no partial diagnosis.
#
# chng_retry_on_error => 1 opts into precise per-row diagnosis: only after a
# definite server-side rejection, it retries once, executing one row at a
# time so each tuple gets its own accurate status (and the good rows still
# get committed).
$dbh->do( 'TRUNCATE TABLE dbd_chng_example_array' );
$sth = $dbh->prepare( 'INSERT INTO dbd_chng_example_array (id, name) VALUES (?, ?)' );
$sth->bind_param_array( 1, [ 1, 2, 'not-a-number' ] );    # id is UInt32
$sth->bind_param_array( 2, [ 'ok1', 'ok2', 'ok3' ] );

@status = ();
{
    local $sth->{RaiseError} = 0;    # this batch is expected to partially fail
    $tuples = $sth->execute_array( { ArrayTupleStatus => \@status, chng_retry_on_error => 1 } );
}
say 'overall result: ', ( defined $tuples ? $tuples : 'undef (one row failed)' );
for my $i ( 0 .. $#status ) {
    if( ref $status[$i] ) {
        say "  row @{[ $i + 1 ]}: failed -- $status[$i][1]";
    }
    else {
        say "  row @{[ $i + 1 ]}: ok";
    }
}

( $count ) = $dbh->selectrow_array( 'SELECT count(*) FROM dbd_chng_example_array' );
say "count(*) = $count (the two good rows were committed individually)";

$dbh->do( 'DROP TABLE dbd_chng_example_array' );
$dbh->disconnect;
