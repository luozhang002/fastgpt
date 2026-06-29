#!/bin/bash
# 配置硅基流动 Rerank 重排模型（知识库可选，提升检索精度）
# 用法: ./configure-rerank-siliconflow.sh <硅基流动API_KEY>
# 注册免费 Key: https://cloud.siliconflow.cn/account/ak

set -euo pipefail
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

if [ $# -lt 1 ]; then
  echo "用法: $0 <硅基流动API_KEY>"
  echo "免费注册: https://cloud.siliconflow.cn/account/ak"
  exit 1
fi

SF_KEY="$1"
RERANK_MODEL="BAAI/bge-reranker-v2-m3"
RERANK_URL="https://api.siliconflow.cn/v1/rerank"

echo "==> 测试硅基流动 Rerank API..."
curl -sf "${RERANK_URL}" \
  -H "Authorization: Bearer ${SF_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${RERANK_MODEL}\",
    \"query\": \"苹果\",
    \"documents\": [\"苹果派\", \"香蕉\"],
    \"top_n\": 2
  }" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('top score:', d['results'][0]['relevance_score'])
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
        provider: 'SiliconFlow',
        model: '${RERANK_MODEL}',
        name: 'bge-reranker-v2-m3 (硅基流动)',
        type: 'rerank',
        charsPointsPrice: 0,
        maxToken: 8192,
        requestUrl: '${RERANK_URL}',
        requestAuth: '${SF_KEY}'
      }
    }
  },
  { upsert: true }
);
"

echo ""
echo "完成！在知识库设置 → 重排模型 中选择「bge-reranker-v2-m3 (硅基流动)」。"
