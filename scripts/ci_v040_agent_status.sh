#!/usr/bin/env bash
# 0.4.0 §5 B4：应用自己建假会话目录，依次追加事件，断言状态序列和闪烁只换图。不读本机会话。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out="$PWD/shots/v040"
mkdir -p "$out"
log="$out/agent-status.log"
LANLIANG_FAKE="$PWD/fixtures/normal.json" "$bin" --debug-agent-status --debug-services=codex,gemini >"$log" 2>&1 &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 120); do
  grep -q '^DEBUG_AGENT_STATUS ' "$log" && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
cat "$log"
line=$(grep '^DEBUG_AGENT_STATUS ' "$log" | tail -n 1 || true)
[[ "$line" == "DEBUG_AGENT_STATUS ok "* ]] || { echo "::error::会话状态序列没有通过: ${line:-没有输出}"; exit 1; }
if grep -q 'DEBUG_SECRET_MARKER' "$log"; then echo "::error::日志里出现了正文"; exit 1; fi
echo "RELEASE: ${line}"
