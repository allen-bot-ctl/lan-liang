#!/usr/bin/env bash
# 带隐藏参数启动应用打开面板，应用打印截图区域（左上原点、点）；screencapture -R 裁剪并检查不是全黑。
# 每个模拟状态单独启动一次，截真实窗口。
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
  sleep 5
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

# 每个模拟状态启动一次应用，打开面板后真实截屏（菜单栏 + 面板），深浅两套；悬停取最高的柱子。
# 用法：shots/<名字>-<深浅>.png；名字 = 模拟数据-页签[-区间]
# 菜单栏跟随系统外观，所以要真的切换系统深浅色再截（应用内也同步 --debug-appearance）。
set_dark() {  # $1=true|false
  perl -e "alarm 30; exec @ARGV" osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" \
    || echo "::warning::切换系统深浅色失败"
  sleep 2
  echo "RELEASE: system_appearance=$(defaults read -g AppleInterfaceStyle 2>/dev/null || echo Light) (want dark=$1)"
}
CASES=(
  "normal codex daily" "normal codex weekly" "normal codex monthly" "normal gemini"
  "codex-5h codex daily" "low codex daily" "low gemini"
  "sub-lt1day codex daily" "sub-expired codex daily" "official-failed codex daily"
  "failed codex daily" "failed gemini" "expired codex daily" "expired gemini" "keychain-denied gemini"
  "both-weekly codex daily" "codex-only codex daily" "none codex daily"
)
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  for c in "${CASES[@]}"; do
    read -r fx tab range <<<"$c"
    name="$fx-$tab${range:+-$range}"
    LANLIANG_FAKE="$PWD/fixtures/$fx.json" shoot "-$name-$ap" --debug-open-panel --debug-appearance=$ap \
      --debug-tab=$tab ${range:+--debug-range=$range} --debug-hover=auto
  done
done
chk() { grep -h "^DEBUG_MENUBAR" "/tmp/shots--$1-dark.log" | grep -q "groups=$2\$" || { echo "::error::$1 菜单栏组不对"; exit 1; }; }
chk normal-codex-daily 'codex:77%,gemini:44%+64%'
chk both-weekly-codex-daily 'codex:77%,gemini:44%'
chk codex-only-codex-daily 'codex:77%'
chk none-codex-daily 'fallback'
chk codex-5h-codex-daily 'codex:77%+36%,gemini:44%+64%'
chk expired-codex-daily 'codex:--,gemini:--'
chk keychain-denied-gemini 'codex:77%'
chk low-codex-daily 'codex:8%+25%,gemini:25%+64%'
chk failed-gemini 'codex:77%,gemini:--'
grep -h "^DEBUG_" /tmp/shots-*.log | sed 's/^/RELEASE: /'
ls -l shots
