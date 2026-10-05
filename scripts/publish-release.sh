#!/usr/bin/env bash
# Publish a release cut by scripts/release.sh: push its tag (and main, when
# main is that release), then create the GitHub Release with the app attached,
# and the signed appcast.xml that installed copies check for updates.
# Running this is the decision to publish.
#
#   ./scripts/publish-release.sh               # the release at HEAD
#   ./scripts/publish-release.sh v2026.41.1    # a named one
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
    echo "publish-release: $1" >&2
    exit 1
}

if [[ $# -gt 0 ]]; then
    tag=$1
elif ! tag=$(git describe --exact-match --match 'v*' HEAD 2>/dev/null); then
    fail "HEAD is not a release; name the tag"
fi
commit=$(git rev-parse -q --verify "refs/tags/$tag^{commit}") || fail "no tag $tag"
version=${tag#v}
zip=dist/Kibble-$version.zip

# The zip is built from the working tree, so check it is this release's.
[[ -f "$zip" ]] || fail "no $zip; check out $tag and run scripts/package.sh"
zipped=$(unzip -p "$zip" Kibble.app/Contents/Info.plist |
    plutil -extract CFBundleShortVersionString raw -) || fail "$zip holds no Kibble.app"
[[ "$zipped" == "$version" ]] || fail "$zip holds $zipped, not $version"

# Sparkle's tools come with its Swift package, which the app's build fetched.
# The private key is in the owner's login Keychain (CLAUDE.md, "Publishing").
bin=DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
[[ -x "$bin/sign_update" && -x "$bin/generate_keys" ]] ||
    fail "no Sparkle tools in $bin; build the app once (scripts/package.sh)"
# Installs verify an update against the public key they carry, so a zip
# signed with any other key could never be installed by anyone.
app_key=$(unzip -p "$zip" Kibble.app/Contents/Info.plist | plutil -extract SUPublicEDKey raw -) ||
    fail "$zip has no SUPublicEDKey"
keychain_key=$("$bin/generate_keys" -p 2>/dev/null) || fail "no Sparkle signing key in the login Keychain"
[[ "$keychain_key" == "$app_key" ]] || fail "the Keychain's signing key is not the one $zip trusts"

owner=$(gh repo view --json owner --jq .owner.login)
repo=$(gh repo view --json name --jq .name)
login=$(gh api user --jq .login)
[[ "$login" == "$owner" ]] || fail "gh is signed in as $login, not $owner"
if gh release view "$tag" >/dev/null 2>&1; then
    fail "$tag already has a GitHub Release"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
changes=$work/changes
notes=$work/notes
if previous=$(git describe --abbrev=0 --match 'v*' "$tag^" 2>/dev/null); then
    range="$previous..$tag"
else
    range=$tag
fi
git log --first-parent --format='%s' "$range" | grep -v '^release: ' >"$changes" ||
    echo "No changes besides the version." >"$changes"
{
    echo "## Changes"
    echo
    sed 's/^/- /' "$changes"
    echo
    echo "## Installing"
    echo
    echo "Requires macOS 26. Unzip, and drag Kibble into Applications in Finder."
    echo
    # One line per paragraph: GitHub can render a newline in release notes as a break.
    echo "Kibble is signed with a self-signed certificate and is not notarized, so macOS blocks it the first time. Open it once, then go to System Settings → Privacy & Security, click **Open Anyway**, and confirm with **Open**."
    echo
    echo "Kibble then updates itself (Settings → Updates). After each update, macOS asks once for your login password so Kibble can read its saved session: choose **Always Allow**."
} >"$notes"

# The appcast: one item, signed, uploaded beside the zip.
signature=$("$bin/sign_update" "$zip") || fail "sign_update failed"
[[ "$signature" == *'sparkle:edSignature="'* ]] || fail "sign_update printed no signature"
url="https://github.com/$owner/$repo/releases/download/$tag/Kibble-$version.zip"
./scripts/appcast.sh "$version" "$url" "$signature" "$changes" >"$work/appcast.xml"
xmllint --noout "$work/appcast.xml" || fail "the appcast is not valid XML"

if [[ "$(git rev-parse main)" == "$commit" ]]; then
    git push origin main "$tag"
else
    git push origin "$tag"
fi
gh release create "$tag" "$zip" "$work/appcast.xml" --verify-tag --title "Kibble $tag" --notes-file "$notes"
