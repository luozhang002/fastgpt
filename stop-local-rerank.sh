#!/bin/bash
# 停止本机 Python Rerank 服务
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="${ROOT}/rerank-service/rerank.pid"

if [ -f "${PID_FILE}" ]; then
  PID="$(cat "${PID_FILE}")"
  if kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}"
    echo "已停止 Rerank (PID ${PID})"
  fi
  rm -f "${PID_FILE}"
else
  pkill -f "${ROOT}/rerank-service/app.py" 2>/dev/null && echo "已停止 Rerank 进程" || echo "Rerank 未在运行"
fi
