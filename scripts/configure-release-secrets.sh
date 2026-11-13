#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
REPOSITORY="davimcruz/PgQuery"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
TEMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT HUP INT TERM

if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "Authenticate first with: gh auth login -h github.com" >&2
  exit 1
fi
if ! gh repo view "$REPOSITORY" >/dev/null 2>&1; then
  echo "Create and push the public repository first: gh repo create $REPOSITORY --public --source=. --remote=origin --push" >&2
  exit 1
fi
if [ ! -x "$SPARKLE_BIN/generate_keys" ]; then
  swift package resolve --disable-sandbox
fi

"$SPARKLE_BIN/generate_keys" -x "$TEMP_DIR/sparkle-private-key"
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
if [ -z "$PUBLIC_KEY" ]; then
  echo "Could not read the Sparkle public key from Keychain" >&2
  exit 1
fi

cat > "$TEMP_DIR/certificate.cnf" <<'CNF'
[req]
distinguished_name = subject
x509_extensions = codesign
prompt = no
[subject]
CN = PgQuery Release Signing
[codesign]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
CNF
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout "$TEMP_DIR/signing.key" -out "$TEMP_DIR/signing.crt" \
  -config "$TEMP_DIR/certificate.cnf"
CERT_PASSWORD="$(openssl rand -hex 32)"
printf '%s' "$CERT_PASSWORD" > "$TEMP_DIR/certificate-password"
openssl pkcs12 -export -out "$TEMP_DIR/signing.p12" \
  -inkey "$TEMP_DIR/signing.key" -in "$TEMP_DIR/signing.crt" \
  -passout "file:$TEMP_DIR/certificate-password"
security import "$TEMP_DIR/signing.p12" -P "$CERT_PASSWORD" -A -t cert -f pkcs12 -k "$HOME/Library/Keychains/login.keychain-db"

gh secret set SPARKLE_PRIVATE_ED_KEY --repo "$REPOSITORY" < "$TEMP_DIR/sparkle-private-key"
base64 < "$TEMP_DIR/signing.p12" | tr -d '\n' | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPOSITORY"
gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPOSITORY" < "$TEMP_DIR/certificate-password"
gh variable set SPARKLE_PUBLIC_ED_KEY --repo "$REPOSITORY" --body "$PUBLIC_KEY"

echo "Release signing secrets configured on $REPOSITORY. Private key files were removed from the temporary directory."
