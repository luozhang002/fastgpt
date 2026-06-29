#!/bin/bash
# 本机 Python 启动 bge-reranker-v2-m3（Mac MPS/CPU，比 Docker 镜像省磁盘）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="${ROOT}/rerank-service/.venv"
PID_FILE="${ROOT}/rerank-service/rerank.pid"
LOG_FILE="${ROOT}/rerank-service/rerank.log"
PY="${PY:-python3.12}"

export ACCESS_TOKEN="${RERANK_ACCESS_TOKEN:-mytoken}"
export PORT="${RERANK_PORT:-6006}"

if [ ! -d "${VENV}" ]; then
  echo "请先运行: ${ROOT}/install-local-rerank.sh"
  exit 1
fi

if [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  echo "Rerank 已在运行 (PID $(cat "${PID_FILE}"))，http://localhost:${PORT}/v1/rerank"
  exit 0
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"
cd "${ROOT}/rerank-service"
nohup python app.py >>"${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"
echo "启动中，模型首次加载约 1–3 分钟，日志: ${LOG_FILE}"

for _ in $(seq 1 60); do
  if curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; then
    echo "Rerank 就绪: http://localhost:${PORT}/v1/rerank  Token: ${ACCESS_TOKEN}"
    exit 0
  fi
  sleep 5
done

echo "超时，查看日志: tail -f ${LOG_FILE}"
exit 1
