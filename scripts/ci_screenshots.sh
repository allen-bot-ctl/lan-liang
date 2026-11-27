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
  local w=0  # 最多等 15 秒，区域一出现就截
  while [ $w -lt 15 ]; do sleep 1; w=$((w+1)); grep -q "^DEBUG_RECT_PANEL" "$log" && break; done
  sleep 1
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
  "failed codex daily" "failed gemini" "expired codex daily" "expired gemini" "keychain-unavailable gemini"
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
# 0.3.0（契约 0.3.0 验收 2/3）：设置窗口（两个都开 / 只开 Codex 置灰加提示 / Codex 失败「不完整」/ 最长文案），
# 只开一个服务的菜单栏和面板（悬停一根柱子）；--debug-services 只覆盖本次启动，不写偏好。
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  nf="$PWD/fixtures/normal.json"
  LANLIANG_FAKE="$nf" shoot "-v030-settings-both-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-update=0.3.1
  LANLIANG_FAKE="$nf" shoot "-v030-settings-codex-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex
  LANLIANG_FAKE="$PWD/fixtures/official-failed.json" shoot "-v030-settings-incomplete-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini
  LANLIANG_FAKE="$PWD/fixtures/summary-longest.json" shoot "-v030-settings-longest-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini
  LANLIANG_FAKE="$nf" shoot "-v030-settings-loading-$ap" --debug-open-settings --debug-appearance=$ap --debug-loading
  LANLIANG_FAKE="$nf" shoot "-v030-both-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini --debug-tab=codex
  # 页签停在关掉的 Gemini 上，也要显示 Codex。
  LANLIANG_FAKE="$nf" shoot "-v030-single-codex-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex --debug-tab=gemini --debug-hover=auto
  LANLIANG_FAKE="$nf" shoot "-v030-single-gemini-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=gemini --debug-hover=auto
  LANLIANG_FAKE="$PWD/fixtures/longest.json" shoot "-v030-single-codex-longest-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex
  for t in both codex incomplete longest loading; do
    r=$(awk '/^DEBUG_RECT_PANEL/{print $2}' "/tmp/shots--v030-settings-$t-$ap.log" | tail -n 1)
    echo "RELEASE: settings $t $ap rect=$r"
    [ "$(cut -d, -f3 <<<"$r")" = 400 ] || { echo "::error::设置页面未沿用 400 点面板: $r"; exit 1; }
  done
done
# 0.3.1：消耗汇总里和面板同一个柱状图（两个都开堆叠、只开一个单色、Codex 失败只画 Gemini），悬停最高的柱子。
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  nf="$PWD/fixtures/normal.json"
  LANLIANG_FAKE="$nf" shoot "-v031-settings-stacked-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-hover=auto
  LANLIANG_FAKE="$nf" shoot "-v031-settings-stacked-monthly-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-summary-range=monthly
  # 四行气泡不超出图区：悬停最左、最右的柱子（契约 0.3.1 验收 3）。
  LANLIANG_FAKE="$nf" shoot "-v031-settings-hover-first-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-hover=first
  LANLIANG_FAKE="$nf" shoot "-v031-settings-hover-last-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-hover=last
  LANLIANG_FAKE="$nf" shoot "-v031-settings-gemini-only-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=gemini
  LANLIANG_FAKE="$nf" shoot "-v031-settings-single-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex --debug-hover=auto
  LANLIANG_FAKE="$PWD/fixtures/official-failed.json" shoot "-v031-settings-incomplete-$ap" --debug-open-settings --debug-appearance=$ap --debug-services=codex,gemini --debug-hover=auto
  for t in stacked stacked-monthly hover-first hover-last gemini-only single incomplete; do
    r=$(awk '/^DEBUG_RECT_PANEL/{print $2}' "/tmp/shots--v031-settings-$t-$ap.log" | tail -n 1)
    echo "RELEASE: settings v031 $t $ap rect=$r"
    [ "$(cut -d, -f3 <<<"$r")" = 400 ] || { echo "::error::设置页面未沿用 400 点面板: $r"; exit 1; }
  done
done
# 0.3.2：菜单栏三列（图标 | 周剩余 | 细竖线 | 5 小时橙色 /「--」灰色），不是模板图。
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  nf="$PWD/fixtures/normal.json"
  LANLIANG_FAKE="$nf" shoot "-v032-mb-both-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini
  LANLIANG_FAKE="$PWD/fixtures/codex-5h.json" shoot "-v032-mb-both-5h-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini
  LANLIANG_FAKE="$nf" shoot "-v032-mb-codex-no5h-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex
  LANLIANG_FAKE="$PWD/fixtures/codex-5h.json" shoot "-v032-mb-codex-5h-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex
  LANLIANG_FAKE="$nf" shoot "-v032-mb-gemini-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=gemini
  LANLIANG_FAKE="$PWD/fixtures/max.json" shoot "-v032-mb-max-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini
done
v032cells() {  # $1=用例 $2=应有的 cells
  for ap in dark light; do
    l=$(grep -h "^DEBUG_MENUBAR_CELLS" "/tmp/shots--$1-$ap.log" | tail -n 1)
    echo "RELEASE: v032 $1 $ap: $l | $(grep -h "^DEBUG_MENUBAR " "/tmp/shots--$1-$ap.log" | tail -n 1 | sed -E 's/.*(content=[^ ]+ item=[^ ]+).*/\1/')"
    [ "$(sed -E 's/.* cells=([^ ]+).*/\1/' <<<"$l")" = "$2" ] || { echo "::error::$1-$ap 菜单栏格子不对: $l（应为 $2）"; exit 1; }
    grep -q " template=0" <<<"$l" || { echo "::error::$1-$ap 菜单栏还是模板图: $l"; exit 1; }
  done
}
v032cells v032-mb-both 'codex:77%|--,gemini:44%|64'
v032cells v032-mb-codex-no5h 'codex:77%|--'
v032cells v032-mb-gemini 'gemini:44%|64'
v032cells v032-mb-codex-5h 'codex:77%|36'
v032cells v032-mb-max 'codex:100%|100,gemini:100%|100'
# 快速切换 20/21 次后（停在 Codex / Gemini），窗口四边不动，
# 两个页签都使用 400×414 pt；较小屏幕用调试上限验证滚动视口。
assert_panel_size() {
  local log="$1" height="$2" size
  size=$(awk '/^DEBUG_RECT_PANEL/{split($2, rect, ","); print rect[3] "," rect[4]}' "$log" | tail -n 1)
  [[ "$size" == "400,$height" ]] \
    || { echo "::error::主面板预期 400×${height}pt，实测 $size（$log）"; return 1; }
}
for ap in dark light; do
  if [ "$ap" = dark ]; then set_dark true; else set_dark false; fi
  for n in 20 21; do
    # 只有两个服务都开时才有页签可切（0.3.0）。
    LANLIANG_FAKE="$PWD/fixtures/normal.json" shoot "-tabflip-$n-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini --debug-tab=codex --debug-tab-flip=$n
    l=$(grep -h "^DEBUG_TABFLIP" "/tmp/shots--tabflip-$n-$ap.log" | tail -n 1)
    echo "RELEASE: tabflip $n $ap: $l"
    grep -q " topsUnique=1 " <<<"$l" && grep -q " mismatches=0$" <<<"$l" \
      || { echo "::error::切页签后面板顶边或内容错位: $l"; exit 1; }
    assert_panel_size "/tmp/shots--tabflip-$n-$ap.log" 414
  done
  # 内容超过高度上限时在面板里滚动（压低上限到 300pt）。
  LANLIANG_FAKE="$PWD/fixtures/normal.json" shoot "-scroll-capped-$ap" --debug-open-panel --debug-appearance=$ap --debug-services=codex,gemini --debug-tab=gemini --debug-max-height=300 --debug-tab-flip=20
  assert_panel_size "/tmp/shots--scroll-capped-$ap.log" 300
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
  l=$(grep -h "^DEBUG_MENUBAR " "/tmp/shots--stale-prefs-codex-daily-$ap.log" | tail -n 1)
  echo "RELEASE: stale-prefs $ap: $l"
  grep -q " visible=1 " <<<"$l" && grep -q " items=1 " <<<"$l" && grep -q " autosave=lanliang.main " <<<"$l" \
    || { echo "::error::带旧偏好启动后状态项不可见: $l"; exit 1; }
done
# 菜单栏：唯一一个状态项、每行文字、内容宽度（契约 0.1.2 §2/§3）。
mbline() { grep -h "^DEBUG_MENUBAR " "/tmp/shots--$1-$2.log" | tail -n 1; }
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
chk keychain-unavailable-gemini 'codex:77%,gemini:--' 2
chk low-codex-daily 'codex:8%+25,gemini:25%+64' 2
chk failed-gemini 'codex:77%,gemini:--' 2
# 0.3.0：只开一个服务 → 单行放大；两个都开 → 和 0.2.2 一样两行。
chk v030-both 'codex:77%,gemini:44%+64' 2
chk v030-single-codex 'codex:77%' 1
chk v030-single-gemini 'gemini:44%+64' 1
for c in v030-both:compact v030-single-codex:single v030-single-gemini:single normal-codex-daily:compact codex-only-codex-daily:single; do
  for ap in dark light; do
    l=$(mbline "${c%%:*}" "$ap")
    [ "$(field "$l" style)" = "${c##*:}" ] || { echo "::error::${c%%:*}-$ap 菜单栏样式不对: $l（应为 ${c##*:}）"; exit 1; }
  done
  echo "RELEASE: menubar ${c%%:*} style=${c##*:} content=$(field "$(mbline "${c%%:*}" dark)" content)pt"
done
lim() {  # $1=用例 $2=上限
  w=$(field "$(mbline "$1" dark)" content)
  echo "RELEASE: menubar content width $1=${w}pt (limit $2)"
  python3 -c "import sys; sys.exit(0 if float('$w') <= $2 else 1)" || { echo "::error::$1 菜单栏宽 ${w}pt 超过 $2pt"; exit 1; }
}
lim max-codex-daily 75
lim both-weekly-codex-daily 75   # 0.3.2：没有 5 小时也留第三列写「--」
# 状态项宽度（只打印）。
a=$(field "$(mbline low-codex-daily dark)" item); b=$(field "$(mbline max-codex-daily dark)" item); c=$(field "$(mbline codex-5h-codex-daily dark)" item)
echo "RELEASE: item width low=$a max=$b codex-5h=$c"
# 0.3.2（PM 04:52 定）：宽度按实际文字，位数变化时宽度跟着变，不再要求相同。
grep -h "^DEBUG_" /tmp/shots-*.log | sed 's/^/RELEASE: /'
ls -l shots
