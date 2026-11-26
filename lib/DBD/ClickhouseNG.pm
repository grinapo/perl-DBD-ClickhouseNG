package DBD::ClickhouseNG;

use v5.40;
use DBI ();

use DBD::ClickhouseNG::dr;
use DBD::ClickhouseNG::db;
use DBD::ClickhouseNG::st;

our $VERSION = '0.5204';
our $drh;

# Cpanel::JSON::XS is a drop-in-compatible, actively-maintained XS
# accelerator for the same ->new->utf8->decode API JSON::PP provides;
# prefer it when installed, but never require it -- JSON::PP is core and
# always available as the correctness baseline.
our $JSON_CLASS = eval { require Cpanel::JSON::XS; 'Cpanel::JSON::XS' }
    // do { require JSON::PP; 'JSON::PP' };

sub driver( $class, $attr = undef ) {
    return $drh if $drh;
    $class .= '::dr';
    ( $drh ) = DBI::_new_drh( $class, {
        Name        => 'ClickhouseNG',
        Version     => $VERSION,
        Attribution => 'DBD::ClickhouseNG',
    } );
    return $drh;
}

sub CLONE {
    undef $drh;
}

1;

__END__

=head1 NAME

DBD::ClickhouseNG - DBI driver for ClickHouse over its HTTP interface

=head1 SYNOPSIS

    use DBI;

    my $dbh = DBI->connect(
        'dbi:ClickhouseNG:host=db1;port=8123;database=default;tls=0;timeout=30',
        $user, $password,
        { RaiseError => 1, AutoCommit => 1 },
    );

    my $sth = $dbh->prepare( 'SELECT id, name FROM users WHERE id = ?' );
    $sth->execute( 42 );
    while( my $row = $sth->fetchrow_arrayref ) {
        ...
    }

    $dbh->do( 'INSERT INTO users (id, name) VALUES (?, ?)', undef, 1, 'alice' );

=head1 DESCRIPTION

C<DBD::ClickhouseNG> is a DBI driver for ClickHouse's HTTP interface. It is a
minimal, DBI-compliant reimplementation of the ideas behind the old
C<DBD::Clickhouse> distribution.

The driver name is C<ClickhouseNG>, not C<Clickhouse::NG>: DBI parses the
driver name out of a DSN with a C<\w+> match, so a driver name cannot contain
C<::>.

=head1 DSN

    dbi:ClickhouseNG:host=db1;port=8123;database=default;tls=0;timeout=30

Recognized keys (unknown keys make C<connect> fail):

=over 4

=item host

Default C<localhost>. Must not be empty, and must not contain C</> or
whitespace. For an IPv6 literal, supply your own brackets (e.g.
C<host=[::1]>) -- the driver passes C<host> through into the URL unchanged.

=item port

Default C<8123>, or C<8443> if C<tls=1>. Must be a positive integer if given.

=item database

Default C<default>.

=item tls

C<0> (default) for HTTP, C<1> for HTTPS. No other value is accepted (e.g.
C<tls=false> is rejected rather than silently treated as true).

=item tls_insecure

C<0> (default) or C<1>; requires C<tls=1> (an error otherwise). C<1>
disables both certificate and hostname verification on the TLS connection
-- for a self-signed or otherwise unverifiable certificate in a dev/test
environment. Explicitly turns verification off (C<HTTP::Tiny>'s
C<verify_SSL => 0>, C<Net::HTTPS>'s C<SSL_verify_mode => SSL_VERIFY_NONE>)
rather than merely omitting it, so behavior doesn't depend on library
defaults. B<Security note:> this accepts any certificate, including an
expired, self-signed, or actively substituted one -- only use it against a
server and network you trust, e.g. a local/private development instance.

=item tls_cert_file, tls_key_file

Paths to a PEM client certificate and its private key, for mutual TLS (the
server authenticates the user from the certificate, e.g. via C<ssl_certificates>
in its user configuration). Both must be given together and require C<tls=1>;
the files must be readable at connect time. Passed as C<SSL_cert_file> /
C<SSL_key_file> (C<HTTP::Tiny> C<SSL_options> on the buffered path,
C<Net::HTTPS> constructor options on the streaming path). The key must not be
passphrase-protected. With a client certificate the driver also sends
C<X-ClickHouse-SSL-Certificate-Auth: on>, which makes ClickHouse authenticate
the user from the certificate (the server needs a user with
C<ssl_certificates> and an C<openSSL.server> config that requests client
certificates, i.e. C<verificationMode> other than C<none>, with C<caConfig>
set to the issuing CA). Pass the ClickHouse user name as C<$user> and an empty
password; the password header is then omitted. The C<default> user sends no
user header.

=item tls_ca_file

Path to a PEM CA bundle used to verify the server certificate instead of the
system store (C<SSL_ca_file>). Requires C<tls=1>.

=item timeout

Seconds, default C<30>. Must be a positive number if given.

=item fetch_batch_rows

Undefined (off) by default. If set, must be a positive integer; turns on
bounded-batch streaming fetch for every statement on this connection (see
L</STREAMING LARGE RESULT SETS>). Overridable per statement via
C<< $sth->{chng_fetch_batch_rows} >>.

=back

Any of the above failing validation makes C<connect> fail with a driver-detected
usage error (see L</ERROR HANDLING>) rather than a confusing later transport
failure.

Username and password are passed as the normal 2nd/3rd arguments to
C<DBI-E<gt>connect>, not as DSN keys. An undefined username defaults to
C<default>; an undefined password defaults to the empty string. Both are sent
as HTTP header values (C<X-ClickHouse-User> / C<X-ClickHouse-Key>); a value
containing a CR or LF is rejected by the underlying HTTP client rather than
risking header injection. With a client certificate (see
L</Mutual TLS (client certificate)>) the password header is omitted when the
password is empty.

=head2 Mutual TLS (client certificate)

Authenticate with an X.509 client certificate instead of a password:

    my $dbh = DBI->connect(
        'dbi:ClickhouseNG:host=ch.example.com;tls=1;database=default'
          . ';tls_ca_file=/etc/ssl/certs/local-ca.crt'
          . ';tls_cert_file=/etc/ssl/private/perl-worker-01.crt'
          . ';tls_key_file=/etc/ssl/private/perl-worker-01.key',
        'perl_service',    # the ClickHouse user bound to the certificate
        '',                # no password
        { RaiseError => 1 },
    );

C<tls_ca_file> is only needed when the server certificate is not signed by a
CA in the system store. The server side must have a user identified by the
certificate and must request client certificates; for example:

    <!-- users.xml -->
    <perl_service>
        <ssl_certificates>
            <common_name>perl-worker-01</common_name>
        </ssl_certificates>
    </perl_service>

    <!-- config.d/ssl.xml -->
    <openSSL><server>
        <verificationMode>relaxed</verificationMode>  <!-- not 'none' -->
        <caConfig>/etc/clickhouse-server/keys/ca.crt</caConfig>
    </server></openSSL>

If the server never asks for a certificate (C<verificationMode> C<none>), the
connection fails with I<SSL certificate authentication requires nonempty
certificate's Common Name or Subject Alternative Name>.

=head1 SUPPORTED METHODS

C<connect>, C<prepare>, C<do>, C<ping>, C<disconnect>, C<commit>,
C<rollback>, C<quote>, C<bind_param>, C<execute>, C<bind_param_array>,
C<execute_array>, C<fetch> / C<fetchrow_arrayref> (and everything DBI derives
from it: C<fetchrow_array>, C<fetchrow_hashref>, C<fetchall_arrayref>,
C<selectall_arrayref>, etc.), C<rows>, C<finish>, C<table_info>,
C<column_info>, C<type_info_all>, C<primary_key_info> (and
C<tables>/C<type_info>/C<primary_key>, which DBI derives from those),
C<get_info>, C<data_sources>.

ClickHouse has no transactions: C<AutoCommit> can never be disabled (attempting
to do so croaks), and C<commit>/C<rollback> are no-ops that warn when C<Warn>
is set, per the DBI convention for non-transactional drivers.

C<foreign_key_info> and C<statistics_info> are not applicable; DBI's
defaults apply, since ClickHouse has no foreign-key concept and no directly
analogous index-statistics model to report. See L</CATALOG METHODS> for
C<table_info>/C<column_info>/C<type_info_all>/C<primary_key_info>. Column
C<NAME>/C<TYPE> metadata for an ordinary query result comes from the
result set's own metadata (unrelated to the catalog methods).

A driver-private attribute, C<< $sth->{chng_ch_types} >>, exposes the raw
ClickHouse type strings (e.g. C<Nullable(String)>) for each result column,
alongside the standard DBI C<TYPE>/C<PRECISION>/C<SCALE>/C<NULLABLE>.

=head1 PLACEHOLDERS AND PARAMETER BINDING

ClickHouse has no native positional C<?> placeholder; it has typed named
query parameters (C<{name:Type}> passed as C<param_name=value>). This driver
translates DBI's C<?> convention into that form transparently: the type is
inferred from the bound Perl value, or taken from an explicit
C<bind_param($n, $value, $sql_type)> call.

Only one row of placeholder values is sent per C<execute()> call -- one HTTP
round-trip each. See L</BULK LOADING> below for why this is unsuitable for
loading large amounts of data, and what to use instead.

Native C<{name:Type}> parameters written directly in SQL pass through
untouched, but this driver provides no way to bind their values from Perl;
use C<?> placeholders instead.

C<execute()> and C<execute_array()> both require every declared placeholder to
have been bound (via C<bind_param>/C<bind_param_array>, or positionally via
C<execute(@bind_values)>/the array-bind C<@bind_values> form) -- a statement
with an unbound placeholder is a driver-detected usage error, not silently
sent as C<NULL>.

=head2 Literal C<?> in SQL text (ternary, JSON operators, etc.)

ClickHouse's ternary operator (C<cond ? a : b>) uses a bare C<?>, which is
indistinguishable from a DBI placeholder by lexical scanning alone. Write
C<??> to get one literal, uncounted C<?> in the statement actually sent to
the server:

    $dbh->prepare( 'SELECT x ?? 7 : 8' );   # sent to ClickHouse as: SELECT x ? 7 : 8

C<??> is only recognized outside quoted/comment/dollar-quoted regions, same
as C<?> itself.

=head2 Dollar-quoted strings

ClickHouse heredoc-style string literals (C<$tag$...$tag$>, C<$tag> any
run of word characters or empty, e.g. C<$$...$$>) are recognized by the
placeholder scanner the same way C<'>/C<">/C<`> quoting is: their contents
pass through verbatim, so a C<?> or an unbalanced quote character inside one
is not misread. An opening C<$tag$> with no matching closing C<$tag$> is a
driver-detected "unterminated quote" error, same as an unterminated C<'>/C<">/C<`>.

=head1 BULK LOADING

C<execute(@bind_values)> binds and sends exactly B<one row> of placeholder
values per call. ClickHouse's own operational guidance is the opposite of
one-row-per-request: each C<INSERT> creates one MergeTree part, and many
small inserts cause part explosion and C<Too many parts> throttling. ClickHouse
recommends batching on the order of thousands to hundreds of thousands of rows
per C<INSERT>.

B<Do not call C<execute()> in a loop to bulk-load data.> That reproduces the
row-per-request pattern ClickHouse advises against, with an added HTTP
round-trip per row on top.

Two ways to bulk-load instead:

=head2 execute_array (the DBI-idiomatic way)

    my $sth = $dbh->prepare( 'INSERT INTO users (id, name) VALUES (?, ?)' );
    $sth->bind_param_array( 1, [ 1, 2, 3 ] );
    $sth->bind_param_array( 2, [ 'alice', 'bob', 'carol' ] );
    my $tuples = $sth->execute_array( { ArrayTupleStatus => \my @status } );

For a statement shaped exactly like the example above -- a single C<?>-tuple
immediately after C<VALUES>, nothing else -- this sends the B<whole batch as
one HTTP request>, regardless of row count, by building one raw multi-row
C<INSERT> internally (values are safely quoted the same way C<< $dbh->quote
>> would). Anything else (C<UPDATE>, multiple C<VALUES> tuples, mixed
literal/placeholder tuples, etc.) transparently falls back to one
C<execute()> call per row -- correct DBI behavior, just not accelerated.

Every array bound via C<bind_param_array> must have the same length (a bound
scalar broadcasts to every tuple instead, per the DBI convention); a
shorter/longer array is a driver-detected usage error, not silently
C<NULL>-padded.

B<ArrayTupleStatus> granularity: ClickHouse reports one pass/fail for the
I<whole> batched statement, not per row. By default, on failure every
tuple's status entry gets the same C<[err, errstr, state]> and
C<execute_array> returns C<undef> -- one HTTP request either way. Pass
C<< chng_retry_on_error => 1 >> (in the C<\%attr> hashref, or set
beforehand as C<< $sth->{chng_retry_on_error} = 1 >>) to opt into precise
per-row diagnosis: only when the batched attempt fails with a definite
server-side rejection, it retries once, looping C<execute()> per tuple so
every row gets its own accurate status.

That retry never happens after an ambiguous B<transport> failure (a dropped
connection, a timeout) -- in that case the batch's actual effect on the
server is unknown, and retrying could silently duplicate rows that were
already written before the response was lost. Those failures always use the
uniform (same status for every tuple) reporting, regardless of
C<chng_retry_on_error>.

C<ArrayTupleFetch> (row-wise supply via a callback or another statement
handle) is not supported and is rejected with a clear error rather than
silently ignored; use C<bind_param_array> or column-wise C<@bind_values>
instead.

C<< $sth->{ParamArrays} >> reflects whatever's currently bound via
C<bind_param_array>/C<execute_array>'s column-wise C<@bind_values>, keyed by
1-based parameter number (per DBI convention). It's C<undef> if no arrays
are bound.

=head2 Raw multi-row SQL (for anything execute_array can't accelerate)

Sent with no bind parameters through C<do($sql)> or
C<< prepare($sql)->execute() >>. SQL text is always sent as the POST body, so
a single call can carry a very large statement in one HTTP request:

    my @rows = ( [ 1, 'alice' ], [ 2, 'bob' ], ... );   # thousands of rows

    my $sql = 'INSERT INTO users (id, name) VALUES '
        . join( ',', map {
            '(' . join( ',', $_->[0], $dbh->quote( $_->[1] ) ) . ')'
        } @rows );

    $dbh->do( $sql );

Quote every scalar with C<< $dbh->quote >> (or C<quote_identifier> for
identifiers); never interpolate untrusted values directly into the SQL text.

Parameterized C<execute()> remains correct for single-row INSERT/DML and
ordinary parameterized SELECT; it must not be used in a loop for bulk
loading.

=head2 Bulk read-back

By default, result sets are parsed from a single buffered C<JSONCompact>
HTTP response -- the whole response is held in memory before any row is
available via C<fetch>. This is simple and avoids partial-row/chunk-boundary
parsing, but it means a very-large-row-count C<SELECT> costs memory
proportional to the whole result. For read-heavy access to very large
tables, see L</STREAMING LARGE RESULT SETS> for the opt-in bounded-batch
alternative.

=head1 STREAMING LARGE RESULT SETS

Opt-in, off by default (see the C<fetch_batch_rows> DSN key under L</DSN>).
When enabled -- connection-wide via the DSN, or per statement via
C<< $sth->{chng_fetch_batch_rows} >> set any time after C<prepare> and
before C<execute> -- C<execute()> requests
C<JSONCompactEachRowWithNamesAndTypes> over a dedicated C<Net::HTTP>/
C<Net::HTTPS> connection (line-oriented: one JSON array per column-name
line, one per column-type line, then one per data row) instead of
C<HTTP::Tiny>'s buffered C<JSONCompact>. C<fetch()> reads and decodes rows
in batches of C<fetch_batch_rows> rows at a time, so client memory stays
bounded to roughly one batch rather than the whole result.

With C<tls=1>, this connects via C<Net::HTTPS> with certificate and
hostname verification requested explicitly (C<SSL_verify_mode>,
C<SSL_verifycn_scheme => 'http'>), matching the buffered path's
C<verify_SSL => 1> (see also C<tls_insecure> under L</DSN>). Verified live,
for both the buffered and streaming transports: a valid certificate
connects and queries successfully with verification on; a hostname
mismatch is correctly refused with verification on; and C<tls_insecure=1>
connects successfully despite that same mismatch.

C<wait_end_of_query=1> (see L</ERROR HANDLING>) still applies in this mode:
the server still buffers the complete result before responding, so errors
are still reported cleanly via the HTTP status/headers before any row data,
never mid-stream. This means streaming here bounds client memory only, not
server memory.

Two behavioral differences from the buffered path:

=over 4

=item *

C<< $sth->rows >> returns C<-1> (unknown) for a streamed C<SELECT> -- the
row count isn't known until the scan completes, per DBI's "not known"
convention.

=item *

The streaming connection does not request response compression; only the
default buffered path does (see L</TRANSPORT COMPRESSION>).

=back

C<finish()> closes the underlying streaming connection if it hasn't been
fully read yet, so it's safe to abandon a partially-fetched streamed
statement and reuse the C<$dbh> for other queries.

The memory bound only holds when rows are consumed one at a time via
C<fetch>/C<fetchrow_*>. C<fetchall_arrayref>, C<selectall_arrayref>,
C<selectall_hashref>, and similar DBI generic helpers are built on top of
C<fetch> -- they still read the transport in bounded batches, but then
accumulate every row into the single arrayref/hashref they return, so the
result as a whole is unbounded again.

=head1 CATALOG METHODS

C<table_info>, C<column_info>, and C<type_info_all> are implemented,
querying C<system.tables>/C<system.columns> over the same HTTP interface as
any other statement, and wrapping the results as a real statement handle
via the DBI-bundled C<DBD::Sponge>. C<tables()>, C<type_info()>, and
C<primary_key()> work automatically on top of these via DBI's generic
layer.

ClickHouse has one namespace level (the database), so:

=over 4

=item *

C<TABLE_CAT> is the ClickHouse database name; C<TABLE_SCHEM> is always
C<undef> ("not applicable" -- ClickHouse has no schema level).

=item *

A non-empty C<$schema> argument to C<table_info>/C<column_info> can never
match anything (no table has one); an empty-string C<$catalog> argument
can never match anything either (every table has a database) -- per DBI's
documented convention that C<''> means "match rows where this level
doesn't apply." C<undef> means "no restriction" for both, as usual.

=item *

C<$catalog>/C<$table>/C<$column> accept SQL C<LIKE> search patterns
(C<%>, C<_>), passed through to ClickHouse's C<LIKE> unchanged. This means a
literal name containing C<_> (e.g. C<user_sessions>) also matches names
that differ in that position (C<userXsessions>) -- a caller that needs an
exact match, not a pattern, must escape it (C<user\_sessions>) or filter
the returned rows themselves.

=item *

The ODBC catalog-function special cases (C<$catalog='%'> with the other
arguments empty to list catalogs; C<$schema='%'> to list schemas;
C<$type='%'> to list table types) are not implemented -- DBI marks these as
only optionally supported.

=back

C<DATA_TYPE>/C<NULLABLE> in C<column_info> reuse C<DBD::ClickhouseNG::Types::map_ch_type>, the same
mapping ordinary result-set metadata uses (see L</SUPPORTED METHODS>), so a
column's reported type is always consistent with what a C<SELECT> of that
column would report. C<COLUMN_SIZE>/C<DECIMAL_DIGITS>/C<NUM_PREC_RADIX>
prefer ClickHouse's own C<system.columns> figures when available (e.g. the
actual length of a C<FixedString(N)> column, or a C<Decimal(P,S)> column's
precision/scale) over falling back to C<DBD::ClickhouseNG::Types::map_ch_type>'s more approximate
values.

C<type_info_all> is static reference data (ClickHouse's own type list isn't
itself queryable); C<COLUMN_SIZE> is given in bits with C<NUM_PREC_RADIX=2>
for integer/float families and in decimal digits with C<NUM_PREC_RADIX=10>
for C<Decimal>, matching what C<system.columns> itself reports for real
columns of those types.

=head2 primary_key_info

ClickHouse has no PRIMARY KEY I<constraint> the way DBI models one
(uniqueness-enforcing); what MergeTree-family tables have instead is a real,
queryable ORDER BY/PRIMARY KEY I<sorting> expression
(C<system.tables.primary_key>), which is what this reports -- one row per
top-level key-part expression, ordered by C<KEY_SEQ>. C<COLUMN_NAME> is the
plain column name for a simple key part, or the raw expression text (e.g.
C<toDate(ts)>) for a functional one -- splitting on commas respects
parenthesis nesting, so a multi-argument function in a key part (e.g.
C<someFunc(a, b)>) isn't broken into two rows. C<PK_NAME> is always
C<undef>: ClickHouse sorting keys aren't named constraints. A table with no
C<ORDER BY> (e.g. a C<Memory>-engine table) returns no rows, per DBI's "no
primary key" convention.

Unlike C<table_info>/C<column_info>, C<$catalog>/C<$schema>/C<$table> here
do B<not> accept search patterns (per DBI spec) -- exact match only, or
C<undef> for "no restriction". The C<TABLE_CAT>/C<TABLE_SCHEM>
empty-string-vs-undef handling is otherwise identical to C<table_info>'s
(see above).

C<foreign_key_info> and C<statistics_info> remain not applicable --
unlike C<primary_key_info>, ClickHouse genuinely has no foreign-key concept
and no directly analogous index-statistics model, so there is nothing to
query.

=head1 DRIVER METADATA

=head2 get_info

Only a small, curated set of DBI's ~150 ODBC info codes is implemented --
ones this driver can answer with a real, verifiable fact rather than a
guess: C<SQL_DRIVER_NAME>, C<SQL_DRIVER_VER>, C<SQL_DBMS_NAME>,
C<SQL_DBMS_VER> (queried from the server via C<SELECT version()> and cached
on the handle), C<SQL_IDENTIFIER_QUOTE_CHAR> (C<">),
C<SQL_CATALOG_NAME_SEPARATOR> (C<.>), C<SQL_CATALOG_TERM> (C<database> --
ClickHouse's one namespace level), and C<SQL_TXN_CAPABLE>
(C<SQL_TC_NONE> -- no transactions). Every other info type returns C<undef>,
DBI's own default for unimplemented codes.

=head2 data_sources

C<< $dbh->data_sources >> lists the databases visible to the connected
user (via C<SHOW DATABASES>), returned as full C<dbi:ClickhouseNG:...> DSNs
that reuse the handle's own host/port/tls, so they're directly usable with
C<< DBI->connect >>. There is no driver-level C<< $drh->data_sources >>
equivalent -- enumerating databases needs an actual connection, which the
driver handle doesn't have; it continues to return an empty list.

=head2 ChopBlanks

C<FixedString(N)> is ClickHouse's only fixed-width string type, and it's
padded with NUL bytes (C<\0>), not spaces, to its declared width.
C<ChopBlanks> is interpreted accordingly: when true (inherited from C<$dbh>
or set per-statement, per the usual DBI convention), trailing C<\0> bytes
are stripped from C<FixedString> column values on fetch. Trailing space
characters are left untouched, since a space is legitimate C<FixedString>
content in ClickHouse, not padding. No other column type is affected.

=head1 JSON DECODING

C<Cpanel::JSON::XS> is used when installed (an XS-accelerated, API-compatible
drop-in for C<JSON::PP>); otherwise the driver falls back to C<JSON::PP>
(core, always available). Neither is a hard dependency beyond C<JSON::PP>
itself -- C<Cpanel::JSON::XS> is purely an optional speed-up, selected once
at load time and exposed as C<$DBD::ClickhouseNG::JSON_CLASS> for
inspection/testing.

=head1 TRANSPORT COMPRESSION

Every request is sent gzip-compressed (C<Content-Encoding: gzip>) and asks
for a gzip-compressed response (C<Accept-Encoding: gzip>), using only core
modules (C<IO::Compress::Gzip> / C<IO::Uncompress::Gunzip>). This is
unconditional -- there is no DSN knob to disable it. ClickHouse also supports
several other codecs (zstd, lz4, br, ...) on this header, but none of them
has a corresponding pure-Perl or reliably-installable XS module that
produces the exact container format ClickHouse's HTTP server expects (in
particular, the C<Compress::LZ4> CPAN module emits its own non-standard
framing, not the LZ4 frame format ClickHouse requires); gzip was chosen
specifically because it is core and was verified working end-to-end against
a live server.

=head1 ERROR HANDLING

All failures go through C<< $h->set_err(...) >>, so C<RaiseError>,
C<PrintError>, and C<HandleError> behave per normal DBI semantics. Methods
return C<undef>/false after C<set_err> -- nothing dies except attempting to
disable C<AutoCommit>, which is a fatal usage error per DBI convention.

=over 4

=item Transport failure at connect time

C<err> is C<1>, C<state> is C<08001>.

=item Transport failure after connect

C<err> is C<1>, C<state> is C<08S01>.

=item Server exception (C<X-ClickHouse-Exception-Code> header present)

C<err> is the ClickHouse exception code, C<state> is C<S1000>.

=item Non-200 response without that header

C<err> is the HTTP status code, C<state> is C<S1000>.

=item 200 response but the body isn't valid JSON

C<err> is C<$DBI::stderr>, C<state> is C<S1000>.

=item Driver-detected usage error

C<err> is C<$DBI::stderr>, C<state> is C<S1000>.

=back

There is no retry logic: a dropped connection is not retried, because
retrying a possibly-already-executed statement (e.g. an INSERT) is unsafe.
HTTP keep-alive reconnects transparently for subsequent, fresh requests.

=head1 QUOTING

C<< $dbh->quote($value) >> escapes C<\> and C<'> and wraps the result in
single quotes (C<undef> becomes C<NULL>), matching ClickHouse string literal
escaping (backslash is an escape character there, unlike plain SQL
C<''>-doubling). C<quote_identifier> uses DBI's default double-quote-doubling
behavior, which is already correct for ClickHouse.

=head1 SEE ALSO

L<DBI>.

=head1 AUTHOR

Peter Gervai <grin@grin.hu>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify it
under the terms of either:

=over 4

=item *

the GNU General Public License as published by the Free Software
Foundation; either version 3, or (at your option) any later version, or

=item *

the "Artistic License".

=back

=cut
