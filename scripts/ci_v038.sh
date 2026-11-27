#!/usr/bin/env bash
# Native Gemini recovery states rendered from fixtures only.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
out="$PWD/shots/gemini-recovery"
mkdir -p "$out"
bin="build/${NAME}.app/Contents/MacOS/$NAME"
pid=
cleanup() { if [[ -n "${pid:-}" ]]; then kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; pid=; }
trap cleanup EXIT
python3 - fixtures/expired.json "$RUNNER_TEMP/gemini-service-failed.json" <<'PY'
import sys,json
with open(sys.argv[1]) as f: obj=json.load(f)
obj["codex"]["status"]="ok"
obj["gemini"]["status"]="fetchFailed"
with open(sys.argv[2],"w") as f: json.dump(obj,f)
PY
for item in "login-expired|$PWD/fixtures/expired.json" "keychain-unavailable|$PWD/fixtures/keychain-unavailable.json" "service-failed|$RUNNER_TEMP/gemini-service-failed.json"; do
    label=${item%%|*}; fixture=${item#*|}
    log="$out/$label.log"
    LANLIANG_FAKE="$fixture" "$bin" --debug-open-panel --debug-tab=gemini --debug-services=codex,gemini         --debug-appearance=light >"$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 15); do
        grep -q '^DEBUG_RECT_PANEL ' "$log" && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    cat "$log"
    rect=$(awk '/^DEBUG_RECT_PANEL /{r=$2} END{print r}' "$log")
    [[ "$(cut -d, -f3-4 <<<"$rect")" = "400,414" ]]
    screencapture -x -R"$rect" "$out/$label.png"
    test -s "$out/$label.png"
    cleanup
done
