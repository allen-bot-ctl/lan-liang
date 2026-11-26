#!/usr/bin/env bash
# Native, isolated fixture; never reads personal Antigravity history or quota.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
[[ "$(uname -m)" == x86_64 ]]
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out="$PWD/shots/v0312"
mkdir -p "$out"
log="$out/history-lifecycle.log"
LANLIANG_FAKE="$PWD/fixtures/model-distribution.json" "$bin" \
    --debug-history-lifecycle --debug-services=gemini --debug-tab=gemini >"$log" 2>&1 &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 18); do
    if grep -q '^DEBUG_HISTORY_LIFECYCLE ok startup=0 automatic=0 foreground=1 hidden=1 preview=true pinned=true$' "$log"; then
        cat "$log"
        exit 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
done
cat "$log"
exit 1
