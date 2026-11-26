#!/usr/bin/env bash
# CI helper: create a throwaway CA, a server certificate for "localhost" and a
# client certificate for the mTLS user, plus the ClickHouse config.d/users.d
# snippets that enable HTTPS with optional client certificates.
#
# Usage: .github/ci-tls-setup.sh OUT_DIR [CERT_DIR_AS_SEEN_BY_SERVER]
#
# Writes OUT_DIR/certs/{ca,server,client}.{crt,key},
#        OUT_DIR/config.d/chng-tls.xml, OUT_DIR/users.d/chng-mtls.xml.
# Server certificate SAN is DNS:localhost only, so 127.0.0.1 is a "wrong host"
# for t/57. The mTLS user is "chng_mtls" (client certificate CN).

set -euo pipefail

OUT="${1:?usage: $0 OUT_DIR [CERT_DIR]}"
CERTS="$OUT/certs"
SRV_CERTS="${2:-$CERTS}"

mkdir -p "$CERTS" "$OUT/config.d" "$OUT/users.d"
cd "$CERTS"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj '/CN=chng-ci-ca' -keyout ca.key -out ca.crt 2>/dev/null

sign() { # name subject extensions
    openssl req -newkey rsa:2048 -nodes -subj "$2" \
        -keyout "$1.key" -out "$1.csr" 2>/dev/null
    openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -days 2 -extfile <( printf '%s\n' "$3" ) -out "$1.crt" 2>/dev/null
    rm -f "$1.csr"
}
sign server '/CN=localhost' \
    $'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost'
sign client '/CN=chng_mtls' \
    $'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth'
rm -f ca.srl
chmod 0644 ./*.key   # read by the clickhouse user and by the test process

cat > "$OUT/config.d/chng-tls.xml" <<EOF
<clickhouse>
    <https_port>8443</https_port>
    <openSSL>
        <server>
            <certificateFile>$SRV_CERTS/server.crt</certificateFile>
            <privateKeyFile>$SRV_CERTS/server.key</privateKeyFile>
            <caConfig>$SRV_CERTS/ca.crt</caConfig>
            <verificationMode>relaxed</verificationMode>
            <loadDefaultCAFile>false</loadDefaultCAFile>
        </server>
    </openSSL>
</clickhouse>
EOF

cat > "$OUT/users.d/chng-mtls.xml" <<'EOF'
<clickhouse>
    <users>
        <chng_mtls>
            <ssl_certificates>
                <common_name>chng_mtls</common_name>
            </ssl_certificates>
            <networks><ip>::/0</ip></networks>
            <profile>default</profile>
            <quota>default</quota>
        </chng_mtls>
    </users>
</clickhouse>
EOF
