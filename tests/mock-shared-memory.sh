#!/bin/bash
# Mock `shared-memory` for tests. Records each call and never touches Mnemopi.
#
#   MOCK_SM_LOG=<file>    append one JSON line per call: {tool, payload, cwd}
#   MOCK_SM_MODE=ok       print a stored result (default)
#   MOCK_SM_MODE=fail     print an error result and exit 1
#   MOCK_SM_MODE=garbage  exit 0 with output that is not JSON
#   MOCK_SM_MODE=nocontext  `context` fails; `call` is never reached
#
# `context --cwd DIR` answers {"retainBank":"bank-<basename DIR>"} and is not logged.

if [ "${1:-}" = "context" ]; then
  shift
  cwd=""
  while [ $# -gt 0 ]; do
    case $1 in
      --cwd) cwd=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  [ "${MOCK_SM_MODE:-ok}" = "nocontext" ] && { printf '{"status":"error"}\n'; exit 1; }
  jq -cn --arg b "bank-$(basename "$cwd")" '{retainBank:$b}'
  exit 0
fi

[ "${1:-}" = "call" ] || { echo "mock-shared-memory: unsupported: $*" >&2; exit 2; }
tool=$2
payload=$3
shift 3
cwd=""
while [ $# -gt 0 ]; do
  case $1 in
    --cwd) cwd=$2; shift 2 ;;
    *) shift ;;
  esac
done

n=1
if [ -n "${MOCK_SM_LOG:-}" ]; then
  [ -f "$MOCK_SM_LOG" ] && n=$(( $(wc -l < "$MOCK_SM_LOG") + 1 ))
  jq -cn --arg t "$tool" --argjson p "$payload" --arg c "$cwd" \
    '{tool:$t,payload:$p,cwd:$c}' >> "$MOCK_SM_LOG"
fi

case "${MOCK_SM_MODE:-ok}" in
  fail)    printf '{"status":"error","message":"mock failure"}\n'; exit 1 ;;
  garbage) echo "not json"; exit 0 ;;
  *)       printf '{"status":"stored","memory_id":"m%s"}\n' "$n" ;;
esac
