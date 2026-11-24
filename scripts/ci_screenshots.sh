#!/usr/bin/env bash
# 带隐藏参数启动应用打开面板，应用打印截图区域（左上原点、点）；screencapture -R 裁剪并检查不是全黑。
# 另用 --debug-render 离屏渲染每个页签深浅两套 2x 图。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
mkdir -p shots

nonblack() {  # 全黑或全透明返回 1
  python3 - "$1" <<'PY'
import subprocess, sys, struct
p = sys.argv[1]; bmp = "/tmp/" + p.replace("/", "_") + ".bmp"
subprocess.run(["sips", "-s", "format", "bmp", p, "--out", bmp], check=True, capture_output=True)
d = open(bmp, "rb").read()
off = struct.unpack_from("<I", d, 10)[0]; w, h = struct.unpack_from("<ii", d, 18); bpp = struct.unpack_from("<H", d, 28)[0]
step = bpp // 8; row = ((w * bpp + 31) // 32) * 4
vals = set(); n = 0
for y in range(0, abs(h), max(1, abs(h) // 60)):
    for x in range(0, w, max(1, w // 60)):
        q = off + y * row + x * step; vals.add(tuple(d[q:q + 3])); n += 1
print(f"{p}: {w}x{abs(h)} colors={len(vals)}")
sys.exit(0 if len(vals) > 2 else 1)
PY
}

shoot() {  # $1=后缀  其余=启动参数
  local tag="$1"; shift
  local log="/tmp/shots-$tag.log"
  "$bin" "$@" >"$log" 2>&1 &
  local pid=$!
  sleep 6
  cat "$log"
  local mb it pn
  mb=$(awk '/^DEBUG_RECT_MENUBAR/{print $2}' "$log")
  it=$(awk '/^DEBUG_RECT_ITEM/{print $2}' "$log")
  pn=$(awk '/^DEBUG_RECT_PANEL/{print $2}' "$log")
  [ -n "$mb" ] && [ -n "$pn" ] && [ -n "$it" ] || { kill -TERM "$pid" || true; echo "::error::应用没有输出截图区域"; return 1; }
  screencapture -x "shots/full$tag.png"
  screencapture -x -R"$mb" "shots/menubar$tag.png"
  screencapture -x -R"$it" "shots/item$tag.png"
  screencapture -x -R"$pn" "shots/panel$tag.png"
  kill -TERM "$pid" 2>/dev/null || true; sleep 1; kill -KILL "$pid" 2>/dev/null || true
  for f in "shots/menubar$tag.png" "shots/panel$tag.png"; do
    nonblack "$f" || { echo "::error::$f 没有内容"; return 1; }
  done
}

"$bin" --debug-render="$PWD/shots/render" | tee /tmp/shots-render.log
n=$(ls shots/render/*.png | wc -l | tr -d ' ')
[ "$n" -ge 4 ] || { echo "::error::离屏渲染只有 $n 张"; exit 1; }
for f in shots/render/*.png; do nonblack "$f" || { echo "::error::$f 没有内容"; exit 1; }; done
shoot "" --debug-open-panel
shoot "-light" --debug-open-panel --debug-appearance=light
grep -h "^DEBUG_" /tmp/shots-*.log | sed 's/^/RELEASE: /'
ls -lR shots
