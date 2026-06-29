#!/bin/bash
# 安装并注册本机 bge-reranker-v2-m3（Python + MPS，适合磁盘不足无法拉 Docker 时）
set -euo pipefail

export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
ROOT="$(cd "$(dirname "$0")" && pwd)"
VENV="${ROOT}/rerank-service/.venv"
PY="${PY:-python3.12}"

RERANK_MODEL="bge-reranker-v2-m3"
RERANK_PORT="${RERANK_PORT:-6006}"
RERANK_TOKEN="${RERANK_ACCESS_TOKEN:-mytoken}"
RERANK_URL="http://host.docker.internal:${RERANK_PORT}/v1/rerank"

echo "==> 创建 Python 虚拟环境 (${PY})..."
if [ ! -d "${VENV}" ]; then
  "${PY}" -m venv "${VENV}"
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"
pip install -U pip wheel
pip install -r "${ROOT}/rerank-service/requirements.txt"

echo "==> 启动 Rerank 服务..."
"${ROOT}/start-local-rerank.sh"

echo "==> 测试 API..."
curl -sf "http://localhost:${RERANK_PORT}/v1/rerank" \
  -H "Authorization: Bearer ${RERANK_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${RERANK_MODEL}\",
    \"query\": \"苹果\",
    \"documents\": [\"苹果派\", \"香蕉\"],
    \"top_n\": 2
  }" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('top index:', d['results'][0]['index'], 'score:', round(d['results'][0]['relevance_score'], 4))
"

echo "==> 注册到 FastGPT..."
docker exec fastgpt-mongo mongosh "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin" --quiet --eval "
db.system_models.updateOne(
  { model: '${RERANK_MODEL}' },
  {
    \$set: {
      model: '${RERANK_MODEL}',
      metadata: {
        isCustom: true,
        isActive: true,
        provider: 'BGE',
        model: '${RERANK_MODEL}',
        name: 'bge-reranker-v2-m3 (本地)',
        type: 'rerank',
        charsPointsPrice: 0,
        maxToken: 8192,
        requestUrl: '${RERANK_URL}',
        requestAuth: '${RERANK_TOKEN}'
      }
    }
  },
  { upsert: true }
);
"

echo ""
echo "完成！知识库 → 重排模型 → 选「bge-reranker-v2-m3 (本地)」"
