#!/usr/bin/env bash
# Create a stable self-signed code-signing identity named by
# scripts/dev-identity.sh in the login keychain.
#
# Why: ad-hoc signing (CODE_SIGN_IDENTITY=-) produces a different code hash on
# every build. macOS binds Keychain item ACLs to that hash, so every rebuild
# triggers a fresh "wants to use your confidential information" prompt and
# "Always Allow" never sticks. A stable identity fixes that, with no Apple
# Developer account.
#
# This is NOT a distribution certificate. Shipping to another Mac needs a paid
# Developer ID certificate plus notarization.
set -euo pipefail

# shellcheck source=dev-identity.sh
source "$(dirname "$0")/dev-identity.sh"
NAME="$GCHAT_DEV_IDENTITY"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Identity '$NAME' already exists. Nothing to do."
    exit 0
fi

cat <<INTRO
This creates a self-signed code-signing certificate named "$NAME" in your login
keychain. You will be prompted:
  1. here, for confirmation
  2. by macOS, to authorise trusting the certificate
  3. here, for your macOS login password (so codesign can use the key without
     prompting on every build)
INTRO
read -r -p "Continue? [y/N] " reply
[[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Aborted."; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ext.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

echo "==> Generating key and certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/ext.cnf" 2>/dev/null

# A non-empty passphrase is required. macOS 'security import' fails PKCS#12 MAC
# verification on empty-password bundles. The passphrase is throwaway: the .p12
# lives only in a temp dir that is deleted on exit.
passphrase="$(openssl rand -hex 16)"

import_p12() {
    security import "$1" -k "$KEYCHAIN" -P "$passphrase" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1
}

echo "==> Importing into the login keychain"
# -legacy (RC2/3DES, SHA-1 MAC) is the historically compatible encoding for
# Apple's importer; modern AES is the fallback if it is unavailable.
if openssl pkcs12 -export -legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$NAME" -out "$tmp/identity.p12" -passout "pass:$passphrase" 2>/dev/null \
        && import_p12 "$tmp/identity.p12"; then
    echo "    imported (legacy encoding)"
elif openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -name "$NAME" -out "$tmp/identity.p12" -passout "pass:$passphrase" 2>/dev/null \
        && import_p12 "$tmp/identity.p12"; then
    echo "    imported (modern encoding)"
else
    echo "Import failed. Run with 'bash -x' to see the failing command." >&2
    exit 1
fi

echo "==> Trusting the certificate for code signing"
# User trust domain, so no sudo. macOS will ask you to authorise this.
if security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem" 2>/dev/null; then
    echo "    trusted"
else
    echo "    could not set trust automatically (see the note at the end)"
fi

echo "==> Allowing codesign to use the key without prompting"
# Without this, the key's ACL prompts on every signing operation, which is the
# whole problem this script exists to solve.
read -r -s -p "    macOS login password (not echoed, leave empty to skip): " login_password
echo
if [[ -n "$login_password" ]]; then
    if security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
            -k "$login_password" "$KEYCHAIN" >/dev/null 2>&1; then
        echo "    done"
    else
        echo "    failed — you may get one keychain prompt per build; re-run to retry"
    fi
    unset login_password
else
    echo "    skipped"
fi

echo
if security find-identity -v -p codesigning | grep "$NAME"; then
    echo
    echo "Success. scripts/build.sh will pick this identity up automatically."
else
    cat <<FIXUP

The certificate imported but is not yet a *valid* codesigning identity, which
means its trust setting did not apply. Fix it by hand:

  1. open -a "Keychain Access"
  2. Select the "login" keychain, category "Certificates"
  3. Double-click "$NAME" -> expand "Trust"
  4. Set "Code Signing" to "Always Trust", close the window, authenticate
  5. Re-check with:  security find-identity -v -p codesigning

Until then builds fall back to ad-hoc signing, which still works — you will just
get repeated Keychain prompts once tokens are stored.
FIXUP
fi
