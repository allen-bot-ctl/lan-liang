#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out=shots/menubar-v039
mkdir -p "$out"
pid=
cleanup() { if [[ -n "${pid:-}" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; pid=; }
trap cleanup EXIT
for appearance in light dark; do
  for mode in codex gemini both; do
    services="$mode"
    [[ "$mode" != both ]] || services=codex,gemini
    path="$out/$appearance-$mode"
    LANLIANG_FAKE="$PWD/fixtures/normal.json" "$bin" --debug-open-panel --debug-services="$services"       --debug-appearance="$appearance" >"$path.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 15); do
      grep -q '^DEBUG_MENUBAR_RENDER ' "$path.log" && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    cat "$path.log"
    rect=$(awk '/^DEBUG_RECT_ITEM /{r=$2} END{print r}' "$path.log")
    test -n "$rect"
    if [[ "$mode" = both ]]; then
      grep -q '^DEBUG_MENUBAR_RENDER font=9.5 ' "$path.log"
      grep -q ' rows=2 .* style=compact' "$path.log"
    else
      grep -q '^DEBUG_MENUBAR_RENDER font=12.0 .*noResize=1' "$path.log"
      grep -q ' rows=1 .* style=single' "$path.log"
    fi
    screencapture -x -R"$rect" "$path.png"
    test -s "$path.png"
    cleanup
  done
done
