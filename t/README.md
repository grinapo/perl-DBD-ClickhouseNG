# Test suite

Run everything from the repository root. Two kinds of tests:

| Files | Kind | Needs |
|---|---|---|
| `t/00`–`t/26` | offline | nothing (no network) |
| `t/50`–`t/58` | live | a ClickHouse server, enabled by environment variables |

A live test whose variables are unset **skips itself** (it is not a failure),
so `prove -l t/` is always safe to run.

## Phases

### 1. Offline (default)

```bash
prove -l t/                 # everything; live tests skip
prove -l t/0* t/1* t/2*     # offline files only
./Build test                # same via Module::Build::Tiny (run `perl Build.PL` first)
```

Includes the module dependency check (`t/01-module-deps.t`, must be updated
when a module or an internal dependency is added) and the mTLS option/header
unit tests (`t/27-mtls.t`).

### 2. Live, plain HTTP (`t/50`–`t/56`)

Enabled by `CHNG_TEST_DSN`.

| Variable | Meaning |
|---|---|
| `CHNG_TEST_DSN` | required; e.g. `dbi:ClickhouseNG:host=localhost;database=test` |
| `CHNG_TEST_USER` | optional; ClickHouse user |
| `CHNG_TEST_PASS` | optional; its password |

```bash
CHNG_TEST_DSN='dbi:ClickhouseNG:host=localhost;database=test' \
CHNG_TEST_USER=me CHNG_TEST_PASS=secret \
    prove -l t/5[0-6]*.t
```

The tests create and drop their own tables (`dbd_chng_test_<nn>_<pid>`, engine
`Memory`) in the database of the DSN. The user needs CREATE/DROP/INSERT/SELECT
there.

### 3. Live, TLS with server verification (`t/57-live-tls.t`)

Needs `CHNG_TEST_TLS_HOST`. The database name and credentials still come from
`CHNG_TEST_DSN` / `_USER` / `_PASS` (phase 2), so those must be set too.

| Variable | Meaning | Default |
|---|---|---|
| `CHNG_TEST_TLS_HOST` | server name; the certificate must be valid for exactly this name | – (unset: skip) |
| `CHNG_TEST_TLS_PORT` | HTTPS port | `8443` |
| `CHNG_TEST_TLS_CA` | CA bundle (PEM) that verifies the server certificate | system store |
| `CHNG_TEST_TLS_WRONG_HOST` | a *different* name reaching the same server/port/certificate (e.g. `localhost`) | – |

Without `CHNG_TEST_TLS_WRONG_HOST` the hostname-mismatch and `tls_insecure`
subtests are skipped; the others still run. The file also skips if a
configured host is unreachable.

```bash
CHNG_TEST_DSN='dbi:ClickhouseNG:host=localhost;database=test' CHNG_TEST_USER=me CHNG_TEST_PASS=secret \
CHNG_TEST_TLS_HOST=ch.example CHNG_TEST_TLS_WRONG_HOST=localhost CHNG_TEST_TLS_CA=keys/ca.crt \
    prove -lv t/57-live-tls.t
```

### 4. Live, mutual TLS (`t/58-live-mtls.t`)

Independent of `CHNG_TEST_DSN` and of the phase-3 variables; enabled by the variables below. It skips unless
`HOST`, `USER`, `CERT` and `KEY` are all set.

| Variable | Meaning | Default |
|---|---|---|
| `CHNG_TEST_MTLS_HOST` | server name; must match the server certificate | – |
| `CHNG_TEST_MTLS_PORT` | HTTPS port | `8443` |
| `CHNG_TEST_MTLS_USER` | ClickHouse user identified by the client certificate; empty password | – |
| `CHNG_TEST_MTLS_CERT` | client certificate (PEM) | – |
| `CHNG_TEST_MTLS_KEY` | client private key (PEM, no passphrase) | – |
| `CHNG_TEST_MTLS_CA` | CA bundle (PEM) that verifies the server certificate | system store |
| `CHNG_TEST_MTLS_DB` | database | `default` |

```bash
CHNG_TEST_MTLS_HOST=ch.example CHNG_TEST_MTLS_USER=svc \
CHNG_TEST_MTLS_CERT=keys/client.crt CHNG_TEST_MTLS_KEY=keys/client.key \
CHNG_TEST_MTLS_CA=keys/ca.crt \
    prove -lv t/58-live-mtls.t
```

It checks certificate login on the buffered and streaming paths, and that the
same user is rejected without the certificate. It creates no tables.

Server requirements:

- a user with `<ssl_certificates>` (`common_name` or `subject_alt_name`)
  matching the certificate, or 
  `CREATE USER click_test IDENTIFIED WITH ssl_certificate CN 'click_test.local'`;
- `openSSL.server.verificationMode` not `none` (use `relaxed`, or `strict` to
  require certificates), so the server sends a TLS `CertificateRequest`;
- `openSSL.server.caConfig` pointing at the CA that issued the client
  certificate.

A server with `verificationMode=none` fails the first two subtests with
`SSL certificate authentication requires nonempty certificate's Common Name
or Subject Alternative Name`. To check what the server asks for:

```bash
echo | openssl s_client -connect HOST:8443 -tls1_2 -msg 2>&1 | grep CertificateRequest
```

## Adding tests

- A new file in `t/` must be added to `MANIFEST`.
- New live tests should skip when their variables are unset, use a
  `dbd_chng_test_<nn>_$$` table name, and clean up after themselves.
