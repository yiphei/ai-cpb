#!/usr/bin/env bash
# Create a self-signed code-signing identity called "ai-cpb-local" with a
# working private key, and import it into the login keychain so `codesign`
# can use it without further prompts.
#
# Safe to re-run: deletes any prior identity with the same name first.

set -euo pipefail

NAME="ai-cpb-local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "→ Removing any prior cert named '$NAME'"
while security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; do
    security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null || break
done

echo "→ Generating private key + self-signed cert with codeSigning EKU"
cat > "$TMP/ext.cnf" <<'EOF'
[v3_req]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 \
    -subj "/CN=$NAME" \
    -extensions v3_req -config <(cat /etc/ssl/openssl.cnf 2>/dev/null || echo "[req]"; echo; cat "$TMP/ext.cnf") \
    >/dev/null 2>&1

# Fallback if the config trick failed (system openssl.cnf path varies)
if ! openssl x509 -in "$TMP/cert.pem" -text -noout 2>/dev/null | grep -q "Code Signing"; then
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 \
        -subj "/CN=$NAME" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        >/dev/null 2>&1
fi

echo "→ Packaging as PKCS12 (legacy format for macOS Security)"
# macOS's `security import` cannot read modern OpenSSL 3 PKCS12
# (AES-256-CBC + SHA256). Force legacy 3DES + SHA1.
openssl pkcs12 -export -legacy \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" \
    -out "$TMP/bundle.p12" \
    -password pass:temp \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg SHA1 \
    2>/dev/null || \
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" \
    -out "$TMP/bundle.p12" \
    -password pass:temp \
    -keypbe PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg SHA1 \
    >/dev/null 2>&1

echo "→ Importing into login keychain (allow codesign to use it)"
security import "$TMP/bundle.p12" \
    -k "$KEYCHAIN" \
    -P temp \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -A \
    >/dev/null

echo "→ Setting partition list so codesign won't prompt (may ask for login password)"
security set-key-partition-list \
    -S "apple-tool:,apple:,codesign:" \
    -s \
    -k "" \
    "$KEYCHAIN" \
    >/dev/null 2>&1 || \
    echo "   (set-key-partition-list needs your login password; rerun if it fails)"

echo
echo "→ Verifying by test-signing a small binary"
TEST_BIN="$(mktemp)"
echo "int main(){return 0;}" | clang -o "$TEST_BIN" -xc - 2>/dev/null
if codesign -s "$NAME" --force "$TEST_BIN" 2>/dev/null; then
    echo "✓ Identity '$NAME' is ready to use."
    echo "  (Note: 'security find-identity -v' shows it as untrusted — that's normal for"
    echo "   a self-signed root and does not affect codesign or TCC behavior.)"
    rm -f "$TEST_BIN"
else
    echo "✗ Test-sign with '$NAME' failed. Diagnostic dump:"
    security find-identity -p codesigning
    rm -f "$TEST_BIN"
    exit 1
fi
