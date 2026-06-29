#!/bin/bash
# FastGPT 本地启动脚本
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
cd "$(dirname "$0")"

if ! docker info >/dev/null 2>&1; then
  echo "Docker 未运行，正在启动 OrbStack..."
  open /Applications/OrbStack.app
  for i in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
fi

# 启动本机 Ollama（索引模型依赖）
if command -v ollama >/dev/null 2>&1; then
  brew services start ollama 2>/dev/null || true
fi

docker-compose up -d

# 本机 Rerank 服务（若已 install-local-rerank.sh）
if [ -x "$(dirname "$0")/start-local-rerank.sh" ] && [ -d "$(dirname "$0")/rerank-service/.venv" ]; then
  "$(dirname "$0")/start-local-rerank.sh" || true
fi

echo ""
echo "FastGPT: http://localhost:3000"
echo "账号: root / 密码: 1234"
echo "索引模型: bge-m3 (本机 Ollama)"
echo "重排模型: bge-reranker-v2-m3 (本机 :6006，若已安装)"
