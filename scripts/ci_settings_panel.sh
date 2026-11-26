#!/usr/bin/env bash
# Focused hosted macOS verification; deliberately no full screenshot matrix.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
mkdir -p shots/settings-panel
pid=
cleanup() { if [[ -n "${pid:-}" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; }
trap cleanup EXIT
run_case() {
  local ap="$1" tab="$2" variant="$3" marker="$4" cap="${5:-414}"
  local log="shots/settings-panel/$ap-$tab-$variant-$cap.log"
  local args=("--debug-${variant}" "--debug-appearance=$ap" "--debug-tab=$tab" "--debug-services=codex,gemini")
  if [[ "$cap" != 414 ]]; then args+=("--debug-max-height=$cap"); fi
  LANLIANG_FAKE="$PWD/fixtures/normal.json" "$bin" "${args[@]}" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 15); do
    grep -q '^DEBUG_RECT_PANEL ' "$log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  cat "$log"
  grep -q "$marker" "$log"
  local rect size
  rect=$(awk '/^DEBUG_RECT_PANEL /{r=$2} END{print r}' "$log")
  size=$(cut -d, -f3-4 <<<"$rect")
  [[ "$size" = "400,$cap" ]] || { echo "::error::Unexpected settings panel size: $rect"; return 1; }
  if [[ "$variant" = open-settings ]]; then
    local shot="${log%.log}.png"
    screencapture -x -R"$rect" "$shot"
    test -s "$shot"
  fi
  cleanup
  pid=
}
for pair in 'light codex' 'dark gemini'; do
  read -r ap tab <<<"$pair"
  run_case "$ap" "$tab" open-settings '^DEBUG_RECT_PANEL '
  run_case "$ap" "$tab" settings-roundtrip "^DEBUG_SETTINGS_ROUNDTRIP ok tab=$tab "
done
run_case dark gemini settings-roundtrip '^DEBUG_SETTINGS_ROUNDTRIP ok tab=gemini ' 300
