#!/bin/bash
# 本地索引模型：Ollama + bge-m3（知识库 Embedding）
# 前置：磁盘至少预留 3GB 空闲；Docker/OrbStack 正常运行
# 用法: ./configure-local-embedding.sh

set -euo pipefail
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

EMBED_MODEL="bge-m3"
OLLAMA_URL="http://host.docker.internal:11434"

echo "==> 检查 Docker..."
docker info >/dev/null

echo "==> 启动本机 Ollama..."
if ! curl -sf http://localhost:11434/ >/dev/null 2>&1; then
  brew services start ollama
  sleep 3
fi

echo "==> 拉取 ${EMBED_MODEL}（约 1.2GB，首次较慢）..."
ollama pull "${EMBED_MODEL}"

echo "==> 添加 Ollama 渠道 (AIProxy)..."
docker exec fastgpt-aiproxy curl -sf -X POST http://localhost:3000/api/channel/ \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"Ollama-Local\",
    \"type\": 30,
    \"models\": [\"${EMBED_MODEL}\"],
    \"base_url\": \"${OLLAMA_URL}\",
    \"key\": \"ollama\",
    \"status\": 1,
    \"priority\": 0
  }" >/dev/null

echo "==> 启用索引模型 ${EMBED_MODEL}..."
docker exec fastgpt-mongo mongosh "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin" --quiet --eval "
db.system_models.updateOne(
  { model: '${EMBED_MODEL}' },
  {
    \$set: {
      model: '${EMBED_MODEL}',
      metadata: {
        isCustom: true,
        isActive: true,
        provider: 'Ollama',
        model: '${EMBED_MODEL}',
        name: 'bge-m3 (本地)',
        type: 'embedding',
        charsPointsPrice: 0,
        defaultToken: 512,
        maxToken: 8192,
        normalization: false
      }
    }
  },
  { upsert: true }
);
"

echo "==> 测试 Embedding..."
docker exec fastgpt-aiproxy curl -sf http://localhost:3000/v1/embeddings \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"测试\"}" | head -c 150

echo ""
echo ""
echo "完成！刷新 http://localhost:3000/dataset/list 创建知识库。"
