#!/bin/bash
# 配置硅基流动 Embedding 索引模型（知识库必需）
# 用法: ./configure-embedding.sh <硅基流动API_KEY>
# 注册免费 Key: https://cloud.siliconflow.cn/account/ak

set -euo pipefail
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

if [ $# -lt 1 ]; then
  echo "用法: $0 <硅基流动API_KEY>"
  echo "免费注册: https://cloud.siliconflow.cn/account/ak"
  exit 1
fi

SF_KEY="$1"
EMBED_MODEL="BAAI/bge-m3"

echo "==> 添加硅基流动渠道 (AIProxy)..."
docker exec fastgpt-aiproxy curl -sf -X POST http://localhost:3000/api/channel/ \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"SiliconFlow-Embedding\",
    \"type\": 43,
    \"models\": [\"${EMBED_MODEL}\"],
    \"base_url\": \"https://api.siliconflow.cn\",
    \"key\": \"${SF_KEY}\",
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
        provider: 'BAAI',
        model: '${EMBED_MODEL}',
        name: 'bge-m3',
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
RESULT=$(docker exec fastgpt-aiproxy curl -sf http://localhost:3000/v1/embeddings \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${EMBED_MODEL}\",\"input\":\"测试\"}" 2>&1 | head -c 200)
echo "$RESULT"

echo ""
echo "完成！刷新 http://localhost:3000/dataset/list 即可创建知识库。"
