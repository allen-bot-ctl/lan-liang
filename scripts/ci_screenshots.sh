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
  "codex-5h codex daily" "low codex daily" "low gemini" "max codex daily"
  "sub-rolled codex daily" "sub-lt1day codex daily" "sub-expired codex daily" "official-failed codex daily"
  "failed codex daily" "failed gemini" "expired codex daily" "expired gemini" "keychain-denied gemini"
  "both-weekly codex daily" "codex-only codex daily" "gemini-only gemini" "none codex daily"
  "normal gemini weekly" "gemini-partial gemini daily" "gemini-empty gemini daily" "gemini-none gemini daily"
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
# 0.2.0 新状态（契约 0.2.0 验收 2）：加载态、升级红点+气泡、刷新悬停、设置窗口。
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  nf="$PWD/fixtures/normal.json"
  LANLIANG_FAKE="$nf" shoot "-v020-loading-codex-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=codex --debug-loading
  LANLIANG_FAKE="$nf" shoot "-v020-loading-gemini-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=gemini --debug-loading
  LANLIANG_FAKE="$nf" shoot "-v020-update-dot-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=codex \
    --debug-update=0.2.1 --debug-hover-button=update
  LANLIANG_FAKE="$nf" shoot "-v020-refresh-hover-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=gemini \
    --debug-hover-button=refresh
  LANLIANG_FAKE="$PWD/fixtures/longest.json" shoot "-v020-longest-codex-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=codex
  LANLIANG_FAKE="$PWD/fixtures/longest.json" shoot "-v020-longest-gemini-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=gemini
  LANLIANG_FAKE="$PWD/fixtures/widest-tick.json" shoot "-v020-widest-tick-codex-$ap" --debug-open-panel --debug-appearance=$ap --debug-tab=codex --debug-hover=auto
  LANLIANG_FAKE="$nf" shoot "-v020-settings-$ap" --debug-open-settings --debug-appearance=$ap --debug-update=0.2.1
done
# 带旧偏好升级（契约 0.1.3 §1）：预置旧版本留下的 Item-0 隐藏偏好（以及新名字也被藏），启动后状态项必须可见。
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  defaults write "$BUNDLE_ID" "NSStatusItem Visible Item-0" -bool false
  defaults write "$BUNDLE_ID" "NSStatusItem Visible Item-1" -bool false
  defaults write "$BUNDLE_ID" "NSStatusItem Preferred Position Item-0" -float 300
  defaults write "$BUNDLE_ID" "NSStatusItem Visible lanliang.main" -bool false
  LANLIANG_FAKE="$PWD/fixtures/normal.json" shoot "-stale-prefs-codex-daily-$ap" --debug-open-panel --debug-appearance=$ap \
    --debug-tab=codex --debug-hover=auto
  if defaults read "$BUNDLE_ID" "NSStatusItem Visible Item-0" >/dev/null 2>&1; then
    echo "::error::启动后旧键 NSStatusItem Visible Item-0 还在"; exit 1
  fi
  l=$(grep -h "^DEBUG_MENUBAR" "/tmp/shots--stale-prefs-codex-daily-$ap.log" | tail -n 1)
  echo "RELEASE: stale-prefs $ap: $l"
  grep -q " visible=1 " <<<"$l" && grep -q " items=1 " <<<"$l" && grep -q " autosave=lanliang.main " <<<"$l" \
    || { echo "::error::带旧偏好启动后状态项不可见: $l"; exit 1; }
done
# 菜单栏：唯一一个状态项、每行文字、内容宽度（契约 0.1.2 §2/§3）。
mbline() { grep -h "^DEBUG_MENUBAR" "/tmp/shots--$1-$2.log" | tail -n 1; }
field() { sed -E "s/.* $2=([^ ]+).*/\1/" <<<"$1"; }
chk() {
  for ap in dark light; do
    l=$(mbline "$1" "$ap")
    [ -n "$l" ] || { echo "::error::$1-$ap 没有 DEBUG_MENUBAR"; exit 1; }
    [ "$(field "$l" items)" = 1 ] || { echo "::error::$1-$ap 状态项不是 1 个: $l"; exit 1; }
    [ "$(field "$l" visible)" = 1 ] || { echo "::error::$1-$ap 状态项不可见: $l"; exit 1; }
    [ "$(field "$l" groups)" = "$2" ] || { echo "::error::$1-$ap 菜单栏行不对: $l（应为 $2）"; exit 1; }
    [ "$(field "$l" rows)" = "$3" ] || { echo "::error::$1-$ap 行数不对: $l（应为 $3）"; exit 1; }
  done
}
chk normal-codex-daily 'codex:77%,gemini:44%+64' 2
chk both-weekly-codex-daily 'codex:77%,gemini:44%' 2
chk codex-only-codex-daily 'codex:77%' 1
chk gemini-only-gemini 'gemini:44%+64' 1
chk none-codex-daily 'fallback' 0
chk codex-5h-codex-daily 'codex:77%+36,gemini:44%+64' 2
chk max-codex-daily 'codex:100%+100,gemini:100%+100' 2
chk expired-codex-daily 'codex:--,gemini:--' 2
chk keychain-denied-gemini 'codex:77%' 1
chk low-codex-daily 'codex:8%+25,gemini:25%+64' 2
chk failed-gemini 'codex:77%,gemini:--' 2
lim() {  # $1=用例 $2=上限
  w=$(field "$(mbline "$1" dark)" content)
  echo "RELEASE: menubar content width $1=${w}pt (limit $2)"
  python3 -c "import sys; sys.exit(0 if float('$w') <= $2 else 1)" || { echo "::error::$1 菜单栏宽 ${w}pt 超过 $2pt"; exit 1; }
}
lim max-codex-daily 75
lim both-weekly-codex-daily 55
# 数字从 8% 变到 100% 宽度不跳：同样的列（两行都有 5 小时）宽度必须相同。
a=$(field "$(mbline low-codex-daily dark)" item); b=$(field "$(mbline max-codex-daily dark)" item); c=$(field "$(mbline codex-5h-codex-daily dark)" item)
echo "RELEASE: item width low=$a max=$b codex-5h=$c"
[ "$a" = "$b" ] && [ "$b" = "$c" ] || { echo "::error::数字变化时状态项宽度跳动"; exit 1; }
grep -h "^DEBUG_" /tmp/shots-*.log | sed 's/^/RELEASE: /'
ls -l shots
