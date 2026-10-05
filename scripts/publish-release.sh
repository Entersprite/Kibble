#!/usr/bin/env bash
# Publish a release cut by scripts/release.sh: push its tag (and main, when
# main is that release), then create the GitHub Release with the app attached.
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

owner=$(gh repo view --json owner --jq .owner.login)
login=$(gh api user --jq .login)
[[ "$login" == "$owner" ]] || fail "gh is signed in as $login, not $owner"
if gh release view "$tag" >/dev/null 2>&1; then
    fail "$tag already has a GitHub Release"
fi

notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
    echo "## Changes"
    echo
    if previous=$(git describe --abbrev=0 --match 'v*' "$tag^" 2>/dev/null); then
        range="$previous..$tag"
    else
        range=$tag
    fi
    git log --first-parent --format='- %s' "$range" | grep -v '^- release: ' || echo "- No changes besides the version."
    echo
    echo "## Installing"
    echo
    echo "Requires macOS 26. Unzip, and move Kibble to Applications."
    echo
    # One line per paragraph: GitHub can render a newline in release notes as a break.
    echo "Kibble is signed with a self-signed certificate and is not notarized, so macOS blocks it the first time. Open it once, then go to System Settings → Privacy & Security, click **Open Anyway**, and confirm with **Open**."
} >"$notes"

if [[ "$(git rev-parse main)" == "$commit" ]]; then
    git push origin main "$tag"
else
    git push origin "$tag"
fi
gh release create "$tag" "$zip" --verify-tag --title "Kibble $tag" --notes-file "$notes"
