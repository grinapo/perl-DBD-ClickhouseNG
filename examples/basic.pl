#!/usr/bin/env perl
# Basic connect / DDL / parameterized query / fetch loop.
#
# Usage: perl examples/basic.pl dbi:ClickhouseNG:host=localhost [user [password]]

use v5.40;
use DBI;

my( $dsn, $user, $password ) = @ARGV;
die "Usage: $0 <dsn> [user] [password]\n"
    . "Example: $0 dbi:ClickhouseNG:host=localhost;port=8123;database=default myuser mypassword\n"
    unless $dsn;

my $dbh = DBI->connect( $dsn, $user, $password, { RaiseError => 1, AutoCommit => 1 } );

$dbh->do( 'DROP TABLE IF EXISTS dbd_chng_example_basic' );
$dbh->do( 'CREATE TABLE dbd_chng_example_basic (id UInt32, name String) ENGINE = Memory' );

my $ins = $dbh->prepare( 'INSERT INTO dbd_chng_example_basic (id, name) VALUES (?, ?)' );
$ins->execute( 1, 'alice' );
$ins->execute( 2, 'bob' );

my $sth = $dbh->prepare( 'SELECT id, name FROM dbd_chng_example_basic WHERE id >= ? ORDER BY id' );
$sth->execute( 1 );

say join( "\t", @{ $sth->{NAME} } );
while( my $row = $sth->fetchrow_arrayref ) {
    say join( "\t", @$row );
}

$dbh->do( 'DROP TABLE dbd_chng_example_basic' );
$dbh->disconnect;
