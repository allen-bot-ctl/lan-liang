#!/usr/bin/env bash
# 校验 dist/appcast.xml：XML 合法、没有 releaseNotesLink、<description> 存在且非空。
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "${1:-dist/appcast.xml}" <<'PY'
import sys, xml.etree.ElementTree as ET
p = sys.argv[1]
raw = open(p, encoding="utf-8").read()
if "releaseNotesLink" in raw:
    sys.exit(f"::error::{p} 仍含 releaseNotesLink")
items = ET.parse(p).getroot().findall("./channel/item")
if not items:
    sys.exit(f"::error::{p} 没有 item")
for it in items:
    d = it.find("description")
    if d is None or not (d.text or "").strip():
        sys.exit(f"::error::{p} 的 item 缺少 <description> 或为空")
print(f"RELEASE: appcast ok items={len(items)} description_chars={len(items[0].find('description').text.strip())}")
PY
