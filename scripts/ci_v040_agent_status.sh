#!/usr/bin/env bash
# 0.4.0 §5 B4 / 0.4.1 §C：应用自己建假会话目录，依次追加事件（Antigravity 用真实序列 fixture），
# 断言状态序列和闪烁只换图；自检打印结果后进程必须自己退出（ok = 0）。不读本机会话。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./project.env
bin="build/${NAME}.app/Contents/MacOS/$NAME"
out="$PWD/shots/v040"
mkdir -p "$out"
log="$out/agent-status.log"
LANLIANG_FAKE="$PWD/fixtures/normal.json" "$bin" --debug-agent-status --debug-services=codex,gemini \
  --debug-agent-fixture="$PWD/fixtures/agent-status/antigravity-real.jsonl" >"$log" 2>&1 &
pid=$!
exited=0
for _ in $(seq 1 150); do
  if ! kill -0 "$pid" 2>/dev/null; then exited=1; break; fi
  sleep 1
done
rc=0
if [ "$exited" = 1 ]; then
  wait "$pid" || rc=$?
else
  kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
fi
cat "$log"
line=$(grep '^DEBUG_AGENT_STATUS ' "$log" | tail -n 1 || true)
[[ "$line" == "DEBUG_AGENT_STATUS ok "* ]] || { echo "::error::会话状态序列没有通过: ${line:-没有输出}"; exit 1; }
[ "$exited" = 1 ] || { echo "::error::自检打印结果后进程没有自己退出"; exit 1; }
[ "$rc" = 0 ] || { echo "::error::自检 ok 但退出码是 $rc"; exit 1; }
if grep -q 'DEBUG_SECRET_MARKER' "$log"; then echo "::error::日志里出现了正文"; exit 1; fi
echo "RELEASE: ${line} exit=${rc}"
