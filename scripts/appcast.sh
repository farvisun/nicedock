#!/bin/sh
# Writes a one-item Sparkle appcast for a release.
# usage: scripts/appcast.sh <version> <build> <zip> <signature attrs from `sign_update`> > appcast.xml
set -eu
version="$1" build="$2" zip="$3" sig="$4"
repo="https://github.com/farvisun/nicedock"
cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NiceDock</title>
    <link>$repo</link>
    <item>
      <title>NiceDock $version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$repo/releases/tag/v$version</sparkle:releaseNotesLink>
      <enclosure url="$repo/releases/download/v$version/$(basename "$zip")" $sig type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
