#!/usr/bin/env bash
# Cut a release, versioned vYEAR.WEEK.N: today's ISO 8601 week (2026-10-05 is
# 2026.41) and N, this week's releases counted from 0. Writes the version to
# Config/Base.xcconfig, builds the app into dist/ (scripts/package.sh), then
# commits on main and tags. Publishing is scripts/publish-release.sh.
#
#   ./scripts/release.sh                              # cut the next release
#   ./scripts/release.sh --dry-run                    # print it, change nothing
#   ./scripts/release.sh --dry-run --date 2027-01-01  # as if on that day
set -euo pipefail
cd "$(dirname "$0")/.."

dry_run=0
on_date=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --date)
            on_date="${2:?--date needs YYYY-MM-DD}"
            shift
            ;;
        *)
            echo "release: unknown argument $1" >&2
            exit 2
            ;;
    esac
    shift
done
if [[ -n "$on_date" && "$dry_run" -eq 0 ]]; then
    echo "release: --date only goes with --dry-run; a release is dated today" >&2
    exit 2
fi

# The ISO week-year, not the calendar year: 1 Jan 2027 is in week 53 of 2026,
# and a v2027.53 would sort after the v2027.1 that follows it.
if [[ -n "$on_date" ]]; then
    iso=$(date -j -f %Y-%m-%d "$on_date" +%G.%V)
else
    iso=$(date +%G.%V)
fi
year=${iso%.*}
week=$((10#${iso#*.})) # 2026.1.0, not 2026.01.0

# One past this week's highest tag, rather than a count of them, so a deleted
# tag can never hand out a version twice.
last=-1
while IFS= read -r tag; do
    n=${tag##*.}
    if [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n > last)); then
        last=$((10#$n))
    fi
done < <(git tag -l "v$year.$week.*")
version="$year.$week.$((last + 1))"

if [[ "$dry_run" -eq 1 ]]; then
    echo "v$version"
    exit 0
fi

if [[ "$(git symbolic-ref --short -q HEAD || true)" != "main" ]]; then
    echo "release: releases are cut on main" >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "release: the working tree has uncommitted changes" >&2
    exit 1
fi
if released=$(git describe --exact-match --match 'v*' HEAD 2>/dev/null); then
    echo "release: HEAD is already $released" >&2
    exit 1
fi

# CFBundleVersion takes the same three integers, and they only ever go up, so
# the build number needs no counter of its own.
xcconfig=Config/Base.xcconfig
sed -i '' -E \
    -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $version/" \
    -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = $version/" \
    "$xcconfig"
if [[ "$(grep -cxE "(MARKETING_VERSION|CURRENT_PROJECT_VERSION) = $version" "$xcconfig")" != 2 ]]; then
    git checkout -- "$xcconfig"
    echo "release: could not write the version into $xcconfig" >&2
    exit 1
fi

# A release always carries the app, so a build that fails leaves no commit and
# no tag behind.
if ! ./scripts/package.sh; then
    git checkout -- "$xcconfig"
    echo "release: packaging failed; nothing was committed or tagged" >&2
    exit 1
fi

git commit -q -m "release: v$version" -- "$xcconfig"
git tag -a "v$version" -m "Kibble v$version"

echo "Tagged v$version with dist/Kibble-$version.zip. Publish it with:"
echo "    ./scripts/publish-release.sh"
