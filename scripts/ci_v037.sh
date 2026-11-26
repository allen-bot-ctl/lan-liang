#!/usr/bin/env bash
# Native Intel interaction and render checks; never uses production account data.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out="$PWD/shots/v037"
mkdir -p "$out"
pid=
cleanup() { if [[ -n "${pid:-}" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; pid=; }
trap cleanup EXIT
wait_marker() {
    local marker="$1" log="$2"
    for _ in $(seq 1 18); do
        if grep -q "$marker" "$log"; then cat "$log"; return 0; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    cat "$log"; return 1
}
LANLIANG_FAKE="$PWD/fixtures/model-distribution.json" "$bin" --debug-hover-lifecycle >"$out/hover.log" 2>&1 &
pid=$!
wait_marker '^DEBUG_HOVER_LIFECYCLE ok ' "$out/hover.log"
cleanup
export_case() {
    local label="$1" range="$2" selection="$3" expected="$4"
    local dir="$out/$label" log="$out/$label.log"
    mkdir -p "$dir"
    LANLIANG_FAKE="$PWD/fixtures/model-distribution.json" TZ=UTC "$bin" --debug-open-settings         --debug-summary-range="$range" --debug-summary-selection="$selection"         --debug-usage-export-dir="$dir" >"$log" 2>&1 &
    pid=$!
    wait_marker "$expected" "$log"
    local pngs=("$dir"/*.png)
    [[ "${#pngs[@]}" == 1 && -s "${pngs[0]}" ]]
    sips -g format -g pixelWidth -g pixelHeight "${pngs[0]}" | tee "$dir/image-info.txt"
    grep -q 'format: png' "$dir/image-info.txt"
    grep -q 'pixelWidth: 1200' "$dir/image-info.txt"
    cleanup
}
export_case daily daily '' '^DEBUG_USAGE_EXPORT_OK .*bars=30 '
export_case november monthly '2026-11-01' '^DEBUG_USAGE_EXPORT_OK start=2026-11-01 end=2026-11-24 bars=1 '
