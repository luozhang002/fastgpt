# macOS 本地搭建 FastGPT 完整指南

本文档记录在 macOS 上从零部署 FastGPT、配置 DeepSeek 对话模型、配置本地 Ollama 索引模型、可选配置 Rerank 重排模型的完整流程。适用于 Apple Silicon（M 系列）Mac。

**官方文档**：[https://doc.fastgpt.cn/zh-CN/docs/self-host/deploy/docker](https://doc.fastgpt.cn/zh-CN/docs/self-host/deploy/docker)

---

## 目录

1. [架构概览](#架构概览)
2. [环境要求](#环境要求)
3. [第一步：安装 Docker（OrbStack）](#第一步安装-dockerorbstack)
4. [第二步：下载部署配置](#第二步下载部署配置)
5. [第三步：修改配置并启动](#第三步修改配置并启动)
6. [第四步：首次登录](#第四步首次登录)
7. [第五步：配置 DeepSeek 语言模型](#第五步配置-deepseek-语言模型)
8. [第六步：配置本地索引模型（Ollama + bge-m3）](#第六步配置本地索引模型ollama--bge-m3)
9. [第七步（可选）：配置重排模型（Rerank）](#第七步可选配置重排模型rerank)
10. [第八步：创建知识库](#第八步创建知识库)
11. [日常运维](#日常运维)
12. [常见问题](#常见问题)
13. [服务账号与调用方式](#服务账号与调用方式)

---

## 架构概览

```
浏览器 (localhost:3000)
    │
    ▼
┌─────────────────────────────────────────────────────┐
│  FastGPT (Docker Compose)                           │
│  ├── fastgpt-app        主服务                      │
│  ├── fastgpt-aiproxy    模型聚合（渠道管理）        │
│  ├── fastgpt-mongo      业务数据                    │
│  ├── fastgpt-pg         向量存储 (PgVector)         │
│  ├── fastgpt-minio      对象存储 (S3)               │
│  └── fastgpt-redis      缓存/队列                   │
└─────────────────────────────────────────────────────┘
    │                              │
    ▼                              ▼
DeepSeek API (云端)          本机 macOS 进程（非 Docker）
deepseek-chat                ├── Ollama :11434  → bge-m3 (Embedding)
deepseek-reasoner            └── Python :6006   → bge-reranker-v2-m3 (Rerank, 可选)
```

**模型分工：**

| 类型 | 用途 | 是否必需 | 本环境已部署 |
|------|------|---------|-------------|
| 语言模型 (LLM) | 对话、问答 | ✅ 必需 | DeepSeek API |
| 索引模型 (Embedding) | 知识库向量化 | ✅ 必需 | 本机 Ollama `bge-m3` |
| 重排模型 (Rerank) | 向量召回后再精排，减少误命中 | ⭕ 可选 | **本机 Python `bge-reranker-v2-m3`（非 Docker）** |

> DeepSeek **不提供** Embedding API，知识库必须单独配置索引模型。  
> **Ollama 不能用于 Rerank**：社区虽有 `bge-reranker-v2-m3` 等模型可 `ollama pull`，但 Ollama **没有** `/api/rerank` 接口（见 [第七步](#第七步可选配置重排模型rerank)）。

### 本环境部署一览（当前）

| 组件 | 运行方式 | 说明 |
|------|---------|------|
| FastGPT 全家桶 | **Docker Compose** | `docker-compose.yml`，端口 3000 |
| Ollama `bge-m3` | **本机 brew 服务** | `brew services start ollama` |
| Rerank `bge-reranker-v2-m3` | **本机 Python + MPS** | `rerank-service/`，端口 6006，**不是** Docker 容器 |

Rerank 未用 Docker 的原因：官方镜像约 **5GB**，磁盘不足时 `docker pull` 会报 `no space left on device`；Python 方案模型约 **1GB**，与 Apple Silicon 更匹配。

---

## 环境要求

| 项目 | 最低要求 | 推荐 |
|------|---------|------|
| 系统 | macOS 12+ | macOS 14+ |
| 芯片 | Apple Silicon / Intel | Apple Silicon |
| 内存 | 8 GB | 16 GB+ |
| 磁盘 | **至少 15 GB 空闲** | 20 GB+ |
| 网络 | 可访问阿里云镜像、DeepSeek API | — |

**磁盘说明**：FastGPT 全套镜像约 10 GB，Ollama `bge-m3` 约 1.2 GB。磁盘满会导致 Docker/Ollama 拉取失败或镜像损坏。

---

## 第一步：安装 Docker（OrbStack）

macOS 推荐使用 [OrbStack](https://orbstack.dev/) 替代 Docker Desktop，更轻量。

```bash
brew install --cask orbstack
```

安装后打开 OrbStack，确认 Docker 可用：

```bash
# OrbStack 的 docker 不在默认 PATH，需加入 ~/.zshrc
echo 'export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"' >> ~/.zshrc
source ~/.zshrc

docker -v          # Docker version 29.x
docker-compose -v  # Docker Compose version v5.x
```

> 若 `docker` 命令找不到，先 `open /Applications/OrbStack.app` 等待 VM 启动完成。

---

## 第二步：下载部署配置

所有文件统一放在 `workspace/fastgpt/`（`~/fastgpt` 为指向该目录的软链，两个路径等价）：

```bash
cd workspace/fastgpt   # 或 cd workspace/fastgpt
```

**不要**从 `doc.fastgpt.cn/deploy/docker/cn/docker-compose.pg.yml` 直接 curl——该 URL 会返回 HTML 页面而非 YAML 文件。

正确做法：从 FastGPT GitHub 仓库获取 v4.14 正式版配置：

```bash
# 稀疏克隆，只拉部署文件
cd /tmp
git clone --depth 1 --filter=blob:none --sparse https://github.com/labring/FastGPT.git
cd FastGPT
git sparse-checkout set document/public/deploy/docker/v4.14/cn projects/app/data

# 复制到部署目录
cp document/public/deploy/docker/v4.14/cn/docker-compose.pg.yml workspace/fastgpt/docker-compose.yml
cp projects/app/data/config.json workspace/fastgpt/config.json
```

文件说明：

| 文件 | 作用 |
|------|------|
| `docker-compose.yml` | 全部服务定义（PgVector 版，适合个人/小团队） |
| `config.json` | FastGPT 业务配置（知识库线程数、PDF 解析等） |

---

## 第三步：修改配置并启动

### 3.1 修改存储地址

编辑 `workspace/fastgpt/docker-compose.yml`，找到 `STORAGE_EXTERNAL_ENDPOINT`，改为**本机局域网 IP**（不能用 `localhost` 或 `127.0.0.1`，容器内无法访问）：

```bash
# 查看本机 IP
ipconfig getifaddr en0
# 示例输出：10.10.12.72
```

```yaml
STORAGE_EXTERNAL_ENDPOINT: http://10.10.12.72:9000
```

### 3.2 可选：修改默认密码

```yaml
x-default-root-psw: &x-default-root-psw '你的密码'
```

默认 `1234`，每次容器重启会重置 root 用户密码为此值。

### 3.3 拉取镜像并启动

```bash
cd workspace/fastgpt

# 预拉 OpenSandbox 依赖镜像
docker-compose --profile prepull pull \
  opensandbox-agent-sandbox-image \
  opensandbox-execd-image \
  opensandbox-egress-image

# 启动全部服务（约 12 个容器，首次需 5–15 分钟）
docker-compose up -d
```

### 3.4 确认服务状态

```bash
docker-compose ps
```

所有容器应为 `Up` 且核心服务 `healthy`：

```
fastgpt-app          Up
fastgpt-aiproxy      Up (healthy)
fastgpt-mongo        Up (healthy)
fastgpt-pg           Up (healthy)
fastgpt-minio        Up (healthy)
fastgpt-redis        Up (healthy)
...
```

访问：**http://localhost:3000**

---

## 第四步：首次登录

| 项目 | 值 |
|------|-----|
| 地址 | http://localhost:3000 |
| 用户名 | `root` |
| 密码 | `docker-compose.yml` 中 `DEFAULT_ROOT_PSW`（默认 `1234`） |

登录后若提示未配置模型，属正常，按下面步骤配置即可。

**v4.14+ 还需安装系统插件**（插件市场在线安装，或下载 `.pkg` 导入）。

---

## 第五步：配置 DeepSeek 语言模型

### 5.1 获取 API Key

1. 注册 [DeepSeek 开放平台](https://platform.deepseek.com/)
2. 创建 API Key（`sk-` 开头）

### 5.2 方式 A：页面配置（推荐）

1. 进入 **账号 → 模型提供商 → 模型渠道**
2. 点击 **新增渠道**，填写：

| 字段 | 值 |
|------|-----|
| 渠道名 | `DeepSeek` |
| 协议类型 | `DeepSeek` |
| 模型 | `deepseek-chat`、`deepseek-reasoner` |
| 代理地址 | `https://api.deepseek.com` |
| API 密钥 | 你的 DeepSeek Key |

3. 点击 **模型测试**，确认绿色通过
4. 进入 **模型配置** 标签页，启用 `deepseek-chat` 和 `deepseek-reasoner`

### 5.3 方式 B：命令行配置（AIProxy API）

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

docker exec fastgpt-aiproxy curl -s -X POST http://localhost:3000/api/channel/ \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "DeepSeek",
    "type": 36,
    "models": ["deepseek-chat", "deepseek-reasoner"],
    "base_url": "https://api.deepseek.com",
    "key": "sk-你的DeepSeek密钥",
    "status": 1,
    "priority": 0
  }'
```

然后在 **模型配置** 页面启用对应模型，或通过 MongoDB 启用：

```bash
docker exec fastgpt-mongo mongosh \
  "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin" \
  --quiet --eval '
    db.system_models.updateOne({model:"deepseek-chat"}, {$set: {"metadata.isActive": true, "metadata.type": "llm"}});
    db.system_models.updateOne({model:"deepseek-reasoner"}, {$set: {"metadata.isActive": true, "metadata.type": "llm"}});
  '
```

### 5.4 模型说明

| 模型 ID | 说明 |
|---------|------|
| `deepseek-chat` | 普通对话（实际路由到 DeepSeek V4 Flash） |
| `deepseek-reasoner` | 思考/推理模式 |

### 5.5 验证

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/v1/chat/completions \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{"model":"deepseek-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
```

返回含 `"content"` 字段即成功。

---

## 第六步：配置本地索引模型（Ollama + bge-m3）

知识库需要 Embedding 模型。本方案使用**本机 Ollama**（非 Docker 版 Ollama，Docker 版在 ARM Mac 上易出现 `llama-server binary not found`）。

### 6.1 安装 Ollama

```bash
brew install ollama
brew services start ollama

# 验证
curl http://localhost:11434/
# 输出：Ollama is running
```

### 6.2 拉取 bge-m3 模型

```bash
ollama pull bge-m3   # 约 1.2 GB，首次较慢
ollama list          # 确认 bge-m3 在列表中
```

### 6.3 配置 FastGPT 渠道

**方式 A：一键脚本**

```bash
workspace/fastgpt/configure-local-embedding.sh
```

**方式 B：页面配置**

1. **账号 → 模型配置 → 新增模型 → 索引模型**
   - 模型 ID：`bge-m3`
   - 启用：开

2. **账号 → 模型渠道 → 新增渠道**

| 字段 | 值 |
|------|-----|
| 渠道名 | `Ollama-Local` |
| 协议类型 | `Ollama` |
| 模型 | `bge-m3` |
| 代理地址 | `http://host.docker.internal:11434` |
| API 密钥 | 任意（如 `ollama`） |

> **关键**：FastGPT 跑在 Docker 里，必须用 `host.docker.internal` 访问宿主机 Ollama，**不能用 `localhost`**。

**方式 C：命令行**

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

# 添加 Ollama 渠道（type=30 为 Ollama 协议）
docker exec fastgpt-aiproxy curl -s -X POST http://localhost:3000/api/channel/ \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Ollama-Local",
    "type": 30,
    "models": ["bge-m3"],
    "base_url": "http://host.docker.internal:11434",
    "key": "ollama",
    "status": 1,
    "priority": 0
  }'

# 启用索引模型
docker exec fastgpt-mongo mongosh \
  "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin" \
  --quiet --eval '
db.system_models.updateOne(
  { model: "bge-m3" },
  { $set: {
      model: "bge-m3",
      metadata: {
        isCustom: true, isActive: true, provider: "Ollama",
        model: "bge-m3", name: "bge-m3 (本地)", type: "embedding",
        charsPointsPrice: 0, defaultToken: 512, maxToken: 8192,
        normalization: false
      }
    }
  },
  { upsert: true }
);
'
```

### 6.4 验证 Embedding

```bash
# 本机直接测
curl -s http://localhost:11434/api/embed \
  -d '{"model":"bge-m3","input":"测试"}' | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['embeddings'][0]))"
# 期望：dim: 1024

# 经 AIProxy 测
docker exec fastgpt-aiproxy curl -s http://localhost:3000/v1/embeddings \
  -H "Authorization: Bearer token" \
  -H "Content-Type: application/json" \
  -d '{"model":"bge-m3","input":"测试知识库"}' | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
# 期望：dim: 1024
```

---

## 第七步（可选）：配置重排模型（Rerank）

### 7.1 什么是 Rerank

知识库检索流程：**Embedding 向量召回** →（可选）**Rerank 重排** → 送入 LLM。

向量相似度有时会误命中（例如不同表格里都有「业绩」字样）。Rerank 用交叉编码器对「问题 + 候选片段」重新打分，通常能提升准确率。

### 7.2 开源模型有哪些

| 模型 | 参数量 | 特点 | 与 bge-m3 搭配 |
|------|--------|------|----------------|
| **bge-reranker-v2-m3** | ~0.5B | 多语言、轻量，FastGPT 官方推荐 | ✅ 最佳（同 BAAI 系列） |
| bge-reranker-base | ~0.3B | 更小，中英 | ✅ |
| bge-reranker-large | ~0.5B | 中英，比 base 略强 | ✅ |
| Qwen3-Reranker-0.6B/4B/8B | 0.6B–8B | 多语言，大模型更强但更吃资源 | 可用 vLLM 部署 |

HuggingFace 地址：[bge-reranker-v2-m3](https://huggingface.co/BAAI/bge-reranker-v2-m3)

### 7.3 Ollama 能装 Rerank 吗？

**能 pull，不能给 FastGPT 用。**

Ollama 库里有社区转换的 rerank 模型，例如：

```bash
# 可以下载，但 FastGPT 无法当 Rerank 用
ollama pull qllama/bge-reranker-v2-m3
ollama pull dengcao/Qwen3-Reranker-8B:Q4_K_M
```

这些模型在 Ollama 里走的是 **`/api/embed`**（当 embedding 用），**没有** `/api/rerank`：

```bash
curl -s http://localhost:11434/api/rerank -d '{"model":"test"}'
# 404 page not found
```

FastGPT 重排需要标准 **`POST /v1/rerank`**（请求体含 `query` + `documents[]`，返回 `relevance_score`）。因此：

| 方式 | 能否用于 FastGPT Rerank |
|------|------------------------|
| Ollama pull rerank 模型 | ❌ 无 rerank API |
| **本机 Python + MPS（Mac 默认）** | ✅ **当前环境用法** |
| FastGPT 官方 BGE Docker | ✅ 需磁盘 ≥8GB 空闲 |
| 硅基流动等云端 Rerank API | ✅ 最省事 |
| vLLM / TEI / Xinference | ✅ 需自行部署 |

### 7.4 方案 A：本地 bge-reranker-v2-m3（当前已安装）

> **本环境状态**：已通过 `install-local-rerank.sh` 安装完成，运行方式为 **宿主机 Python 进程**，FastGPT 模型名 **bge-reranker-v2-m3 (本地)**。无 `fastgpt-reranker` Docker 容器。

#### A1. Python + MPS（**Mac 推荐 / 当前方案**）

| 项目 | 值 |
|------|-----|
| 模型 | `BAAI/bge-reranker-v2-m3` |
| 推理设备 | Apple MPS（无 GPU 则 CPU） |
| API | `http://localhost:6006/v1/rerank` |
| Token | `mytoken`（`RERANK_ACCESS_TOKEN` 可改） |
| FastGPT requestUrl | `http://host.docker.internal:6006/v1/rerank` |
| 代码目录 | `rerank-service/`（`sentence-transformers` + FastAPI） |
| 日志 | `rerank-service/rerank.log` |
| PID 文件 | `rerank-service/rerank.pid` |

**首次安装：**

```bash
workspace/fastgpt/install-local-rerank.sh
```

完成：创建 `rerank-service/.venv`、下载 HuggingFace 模型、启动服务、写入 FastGPT Mongo。

**日常启停：**

```bash
workspace/fastgpt/start-local-rerank.sh   # 只启 Rerank
workspace/fastgpt/stop-local-rerank.sh    # 只停 Rerank
workspace/fastgpt/start.sh                # FastGPT + Ollama + Rerank（检测到 .venv 时自动启 Rerank）
workspace/fastgpt/stop.sh                 # 停 FastGPT + Rerank
```

**健康检查：**

```bash
curl -s http://localhost:6006/health
# {"status":"ok","model":"BAAI/bge-reranker-v2-m3"}
```

**Rerank 推理测试：**

```bash
curl -s http://localhost:6006/v1/rerank \
  -H 'Authorization: Bearer mytoken' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bge-reranker-v2-m3",
    "query": "2024年业绩",
    "documents": [
      "2024年公司业绩同比增长15%",
      "员工食堂菜单"
    ],
    "top_n": 2
  }' | python3 -m json.tool
```

期望：与「业绩」相关文档的 `relevance_score` 明显高于无关文档（实测约 `0.97` vs `0.00002`）。

**从 FastGPT 容器内验证（确认 `host.docker.internal` 可达）：**

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
docker exec fastgpt-app curl -sf http://host.docker.internal:6006/health
```

**在 FastGPT 页面使用：**

1. **账号 → 模型配置** 中应已有 **bge-reranker-v2-m3 (本地)**（脚本已注册）
2. 知识库 **设置 → 重排模型** → 选择该项并保存

手动添加时字段：

| 字段 | 值 |
|------|-----|
| 模型 ID | `bge-reranker-v2-m3` |
| 请求地址 | `http://host.docker.internal:6006/v1/rerank` |
| 请求 Token | `mytoken` |

#### A2. Docker 官方镜像（备选，非当前环境）

磁盘至少 **8GB 空闲** 时再试；镜像约 5GB。

```bash
workspace/fastgpt/configure-local-rerank.sh
```

会拉取 `registry.cn-hangzhou.aliyuncs.com/fastgpt/bge-rerank-v2-m3:v0.1` 并启动容器 `fastgpt-reranker`。

**手动 Docker：**

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"

docker run -d \
  --name fastgpt-reranker \
  -p 6006:6006 \
  -e ACCESS_TOKEN=mytoken \
  --shm-size=2g \
  --restart unless-stopped \
  registry.cn-hangzhou.aliyuncs.com/fastgpt/bge-rerank-v2-m3:v0.1
```

> 官方 Docker 文档：[接入 bge-rerank 重排模型](https://doc.fastgpt.io/zh-CN/self-host/custom-models/bge-rerank)

### 7.5 方案 B：硅基流动云端（免本地算力）

```bash
workspace/fastgpt/configure-rerank-siliconflow.sh sk-你的硅基流动Key
```

等价 curl：

```bash
curl -s https://api.siliconflow.cn/v1/rerank \
  -H "Authorization: Bearer sk-你的Key" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "BAAI/bge-reranker-v2-m3",
    "query": "苹果",
    "documents": ["苹果派", "香蕉"],
    "top_n": 2
  }'
```

### 7.6 Docker 镜像选型对照（仅方案 A2 使用）

| Docker 镜像 | 模型 ID | 体积 | 适用 |
|-------------|---------|------|------|
| `bge-rerank-base:v0.1` | `bge-reranker-base` | ~4GB | 资源紧张 |
| `bge-rerank-large:v0.1` | `bge-reranker-large` | ~5GB | 中英场景 |
| `bge-rerank-v2-m3:v0.1` | `bge-reranker-v2-m3` | ~5GB | **多语言，推荐** |

---

## 第八步：创建知识库

1. 打开 http://localhost:3000/dataset/list
2. 点击 **新建知识库**
3. 索引模型选择 **bge-m3 (本地)**
4. **（推荐）** 重排模型选择 **bge-reranker-v2-m3 (本地)**（本机 Python，非 Docker）
5. 上传文档（PDF、Word、TXT、Markdown 等）
6. 等待索引完成（进度可在知识库详情查看）
7. 创建 **应用**，关联知识库，对话模型选 `deepseek-chat`

若仍提示「未配置索引模型」，刷新页面；确认 **模型配置** 中 `bge-m3` 已启用且渠道测试通过。

---

## 日常运维

### 目录结构

```
workspace/fastgpt/              # 唯一管理目录（配置、脚本、文档）
├── README.md                   # 本文档
├── docker-compose.yml          # 服务编排（实际运行用这份）
├── config.json                 # FastGPT 业务配置
├── start.sh                    # 一键启动（含 Ollama + Rerank）
├── stop.sh                     # 一键停止（含 Rerank）
├── stop-local-rerank.sh        # 仅停 Python Rerank
├── configure-local-embedding.sh
├── configure-embedding.sh
├── configure-local-rerank.sh      # Docker 版 Rerank（备选）
├── configure-rerank-siliconflow.sh
├── install-local-rerank.sh        # Python 版 Rerank 首次安装（当前环境）
├── start-local-rerank.sh
└── rerank-service/                # Python Rerank 服务
    ├── app.py
    ├── requirements.txt
    ├── .venv/                     # 虚拟环境（install 后生成）
    ├── rerank.log
    └── rerank.pid

~/fastgpt/                      # 建议软链到 workspace/fastgpt（见下方说明）
```

**推荐**：让 `~/fastgpt` 指向 `workspace/fastgpt`，两个路径等价：

```bash
rm -rf ~/fastgpt   # 若已是旧目录，先备份数据卷不受影响
ln -sfn "$(pwd)/workspace/fastgpt" ~/fastgpt
```

未建软链时，改配置后需同步：`cp workspace/fastgpt/{docker-compose.yml,config.json} ~/fastgpt/`

### 启动

```bash
workspace/fastgpt/start.sh
```

自动完成：启动 OrbStack → 启动 Ollama → `docker-compose up -d` → 若存在 `rerank-service/.venv` 则启动 Python Rerank

### 停止

```bash
workspace/fastgpt/stop.sh
```

停止 FastGPT Compose 栈，并尝试停止本机 Python Rerank。

### Rerank 单独运维

```bash
workspace/fastgpt/start-local-rerank.sh
workspace/fastgpt/stop-local-rerank.sh
tail -f workspace/fastgpt/rerank-service/rerank.log
```

确认 Rerank 在跑：

```bash
curl -s http://localhost:6006/health
docker ps --filter name=fastgpt-reranker   # 应为空（当前非 Docker 部署）
ps aux | grep rerank-service/app.py        # 应有 Python 进程
```

### 查看日志

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
docker logs fastgpt-app --tail 50
docker logs fastgpt-aiproxy --tail 50
```

### 更新版本

```bash
# 1. 备份数据卷
docker run --rm -v fastgpt_mongo_data:/data -v $(pwd):/backup alpine \
  tar czf /backup/mongo-backup.tar.gz /data

# 2. 修改 docker-compose.yml 中 fastgpt-app 的 image tag
# 3. 重新拉取并启动
cd workspace/fastgpt && docker-compose pull && docker-compose up -d
```

参考官方升级文档，避免跨大版本升级。

---

## 常见问题

### 1. 磁盘空间不足

**现象**：`no space left on device`、OrbStack 无法启动、镜像拉取失败。

**处理**：

```bash
brew cleanup -s                          # 清理 Homebrew 缓存（可释放 ~1 GB）
docker system prune -a                   # 清理无用镜像（谨慎，会删未用镜像）
rm -rf ~/Library/Caches/Homebrew/downloads/*
```

至少保留 **5 GB** 空闲再继续部署。Rerank **Docker 镜像约 5GB**，磁盘不足时请用 `install-local-rerank.sh`（Python 方案，约 1GB 模型）。

### 2. Rerank Docker 镜像拉取失败

**现象**：`docker pull ... bge-rerank-v2-m3` 报 `no space left on device` 或解压失败。

**处理**：改用 Python 方案（当前环境做法）：

```bash
workspace/fastgpt/install-local-rerank.sh
```

无需 `fastgpt-reranker` 容器；API 同为 `localhost:6006/v1/rerank`。

### 3. `doc.fastgpt.cn` 下载到的是 HTML

官方文档站的 compose 下载链接会 302 到 HTML 页面。务必从 GitHub 仓库获取：

```
https://github.com/labring/FastGPT/tree/main/document/public/deploy/docker/v4.14/cn
```

### 4. Mongo 容器网络冲突

**现象**：`endpoint with name fastgpt-mongo already exists in network fastgpt_data`

**处理**：

```bash
cd workspace/fastgpt && docker-compose down
docker network disconnect -f fastgpt_data fastgpt-mongo
docker network rm fastgpt_data
docker-compose up -d
```

### 5. 知识库提示「未配置索引模型」

- DeepSeek 只有对话模型，必须单独配 Embedding
- 确认 `bge-m3` 在 **模型配置** 中已启用（`type: embedding`）
- 确认 Ollama 渠道地址为 `http://host.docker.internal:11434`

### 6. Docker 版 Ollama 报 `llama-server binary not found`

ARM Mac 上 Docker 版 Ollama 镜像可能损坏或不兼容。**改用本机 brew 安装**：

```bash
brew install ollama
brew services start ollama
```

### 7. DeepSeek 认证失败

**现象**：`Authentication Fails, Your api key is invalid`

- 到 [DeepSeek 平台](https://platform.deepseek.com/) 检查 Key 是否有效、有余额
- 在 **模型渠道 → DeepSeek → 编辑** 更新 Key

### 8. S3 / 文件上传 403

`STORAGE_EXTERNAL_ENDPOINT` 不能填 `localhost`，必须填宿主机局域网 IP：

```bash
ipconfig getifaddr en0
# 填入 docker-compose.yml 的 STORAGE_EXTERNAL_ENDPOINT
```

### 9. `docker` 命令找不到

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
# 或写入 ~/.zshrc 永久生效
```

### 10. AIProxy 渠道 type 报错 `invalid channel type`

不同版本 AIProxy 的协议 ID 不同。查询当前版本支持的类型：

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/swagger/doc.json | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for n,v in zip(d['definitions']['model.ChannelType']['x-enum-varnames'],
               d['definitions']['model.ChannelType']['enum']):
    if 'Deep' in n or 'Ollama' in n or 'Silicon' in n:
        print(v, n)
"
# DeepSeek = 36, Ollama = 30, Siliconflow = 43
```

### 11. Ollama 添加 Rerank 模型报 404

Ollama **不支持** `/api/rerank`。即使 `ollama pull qllama/bge-reranker-v2-m3` 成功，FastGPT 重排仍会失败。

**处理**：改用 [第七步](#第七步可选配置重排模型rerank) 的 Docker 或硅基流动方案，不要用 Ollama 渠道配 Rerank。

### 12. Rerank 服务 403

FastGPT 里配置的 **请求 Token** 必须与 Rerank 容器环境变量 `ACCESS_TOKEN` 一致（默认 `mytoken`）。

---

## 备选：云端索引模型（硅基流动）

若不想本地跑 Ollama，可用硅基流动免费 Embedding：

1. 注册 https://cloud.siliconflow.cn ，获取 API Key
2. 运行：

```bash
workspace/fastgpt/configure-embedding.sh sk-你的硅基流动Key
```

模型为 `BAAI/bge-m3`，数据会发送到云端。

Rerank 重排同理，运行：

```bash
workspace/fastgpt/configure-rerank-siliconflow.sh sk-你的硅基流动Key
```

---

## 服务账号与调用方式

以下账号密码均来自 `docker-compose.yml` 默认值。修改 compose 后需同步更新本节。

**终端前置**（OrbStack 的 `docker` 不在默认 PATH）：

```bash
export PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
```

### 端口与账号速查

| 服务 | 容器名 | 宿主机端口 | 账号 | 密码 / Token | 能否从本机直接访问 |
|------|--------|-----------|------|--------------|-------------------|
| FastGPT 主服务 | `fastgpt-app` | 3000 | `root` | `1234`（`DEFAULT_ROOT_PSW`） | ✅ Web + API |
| AIProxy | `fastgpt-aiproxy` | — | — | `token`（`ADMIN_KEY`） | ❌ 仅容器内 / `docker exec` |
| MCP Server | `fastgpt-mcp-server` | 3003 | — | — | ✅ HTTP（无 Web 登录） |
| MinIO API | `fastgpt-minio` | 9000 | `minioadmin` | `minioadmin` | ✅ S3 API |
| MinIO 控制台 | `fastgpt-minio` | 9001 | `minioadmin` | `minioadmin` | ✅ 浏览器 |
| MongoDB | `fastgpt-mongo` | — | `myusername` | `mypassword` | ❌ 仅容器内 |
| Redis | `fastgpt-redis` | — | `default` | `mypassword` | ❌ 仅容器内 |
| PgVector（向量库） | `fastgpt-pg` | — | `username` | `password` | ❌ 仅容器内 |
| AIProxy PG | `fastgpt-aiproxy-pg` | — | `postgres` | `aiproxy` | ❌ 仅容器内 |
| Ollama | 本机进程 | 11434 | — | 无 | ✅ HTTP |
| BGE Rerank | 本机 Python 进程 | 6006 | — | `mytoken`（`ACCESS_TOKEN`） | ✅ `/v1/rerank`（**非 Docker**） |
| Plugin | `fastgpt-plugin` | — | — | `token` | ❌ 仅容器内 |
| Code Sandbox | `fastgpt-code-sandbox` | — | — | `codesandbox` | ❌ 仅容器内 |

**内部 Token（compose 顶部 `x-*` 变量，服务间鉴权用）**

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `x-system-key` | `fastgpt-xxx` | FastGPT `ROOT_KEY`（最高权限） |
| `x-plugin-auth-token` | `token` | Plugin `AUTH_TOKEN` |
| `x-code-sandbox-token` | `codesandbox` | 代码沙箱 `SANDBOX_TOKEN` |
| `x-aiproxy-token` | `token` | AIProxy `ADMIN_KEY` / FastGPT `AIPROXY_API_TOKEN` |
| `x-volume-manager-auth-token` | `vmtoken` | Agent 卷管理 |

---

### 1. FastGPT 主服务（`localhost:3000`）

#### Web 登录

| 项目 | 值 |
|------|-----|
| 地址 | http://localhost:3000 |
| 用户名 | `root` |
| 密码 | `1234`（改 `x-default-root-psw` 后重启容器生效） |

#### OpenAPI 文档

```bash
curl -s http://localhost:3000/api/openapi.json | python3 -m json.tool | head
```

浏览器也可直接打开上述 URL。

#### 应用对话 API（最常用）

**必须用应用级 API Key**（应用 → API 访问 → 新建），**不能用账号 Key**。

```bash
export FASTGPT_APP_KEY="fastgpt-你的应用Key"

# 非流式
curl -s -X POST 'http://localhost:3000/api/v1/chat/completions' \
  -H "Authorization: Bearer $FASTGPT_APP_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "chatId": "cli-test-001",
    "stream": false,
    "detail": false,
    "messages": [
      {"role": "user", "content": "你好"}
    ]
  }'
```

只看回复正文（需 `jq`）：

```bash
curl -s -X POST 'http://localhost:3000/api/v1/chat/completions' \
  -H "Authorization: Bearer $FASTGPT_APP_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"chatId":"cli-001","stream":false,"messages":[{"role":"user","content":"你好"}]}' \
  | jq -r '.choices[0].message.content'
```

流式输出（SSE，不要用 `jq` 解析整段响应）：

```bash
curl -N -X POST 'http://localhost:3000/api/v1/chat/completions' \
  -H "Authorization: Bearer $FASTGPT_APP_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "chatId": "cli-stream-001",
    "stream": true,
    "messages": [
      {"role": "user", "content": "用三句话介绍 FastGPT"}
    ]
  }'
```

**Key 类型区别**

| Key 类型 | 获取位置 | 能否调对话 API |
|---------|---------|---------------|
| 账号 Key | 账号设置 → API Key | ❌ 返回 `You need to use the app key` |
| **应用 Key** | **应用 → API 访问** | ✅ |

对接 OpenAI 兼容客户端时：`BaseURL = http://localhost:3000/api`，`API Key = 应用 Key`。

---

### 2. AIProxy（模型聚合，`fastgpt-aiproxy`）

未映射宿主机端口，需在容器内或通过 `docker exec` 调用。Admin Token 为 compose 中的 `token`。

#### 健康检查

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/api/status
```

#### 测试 LLM 渠道（OpenAI 兼容）

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/v1/chat/completions \
  -H 'Authorization: Bearer token' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "deepseek-chat",
    "messages": [{"role": "user", "content": "say ok"}],
    "max_tokens": 10
  }'
```

#### 测试 Embedding 渠道

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/v1/embeddings \
  -H 'Authorization: Bearer token' \
  -H 'Content-Type: application/json' \
  -d '{"model":"bge-m3","input":"测试知识库"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['data'][0]['embedding']))"
```

#### 新增模型渠道（示例：DeepSeek）

```bash
docker exec fastgpt-aiproxy curl -s -X POST http://localhost:3000/api/channel/ \
  -H 'Authorization: Bearer token' \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "DeepSeek",
    "type": 36,
    "models": ["deepseek-chat", "deepseek-reasoner"],
    "base_url": "https://api.deepseek.com",
    "key": "sk-你的DeepSeek密钥",
    "status": 1,
    "priority": 0
  }'
```

#### 查询支持的渠道 type

```bash
docker exec fastgpt-aiproxy curl -s http://localhost:3000/swagger/doc.json | \
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for n,v in zip(d['definitions']['model.ChannelType']['x-enum-varnames'],
               d['definitions']['model.ChannelType']['enum']):
    if 'Deep' in n or 'Ollama' in n or 'Silicon' in n:
        print(v, n)
"
# DeepSeek=36, Ollama=30, Siliconflow=43
```

---

### 3. MinIO 对象存储（`localhost:9000` / `9001`）

FastGPT 上传的文件存在 MinIO bucket：`fastgpt-public`、`fastgpt-private`。

#### Web 控制台

- 地址：http://localhost:9001
- 账号：`minioadmin` / `minioadmin`

#### 健康检查

```bash
curl -s http://localhost:9000/minio/health/live
# 空响应 + HTTP 200 即正常
```

#### 命令行列出 bucket（容器内 mc）

```bash
docker exec fastgpt-minio mc alias set local http://localhost:9000 minioadmin minioadmin
docker exec fastgpt-minio mc ls local/
```

#### S3 API（宿主机 curl 示例）

```bash
curl -s http://localhost:9000/fastgpt-public/
# 未签名访问可能 403，属正常；应用通过 compose 内 STORAGE_* 变量鉴权
```

> `STORAGE_EXTERNAL_ENDPOINT` 必须填宿主机局域网 IP（如 `http://10.10.x.x:9000`），不能填 `localhost`，否则容器内上传/预览会失败。

---

### 4. MongoDB（`fastgpt-mongo`）

连接串（容器内）：

```
mongodb://myusername:mypassword@fastgpt-mongo:27017/fastgpt?authSource=admin
```

#### 进入 shell

```bash
docker exec -it fastgpt-mongo mongosh \
  "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin"
```

#### 查看已启用模型

```bash
docker exec fastgpt-mongo mongosh \
  "mongodb://myusername:mypassword@localhost:27017/fastgpt?authSource=admin" \
  --quiet --eval 'db.system_models.find({ "metadata.isActive": true }, { model: 1, "metadata.type": 1 }).toArray()'
```

---

### 5. Redis（`fastgpt-redis`）

连接串（容器内）：`redis://default:mypassword@fastgpt-redis:6379`

```bash
# Ping
docker exec fastgpt-redis redis-cli -a mypassword ping

# 查看 key 数量（调试用）
docker exec fastgpt-redis redis-cli -a mypassword DBSIZE
```

---

### 6. PgVector 向量库（`fastgpt-pg`）

连接串（容器内）：`postgresql://username:password@fastgpt-vector:5432/postgres`

```bash
# 就绪检查
docker exec fastgpt-pg pg_isready -U username -d postgres

# 进入 psql
docker exec -it fastgpt-pg psql -U username -d postgres

# 查看向量表（示例）
docker exec fastgpt-pg psql -U username -d postgres -c "\dt"
```

> 首次启动后改 `POSTGRES_PASSWORD` **不会**自动生效，需删 volume `fastgpt-pg` 后重建。

---

### 7. AIProxy PostgreSQL（`fastgpt-aiproxy-pg`）

连接串（容器内）：`postgres://postgres:aiproxy@fastgpt-aiproxy-pg:5432/aiproxy`

```bash
docker exec fastgpt-aiproxy-pg pg_isready -U postgres -d aiproxy

docker exec -it fastgpt-aiproxy-pg psql -U postgres -d aiproxy -c "SELECT COUNT(*) FROM channels;"
```

---

### 8. Ollama（本机 `localhost:11434`）

```bash
# 存活
curl -s http://localhost:11434/

# 列出模型
curl -s http://localhost:11434/api/tags | python3 -m json.tool

# Embedding（本机直连）
curl -s http://localhost:11434/api/embed \
  -d '{"model":"bge-m3","input":"测试"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('dim:', len(d['embeddings'][0]))"
```

FastGPT 容器访问 Ollama 必须用 `http://host.docker.internal:11434`，不能用 `localhost`。

---

### 9. BGE Rerank 重排服务（`localhost:6006`，本机 Python）

**当前环境**：`install-local-rerank.sh` 安装的 **宿主机 Python 服务**，不是 `fastgpt-reranker` Docker 容器。

```bash
# 健康检查
curl -s http://localhost:6006/health

# 推理
curl -s http://localhost:6006/v1/rerank \
  -H 'Authorization: Bearer mytoken' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "bge-reranker-v2-m3",
    "query": "测试",
    "documents": ["相关文档", "无关内容"]
  }' | python3 -m json.tool

# 启停
workspace/fastgpt/start-local-rerank.sh
workspace/fastgpt/stop-local-rerank.sh
tail -f workspace/fastgpt/rerank-service/rerank.log
```

| 项目 | 值 |
|------|-----|
| 运行方式 | 本机 Python（`rerank-service/app.py` + MPS） |
| API | `POST http://localhost:6006/v1/rerank` |
| Token | `Authorization: Bearer mytoken` |
| FastGPT requestUrl | `http://host.docker.internal:6006/v1/rerank` |
| FastGPT 模型名 | `bge-reranker-v2-m3 (本地)` |
| Docker 备选 | `configure-local-rerank.sh` → 容器 `fastgpt-reranker`（需 ≥8GB 磁盘） |

---

### 10. MCP Server（`localhost:3003`）

MCP 服务映射宿主机 **3003**，供外部 MCP 客户端连接 FastGPT 应用，无独立 Web 登录。

```bash
# 探测端口（具体路径依客户端/SDK 而定）
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3003/
```

配置 MCP 客户端时，Endpoint 填 `http://localhost:3003`（或部署域名对应端口）。详见 [FastGPT MCP 文档](https://doc.fastgpt.cn/)。

---

### 11. 其它内部服务（一般不需手动调用）

| 服务 | 健康检查 |
|------|---------|
| Plugin | `docker exec fastgpt-plugin curl -sf http://localhost:3000/health` |
| Code Sandbox | `docker exec fastgpt-code-sandbox bun -e "fetch('http://localhost:3000/health').then(r=>console.log(r.status))"` |
| OpenSandbox | `docker exec fastgpt-opensandbox-server python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8090/health').status)"` |
| Volume Manager | `docker exec fastgpt-volume-manager bun -e "fetch('http://localhost:3000/health').then(r=>console.log(r.status))"` |

---

## 参考链接

- [FastGPT 官方文档](https://doc.fastgpt.cn/)
- [FastGPT GitHub](https://github.com/labring/FastGPT)
- [DeepSeek API 文档](https://api-docs.deepseek.com/zh-cn/)
- [Ollama 模型库](https://ollama.com/library/bge-m3)
- [OrbStack](https://orbstack.dev/)

---

*文档版本：2026-06-29 | FastGPT v4.14.26 | macOS Apple Silicon | Rerank: Python+MPS（非 Docker）*
