#!/bin/bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
cd "$(dirname "$0")"
docker-compose down

# 停止本机 Python Rerank（若已安装）
if [ -x "$(dirname "$0")/stop-local-rerank.sh" ]; then
  "$(dirname "$0")/stop-local-rerank.sh" || true
fi

echo "FastGPT 已停止"
