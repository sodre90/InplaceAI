#!/usr/bin/env bash
set -euo pipefail

# Create (once) a self-signed code-signing identity in a dedicated keychain so
# locally-built InplaceAI.app gets a STABLE codesign Designated Requirement.
#
# Why: macOS ties the Accessibility (TCC) grant to the app's signature. An
# ad-hoc signature ("-") gets a new cdhash on every rebuild, so the grant breaks
# each time you rebuild. A self-signed cert yields a Designated Requirement of
# the form `identifier "com.inplaceai.desktop" and certificate leaf = H"..."`,
# which is identical across rebuilds — so the grant survives.
#
# Idempotent: if the identity already exists it is kept (regenerating would
# change the leaf-cert hash and break the existing grant). To rotate, delete the
# keychain first: security delete-keychain "$SIGN_KEYCHAIN".

IDENTITY="${LOCAL_SIGN_IDENTITY:-InplaceAI Local Signing}"
KEYCHAIN="${SIGN_KEYCHAIN:-$HOME/Library/Keychains/inplaceai-signing.keychain-db}"
# Local-only keychain holding nothing but this self-signed code-signing key.
# The password guards a key with no value outside this machine; not a real secret.
KEYCHAIN_PW="${SIGN_KEYCHAIN_PW:-inplaceai}"

if [[ -f "$KEYCHAIN" ]] && security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already present in:"
    echo "  $KEYCHAIN"
    echo "Keeping it (regenerating would change the leaf-cert hash and break the"
    echo "existing Accessibility grant)."

    # Keychains created before the codesign: partition was added still prompt on
    # every signing run. Refresh the partition list so they stop.
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "Refreshed the key partition list; codesign will not prompt."
    else
        echo
        echo "Could not refresh the key partition list — SIGN_KEYCHAIN_PW does not match"
        echo "this keychain, so codesign may keep prompting. To fix it, run:"
        echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \\"
        echo "    -k '<keychain password>' '$KEYCHAIN'"
    fi
    exit 0
fi

TMP="$(mktemp -d /tmp/inplaceai-cert.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

echo "Generating self-signed code-signing certificate..."
cat > "$TMP/ext.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/ext.cnf" >/dev/null 2>&1

# -legacy + sha1 MAC + non-empty password: required for macOS `security import`
# to read OpenSSL 3.x PKCS#12 files.
openssl pkcs12 -export -legacy -macalg sha1 -name "$IDENTITY" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:tmppw >/dev/null 2>&1

if [[ ! -f "$KEYCHAIN" ]]; then
    echo "Creating dedicated signing keychain..."
    security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no auto-lock timeout
fi

security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P tmppw -T /usr/bin/codesign -A >/dev/null
# Allow codesign to use the key without an interactive keychain prompt. The
# codesign: partition is required alongside apple:/apple-tool: — importing with
# `-T /usr/bin/codesign` alone still leaves macOS prompting on first use.
if ! security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Warning: could not set the key partition list; codesign may prompt on first use." >&2
fi

# codesign locates a signing identity by name via the user keychain SEARCH LIST
# (the --keychain flag alone is not sufficient), so add ours if it isn't there.
if ! security list-keychains -d user | sed 's/[" ]//g' | grep -qxF "$KEYCHAIN"; then
    EXISTING="$(security list-keychains -d user | sed 's/[" ]//g')"
    security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$IDENTITY"; then
    echo "Created signing identity '$IDENTITY' in:"
    echo "  $KEYCHAIN"
    echo "build_dmg.sh will auto-detect and use it. Rebuilds now keep their Accessibility grant."
else
    echo "Error: identity not found in keychain after import." >&2
    exit 1
fi
