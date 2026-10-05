#!/usr/bin/env bash
# Print a one-item Sparkle appcast for a release. publish-release.sh uploads
# it as appcast.xml beside the zip; the feed URL is .../releases/latest/
# download/appcast.xml, so one item - the newest - is all a feed needs.
#
#   scripts/appcast.sh VERSION ZIP_URL 'sparkle:edSignature="…" length="…"' NOTES_FILE
#
# NOTES_FILE holds one change per line, plain text.
set -euo pipefail

[[ $# -eq 4 ]] || {
    echo "usage: appcast.sh VERSION ZIP_URL SIGNATURE NOTES_FILE" >&2
    exit 2
}
version=$1 url=$2 signature=$3 notes=$4

# Escape for HTML and XML alike: & first, then < and >. With > escaped, no
# subject can close the CDATA section early.
escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

items=$(escape <"$notes" | sed -e 's|^|<li>|' -e 's|$|</li>|')
cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kibble</title>
    <item>
      <title>Kibble $(escape <<<"$version")</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>
$items
</ul>]]></description>
      <enclosure url="$url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF
