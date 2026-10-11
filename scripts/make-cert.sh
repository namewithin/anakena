#!/bin/bash
# Creates a self-signed code-signing identity in the login keychain, so the
# Accessibility permission survives rebuilds (ad-hoc signing loses it each time).
# build.sh picks it up automatically. Safe to run again: does nothing if it exists.
# Each build asks to use the key: click Allow, never Always Allow.
set -euo pipefail

NAME="Anakena Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

has_identity() {
    # No -v: the cert is untrusted but codesign can still use it.
    local ids count
    ids="$(security find-identity -p codesigning 2>/dev/null || true)"
    count="$(awk -v name="$NAME" 'index($0, "\"" name "\"") && length($2) == 40 && $2 !~ /[^[:xdigit:]]/ && !seen[$2]++ { n++ } END { print n+0 }' <<<"$ids")"
    if [ "$count" -gt 1 ]; then
        echo "error: multiple \"$NAME\" identities; remove duplicates before running this script" >&2
        exit 1
    fi
    [ "$count" -eq 1 ]
}

if has_identity; then
    echo "Signing identity \"$NAME\" already exists."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $NAME

[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem"

# OpenSSL 3+ writes p12 files Keychain can't import unless -legacy is used.
# macOS's own openssl (LibreSSL) has no -legacy and doesn't need it.
LEGACY=()
if openssl pkcs12 -help 2>&1 | grep -q -- -legacy; then LEGACY=(-legacy); fi

P12_PW="$(openssl rand -hex 16)"
P12_PW="$P12_PW" openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout env:P12_PW

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$P12_PW"

if ! has_identity; then
    echo "Import finished but \"$NAME\" is not listed as a signing identity." >&2
    exit 1
fi
echo "Created signing identity \"$NAME\"."
