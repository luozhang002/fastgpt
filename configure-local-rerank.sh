#!/bin/bash
# 本地 BGE Rerank 重排模型（FastGPT 官方 Docker 镜像，CPU 可跑，Apple Silicon 较慢）
# 用法: ./configure-local-rerank.sh
#
# 注意：Ollama 虽有 bge-reranker 社区模型，但没有 /api/rerank 接口，不能给 FastGPT 用。
# 本脚本使用 FastGPT 官方 bge-rerank-v2-m3 镜像，暴露标准 /v1/rerank API。

set -euo pipefail
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

RERANK_CONTAINER="fastgpt-reranker"
RERANK_IMAGE="registry.cn-hangzhou.aliyuncs.com/fastgpt/bge-rerank-v2-m3:v0.1"
RERANK_MODEL="bge-reranker-v2-m3"
RERANK_PORT="${RERANK_PORT:-6006}"
RERANK_TOKEN="${RERANK_ACCESS_TOKEN:-mytoken}"
# FastGPT 跑在 Docker 里，访问宿主机 rerank 服务用 host.docker.internal
RERANK_URL="http://host.docker.internal:${RERANK_PORT}/v1/rerank"

echo "==> 检查 Docker..."
docker info >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "${RERANK_CONTAINER}"; then
  echo "==> 重启已有容器 ${RERANK_CONTAINER}..."
  docker start "${RERANK_CONTAINER}" >/dev/null 2>&1 || true
else
  echo "==> 拉取镜像 ${RERANK_IMAGE}（约 5GB，首次较慢）..."
  docker pull "${RERANK_IMAGE}"
  echo "==> 启动 Rerank 服务（端口 ${RERANK_PORT}）..."
  docker run -d \
    --name "${RERANK_CONTAINER}" \
    -p "${RERANK_PORT}:6006" \
    -e "ACCESS_TOKEN=${RERANK_TOKEN}" \
    --shm-size=2g \
    --restart unless-stopped \
    "${RERANK_IMAGE}"
fi

echo "==> 等待服务就绪..."
for _ in $(seq 1 30); do
  if curl -sf "http://localhost:${RERANK_PORT}/v1/rerank" \
    -H "Authorization: Bearer ${RERANK_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${RERANK_MODEL}\",\"query\":\"test\",\"documents\":[\"a\"]}" >/dev/null 2>&1; then
    break
  fi
  sleep 3
done

echo "==> 测试 Rerank API..."
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
print('top index:', d['results'][0]['index'], 'score:', d['results'][0]['relevance_score'])
"

echo "==> 注册重排模型到 FastGPT..."
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
echo "完成！在知识库设置 → 重排模型 中选择「bge-reranker-v2-m3 (本地)」。"
echo "Rerank 服务: http://localhost:${RERANK_PORT}/v1/rerank  Token: ${RERANK_TOKEN}"
