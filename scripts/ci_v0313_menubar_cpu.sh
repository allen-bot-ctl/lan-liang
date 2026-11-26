#!/usr/bin/env bash
# Native Intel status item; real AppKit process/CPU, fake quota, no personal data.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
[[ "$(uname -m)" == x86_64 ]]
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out="$PWD/shots/v0313"
mkdir -p "$out"
pid=
cleanup() {
    if [[ -n "${pid:-}" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
    fi
}
trap cleanup EXIT
test_case() {
    local rows="$1" services="$2" appearance="$3"
    local log="$out/cpu-$rows.log"
    LANLIANG_FAKE="$PWD/fixtures/normal.json" "$bin" --debug-menubar-render \
        --debug-services="$services" --debug-appearance="$appearance" >"$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 30); do
        if grep -q '^DEBUG_MENUBAR_RENDER ' "$log"; then break; fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    cat "$log"
    grep -Eq "^DEBUG_MENUBAR_RENDER ok rows=$rows bitmap=true idleStable=true burstStable=true appearance=true rasters=1 installs=1 widths=0 idleCPU=[0-9.]+% burstCPU=[0-9.]+%" "$log"
    cleanup
}
test_case 1 gemini light
test_case 2 codex,gemini dark
