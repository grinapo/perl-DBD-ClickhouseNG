# DBD::ClickhouseNG

A minimal, DBI-compliant Perl driver for ClickHouse over its HTTP interface.

It is designed to be correct, properly handle errors and failure modes, ability to use batch transfers and compression.

## Install

    perl Build.PL
    ./Build
    ./Build test
    ./Build install

## Documentation

Full usage docs (DSN, placeholders, bulk loading, error handling, quoting)
are in the module's POD:

    perldoc DBD::ClickhouseNG

Runnable examples are in `examples/`:

- `examples/basic.pl` — connect, DDL, parameterized INSERT/SELECT, fetch loop.
- `examples/bulk_insert_manual.pl` — bulk INSERT via one hand-built, raw
  multi-row SQL statement.
- `examples/bulk_insert_auto.pl` — the same bulk INSERT via
  `bind_param_array`/`execute_array` instead, including the
  `chng_retry_on_error` per-row diagnosis mode.

Each takes a DSN (and optional user/password) as arguments, e.g.:

    perl examples/basic.pl dbi:ClickhouseNG:host=localhost

### Generating documentation in other formats

The module's POD can be converted to other formats with the standard tools
that ship with Perl itself (no extra dependencies):

    # plain text
    pod2text lib/DBD/ClickhouseNG.pm > DBD-ClickhouseNG.txt

    # standalone HTML page
    pod2html lib/DBD/ClickhouseNG.pm --outfile=DBD-ClickhouseNG.html

    # a man page (view with: man ./DBD::ClickhouseNG.3pm)
    pod2man --name=DBD::ClickhouseNG --section=3pm \
        lib/DBD/ClickhouseNG.pm > DBD::ClickhouseNG.3pm

`./Build build` also generates man pages for every module under `blib/`
automatically (that's what `./Build install` installs); the commands above
are for producing a standalone copy without a full build/install.

## Feature coverage vs. a full DBI driver

DBI defines a large method/attribute surface (see `perldoc DBI`), but many of
those are generic conveniences DBI implements once on top of a handful of
driver primitives (`prepare`, `execute`, `bind_param`, `fetch`, and a few
attributes) — those work automatically here too, without this driver doing
anything special for them. The tables below cover what a driver actually has
to implement itself, plus the attributes/behaviors that differ from a "full"
transactional DBD. Everything stated here was checked against the actual
driver, not assumed.

Legend: ✅ implemented &nbsp; ⚠️ partial/limited &nbsp; ❌ not implemented (DBI's default applies — usually a no-op or `undef`) &nbsp; 🚫 not applicable (nothing to implement — ClickHouse's HTTP interface has no such concept)

**Connection**

| Feature | Status | Notes |
|---|---|---|
| `connect` | ✅ | validated with a `SELECT 1` round-trip at connect time |
| `disconnect` | ✅ | stateless transport, just flips `Active` |
| `ping` | ✅ | `GET /ping` |
| `data_sources` | ✅ (dbh-level) | `$dbh->data_sources` lists databases via `SHOW DATABASES`; `$drh->data_sources` still returns an empty list (no connection to query from) |
| `clone` | ⚠️ | DBI's generic reconnect-with-same-args default applies; not driver-specific |
| `get_info` | ⚠️ | minimal curated set only (driver/DBMS name+version, identifier quoting, catalog term/separator, `SQL_TXN_CAPABLE`); `undef` for every other info type |
| `take_imp_data` | ❌ | not implemented |

**Statements & parameters**

| Feature | Status | Notes |
|---|---|---|
| `prepare` / `prepare_cached` | ✅ | no server round-trip at prepare time; `prepare_cached` works via DBI's generic layer over `prepare` |
| `?` positional placeholders | ✅ | translated to ClickHouse's `{pN:Type}` + `param_pN` |
| `bind_param` | ✅ | explicit `SQL_*` type, or inferred from the Perl value |
| `bind_param_inout` | 🚫 | not applicable (no OUT parameters in ClickHouse) |
| `bind_param_array` / `execute_array` | ⚠️ | one HTTP request for the whole batch when the statement is a single `INSERT ... VALUES (?, ...)` tuple; falls back to one `execute()` per row otherwise -- see "Differences" below |
| `execute_for_fetch` | ❌ | not implemented directly; `execute_array` covers the common case |
| `execute` | ✅ | one HTTP request per call |
| `do` | ✅ | fast path with no bind values/attrs; prepare+execute otherwise |

**Fetching**

| Feature | Status | Notes |
|---|---|---|
| `fetch` / `fetchrow_arrayref` | ✅ | driver primitive |
| `fetchrow_array`, `fetchrow_hashref`, `fetchall_arrayref`, `fetchall_hashref`, `selectrow_*`, `selectall_*`, `selectcol_arrayref`, `bind_col`, `bind_columns`, `dump_results` | ✅ (via DBI's generic layer) | all work automatically on top of `fetch` |
| `more_results` | 🚫 | not applicable; ClickHouse's HTTP interface returns one result set per request |
| Streaming/chunked fetch | ⚠️ | opt-in via `fetch_batch_rows` (DSN key or `chng_fetch_batch_rows` handle/statement attribute); off by default, which still buffers the whole `JSONCompact` response in memory (see "Streaming large result sets" below) |

**Metadata attributes**

| Feature | Status | Notes |
|---|---|---|
| `NUM_OF_FIELDS`, `NUM_OF_PARAMS`, `NAME`, `TYPE`, `PRECISION`, `SCALE`, `NULLABLE` | ✅ | populated from the result's `meta` block at first `execute` |
| `NAME_lc`, `NAME_uc`, `NAME_hash`, etc. | ✅ (via DBI's generic layer) | derived from `NAME` |
| `ParamValues`, `ParamTypes` | ✅ | |
| `ParamArrays` | ✅ | reflects values bound via `bind_param_array`/`execute_array`; `undef` if none are bound |
| `CursorName` | 🚫 | not applicable (no server-side cursors over HTTP) |
| `ChopBlanks` | ✅ | strips trailing `\0` (ClickHouse's `FixedString(N)` padding byte, not a space) from `FixedString` column values; no other type is affected |
| `LongReadLen` / `LongTruncOk` | 🚫 | not applicable; no LOB streaming |
| `RowsInCache` | 🚫 | not applicable (no read-ahead buffering) |

**Transactions**

| Feature | Status | Notes |
|---|---|---|
| `AutoCommit` | ⚠️ | always on; disabling it croaks (ClickHouse has no transactions) |
| `commit` / `rollback` | ⚠️ | no-ops that warn if `Warn` is set, per DBI convention for non-transactional drivers |
| `begin_work` | 🚫 | dies (it tries to disable `AutoCommit`; not applicable — ClickHouse has no transactions) |
| Savepoints | 🚫 | not applicable |

**Catalog / introspection**

| Feature | Status | Notes |
|---|---|---|
| `table_info`, `column_info` | ✅ | query `system.tables`/`system.columns`, wrapped as a real statement handle via `DBD::Sponge`; `TABLE_CAT` = database name, `TABLE_SCHEM` always `undef` (no schema level) |
| `primary_key_info` | ✅ | reports MergeTree's ORDER BY/PRIMARY KEY sorting expression from `system.tables.primary_key` -- not a uniqueness constraint the way DBI models one, but real, queryable metadata |
| `tables`, `type_info`, `primary_key` | ✅ (via DBI's generic layer) | built automatically on top of `table_info`/`type_info_all`/`primary_key_info` |
| `type_info_all` | ✅ | static reference data (ClickHouse's type list isn't itself queryable) |
| `foreign_key_info`, `statistics_info` | 🚫 | not applicable -- ClickHouse has no foreign-key concept, and no directly analogous index-statistics model to report |

**Quoting**

| Feature | Status | Notes |
|---|---|---|
| `quote` | ✅ | ClickHouse's backslash-escaping rules, not `''`-doubling |
| `quote_identifier` | ✅ (DBI default) | double-quote doubling is already correct for ClickHouse |

### Differences from expected DBD behaviour

- **No transactions.** `AutoCommit` can never be turned off (attempting to
  croaks); `commit`/`rollback` are no-ops that warn under `Warn`.
- **Array/bulk parameter binding is accelerated only for plain INSERT.**
  `bind_param_array`/`execute_array` send the whole batch in one HTTP
  request for a single-tuple `INSERT ... VALUES (?, ...)` statement;
  anything else (`UPDATE`, multiple `VALUES` tuples, etc.) falls back to one
  `execute()` per row. `ArrayTupleStatus` is also coarser than some other
  DBDs: ClickHouse reports one pass/fail for the whole batch, not per row,
  by default — see "BULK LOADING" in the module POD for the opt-in
  `chng_retry_on_error` mode that trades a slower failure path for precise
  per-row diagnosis.
- **No foreign key or index-statistics introspection.** `foreign_key_info`
  and `statistics_info` are not applicable, since ClickHouse has no
  foreign-key concept and no directly analogous index-statistics model to
  report; DBI's empty/`undef` defaults apply. `table_info`/`column_info`/
  `type_info_all`/`primary_key_info` (and `tables`/`type_info`/
  `primary_key` on top of them) are implemented — see "Catalog /
  introspection" above. `primary_key_info` reports ClickHouse's ORDER
  BY/PRIMARY KEY sorting expression, not a uniqueness-enforcing constraint
  the way DBI otherwise models "primary key".
- **Whole result sets are buffered in memory by default** (`JSONCompact`);
  there's no server-side cursor, so a very large `SELECT` costs memory
  proportional to the result size unless streaming is opted into (see
  "Streaming large result sets" below).
- **No LOB-specific handling** — `ChopBlanks`, `LongReadLen`, and
  `LongTruncOk` are unimplemented, since ClickHouse's HTTP/JSON interface
  doesn't expose LOBs the way DBI models them.
- **No `bind_param_inout`** — no OUT parameters, since ClickHouse has no
  stored procedures over this interface.
- **Native `{name:Type}` ClickHouse parameters** written directly in SQL
  pass through untouched, but there's no DBI-level way to bind their values.

### Streaming large result sets

Opt-in, off by default. Set `fetch_batch_rows` in the DSN (connection-wide)
or `chng_fetch_batch_rows` on a statement handle after `prepare` (overrides
the connection-wide default for that statement) to a positive row count:

    my $dbh = DBI->connect( 'dbi:ClickhouseNG:host=localhost;fetch_batch_rows=10000', ... );
    # or, per statement:
    my $sth = $dbh->prepare( 'SELECT ... FROM huge_table' );
    $sth->{chng_fetch_batch_rows} = 10000;
    $sth->execute;
    while( my $row = $sth->fetch ) { ... }

When set, `execute()` requests `JSONCompactEachRowWithNamesAndTypes` over a
dedicated `Net::HTTP`/`Net::HTTPS` connection instead of `HTTP::Tiny`, and
`fetch()` reads/decodes rows in batches of that size instead of decoding the
whole response upfront — client memory stays bounded to roughly one batch
regardless of result size. `wait_end_of_query=1` is still used, so the
server still buffers the full result and errors are still reported cleanly
via HTTP status/headers before any row data (this bounds client memory
only, not server memory). With `tls=1`, the streaming connection requests
certificate + hostname verification explicitly, matching the buffered
path's posture (see `tls_insecure` in the module POD's DSN section to
disable it). 
Two consequences:

- `$sth->rows` returns `-1` (unknown) for a streamed `SELECT`, since the row
  count isn't known until the scan completes.
- The streaming connection does not request response compression (no
  `Accept-Encoding: gzip`), unlike the default buffered path.

**The memory bound only holds when rows are consumed one at a time**
(`fetch`/`fetchrow_*`). `fetchall_arrayref`, `selectall_arrayref`,
`selectall_hashref`, and friends are DBI generic helpers built on top of
`fetch` — they still read in bounded batches over the wire, but then
accumulate every row into the single arrayref/hashref they return, so the
result as a whole is unbounded again. Use a `fetch`/`fetchrow_*` loop to
actually get the memory benefit.

## Tests

Unit tests (`t/00`-`t/26`) run always, with the transport layer mocked — no
server required:

    ./Build test

Integration tests (`t/50`-`t/57`) run against a live ClickHouse server and
are skipped unless `CHNG_TEST_DSN` is set:

    CHNG_TEST_DSN='dbi:ClickhouseNG:host=localhost' ./Build test

Optional `CHNG_TEST_USER` / `CHNG_TEST_PASS` for non-default credentials.
