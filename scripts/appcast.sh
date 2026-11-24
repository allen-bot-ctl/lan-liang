#!/usr/bin/env bash
# 用法：SPARKLE_ED_PRIVATE_KEY=... scripts/appcast.sh VERSION
# 用 Sparkle bin/sign_update 给 zip 签名（私钥只经 stdin 传入，不落盘、不回显），生成 dist/appcast.xml。
# 本地自测可设 SIGN_LINE='sparkle:edSignature="..." length="..."' 跳过 sign_update；
# DRY_RUN=1 用假签名生成（CI 推送预检用，不需要私钥）。
# 说明来自 release-notes/vVERSION.md（缺失时用 scripts/generic-notes.md.tpl），转成 HTML 嵌入 <description>。
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
VERSION="${1:?用法: scripts/appcast.sh VERSION}"; VERSION="${VERSION#v}"
# shellcheck disable=SC1091
source ./project.env
ZIP="dist/${NAME}-${VERSION}-mac-universal.zip"
[ -f "$ZIP" ] || { echo "::error::找不到 $ZIP"; exit 1; }

if [ "${DRY_RUN:-0}" = "1" ]; then
  SIGN_LINE="sparkle:edSignature=\"DRY-RUN-NOT-SIGNED\" length=\"$(wc -c < "$ZIP" | tr -d ' ')\""
fi
if [ -z "${SIGN_LINE:-}" ]; then
  [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || { echo "::error::缺少 SPARKLE_ED_PRIVATE_KEY"; exit 1; }
  SIGN_UPDATE="vendor/Sparkle-${SPARKLE_VERSION}/bin/sign_update"
  SIGN_LINE=$(printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")
fi
SIG=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGN_LINE")
LEN=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGN_LINE")
[ -n "$SIG" ] && [ -n "$LEN" ] || { echo "::error::sign_update 输出无法解析"; exit 1; }
ACTUAL=$(wc -c < "$ZIP" | tr -d ' ')
[ "$LEN" = "$ACTUAL" ] || { echo "::error::length $LEN != 实际 $ACTUAL"; exit 1; }

URL="https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/v${VERSION}/${NAME}-${VERSION}-mac-universal.zip"
NOTES_HTML=$(python3 scripts/notes.py html "$VERSION")
[ -n "$NOTES_HTML" ] || { echo "::error::发版说明为空"; exit 1; }
case "$NOTES_HTML" in *']]>'*) echo "::error::说明含 ]]>"; exit 1;; esac
PUBDATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${DISPLAY_NAME}</title>
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MACOS_MIN}</sparkle:minimumSystemVersion>
      <description><![CDATA[
${NOTES_HTML}
]]></description>
      <enclosure url="${URL}" sparkle:edSignature="${SIG}" length="${LEN}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
echo "appcast: v${VERSION} length=${LEN}"
