#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
mkdir -p shots/model-distribution
pid=
cleanup() {
    if [[ -n "${pid:-}" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
for config in 'light daily' 'dark weekly' 'dark monthly' 'light monthly 2026-11-01'; do
    read -r ap range selected <<<"$config"
    name="shots/model-distribution/$ap-$range${selected:+-$selected}"
    LANLIANG_FAKE="$PWD/fixtures/model-distribution.json" "$bin" --debug-open-settings \
        --debug-appearance="$ap" --debug-summary-range="$range" --debug-services=codex,gemini \
        --debug-show-models --debug-summary-selection="$selected" >"$name.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 15); do
        grep -q '^DEBUG_RECT_PANEL ' "$name.log" && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    cat "$name.log"
    rect=$(awk '/^DEBUG_RECT_PANEL /{r=$2} END{print r}' "$name.log")
    [[ "$(cut -d, -f3-4 <<<"$rect")" = "400,414" ]]
    screencapture -x -R"$rect" "$name.png"
    test -s "$name.png"
    cleanup; pid=
done
