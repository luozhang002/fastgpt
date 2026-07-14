#!/bin/bash
# 本机 Python 启动 bge-reranker-v2-m3
# 默认 CPU + 离线缓存，避免启动时访问 HuggingFace / MPS 把整机打满。
# 覆盖方式：RERANK_DEVICE=mps RERANK_FORCE_CPU=0 HF_HUB_OFFLINE=0 ./start-local-rerank.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="${ROOT}/rerank-service/.venv"
PID_FILE="${ROOT}/rerank-service/rerank.pid"
LOG_FILE="${ROOT}/rerank-service/rerank.log"

export ACCESS_TOKEN="${RERANK_ACCESS_TOKEN:-mytoken}"
export PORT="${RERANK_PORT:-6006}"
export HOST="${RERANK_HOST:-127.0.0.1}"
export RERANK_FORCE_CPU="${RERANK_FORCE_CPU:-1}"
export RERANK_DEVICE="${RERANK_DEVICE:-cpu}"
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
export TRANSFORMERS_OFFLINE="${TRANSFORMERS_OFFLINE:-1}"
export PYTHONUNBUFFERED=1

if [ -z "${RERANK_MODEL:-}" ]; then
  SNAP_ROOT="${HOME}/.cache/huggingface/hub/models--BAAI--bge-reranker-v2-m3/snapshots"
  if [ -d "${SNAP_ROOT}" ]; then
    RERANK_MODEL="$(find "${SNAP_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
  fi
fi
export RERANK_MODEL="${RERANK_MODEL:-BAAI/bge-reranker-v2-m3}"

if [ ! -d "${VENV}" ]; then
  echo "请先运行: ${ROOT}/install-local-rerank.sh"
  exit 1
fi

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Rerank 已在运行 (PID $(cat "${PID_FILE}"))，http://127.0.0.1:${PORT}/v1/rerank"
    exit 0
  fi
  kill "$(cat "${PID_FILE}")" 2>/dev/null || true
  rm -f "${PID_FILE}"
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"
cd "${ROOT}/rerank-service"
: > "${LOG_FILE}"
nohup python -u app.py >>"${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"
echo "启动中 (device=${RERANK_DEVICE})，日志: ${LOG_FILE}"

for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "Rerank 就绪: http://127.0.0.1:${PORT}/v1/rerank  Token: ${ACCESS_TOKEN}"
    exit 0
  fi
  if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "进程已退出，查看日志: tail -f ${LOG_FILE}"
    exit 1
  fi
  sleep 5
done

echo "超时，查看日志: tail -f ${LOG_FILE}"
exit 1
