"""
BGE Rerank API for FastGPT — POST /v1/rerank
Mac: MPS when available, else CPU.
"""
import os
from contextlib import asynccontextmanager
from typing import Any

import torch
import uvicorn
from fastapi import Depends, FastAPI, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field
from sentence_transformers import CrossEncoder

MODEL_NAME = os.environ.get("RERANK_MODEL", "BAAI/bge-reranker-v2-m3")
ACCESS_TOKEN = os.environ.get("ACCESS_TOKEN", "mytoken")
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "6006"))

reranker: CrossEncoder | None = None
security = HTTPBearer(auto_error=False)


def pick_device() -> str:
    if torch.backends.mps.is_available():
        return "mps"
    if torch.cuda.is_available():
        return "cuda"
    return "cpu"


@asynccontextmanager
async def lifespan(_: FastAPI):
    global reranker
    device = pick_device()
    print(f"Loading {MODEL_NAME} on {device}...")
    reranker = CrossEncoder(MODEL_NAME, device=device)
    print(f"Rerank ready at http://{HOST}:{PORT}/v1/rerank")
    yield


app = FastAPI(title="BGE Rerank", lifespan=lifespan)


class RerankRequest(BaseModel):
    model: str = Field(default=MODEL_NAME)
    query: str
    documents: list[str]
    top_n: int | None = None


def verify_token(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> None:
    if not ACCESS_TOKEN:
        return
    if credentials is None or credentials.credentials != ACCESS_TOKEN:
        raise HTTPException(status_code=403, detail="Invalid or missing token")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "model": MODEL_NAME}


@app.post("/v1/rerank")
async def rerank(body: RerankRequest, _: None = Depends(verify_token)) -> dict[str, Any]:
    if reranker is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    docs = [d.strip() for d in body.documents if d and d.strip()]
    if not docs:
        return {"results": []}

    pairs = [[body.query, doc] for doc in docs]
    raw_scores = reranker.predict(pairs)
    scores = [float(s) for s in raw_scores]

    indexed = sorted(enumerate(scores), key=lambda x: x[1], reverse=True)
    if body.top_n is not None:
        indexed = indexed[: body.top_n]

    results = [{"index": i, "relevance_score": s} for i, s in indexed]
    results.sort(key=lambda x: x["index"])
    return {"results": results}


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
