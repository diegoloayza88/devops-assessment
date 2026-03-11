import os
import logging
import time
import uuid
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
)
logger = logging.getLogger("qa-service")

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
VLLM_BASE_URL: str = os.environ.get("VLLM_BASE_URL", "http://vllm-service:8000")
VLLM_MODEL: str = os.environ.get("VLLM_MODEL", "HuggingFaceTB/SmolLM2-135M-Instruct")
MAX_NEW_TOKENS: int = int(os.environ.get("MAX_NEW_TOKENS", "512"))
TEMPERATURE: float = float(os.environ.get("TEMPERATURE", "0.7"))
REQUEST_TIMEOUT: float = float(os.environ.get("REQUEST_TIMEOUT", "60.0"))
APP_ENV: str = os.environ.get("APP_ENV", "production")

# ---------------------------------------------------------------------------
# Lifespan – warm-up health check against vLLM
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting QA service (env=%s)", APP_ENV)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(f"{VLLM_BASE_URL}/health")
            resp.raise_for_status()
            logger.info("vLLM health check passed")
    except Exception as exc:
        logger.warning("vLLM not reachable at startup: %s", exc)
    yield
    logger.info("QA service shutting down")

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(
    title="AI Question-Answering Service",
    description="REST API that forwards questions to a self-hosted vLLM instance.",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Middleware – request-id / latency logging
# ---------------------------------------------------------------------------
@app.middleware("http")
async def log_requests(request: Request, call_next):
    request_id = str(uuid.uuid4())[:8]
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = (time.perf_counter() - start) * 1000
    logger.info(
        "[%s] %s %s → %d  (%.1f ms)",
        request_id,
        request.method,
        request.url.path,
        response.status_code,
        elapsed,
    )
    response.headers["X-Request-ID"] = request_id
    return response

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------
class QuestionRequest(BaseModel):
    question: str = Field(
        ...,
        min_length=1,
        max_length=2000,
        description="The question to be answered by the LLM.",
        examples=["What is the capital of France?"],
    )

class AnswerResponse(BaseModel):
    question: str
    answer: str
    model: str
    latency_ms: float

class HealthResponse(BaseModel):
    status: str
    vllm_reachable: bool

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _build_prompt(question: str) -> str:
    """Wrap the question in the SmolLM2-Instruct chat template."""
    return (
        "<|im_start|>system\n"
        "You are a helpful AI assistant. Answer questions clearly and concisely.\n"
        "<|im_end|>\n"
        f"<|im_start|>user\n{question}\n<|im_end|>\n"
        "<|im_start|>assistant\n"
    )


async def _call_vllm(prompt: str) -> str:
    """Call the vLLM OpenAI-compatible completions endpoint."""
    payload = {
        "model": VLLM_MODEL,
        "prompt": prompt,
        "max_tokens": MAX_NEW_TOKENS,
        "temperature": TEMPERATURE,
        "stop": ["<|im_end|>", "<|im_start|>"],
    }
    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        resp = await client.post(
            f"{VLLM_BASE_URL}/v1/completions",
            json=payload,
        )
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["text"].strip()

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------
@app.get("/health", response_model=HealthResponse, tags=["ops"])
async def health_check():
    """Liveness / readiness probe."""
    vllm_ok = False
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{VLLM_BASE_URL}/health")
            vllm_ok = r.status_code == 200
    except Exception:
        pass
    return HealthResponse(status="ok", vllm_reachable=vllm_ok)


@app.post("/ask", response_model=AnswerResponse, tags=["qa"])
async def ask_question(body: QuestionRequest):
    """
    Accept a natural-language question and return an LLM-generated answer.

    - **question**: The question string (1–2000 characters).
    """
    logger.info("Received question (len=%d)", len(body.question))
    t0 = time.perf_counter()

    try:
        prompt = _build_prompt(body.question)
        answer = await _call_vllm(prompt)
    except httpx.TimeoutException:
        logger.error("vLLM request timed out")
        raise HTTPException(
            status_code=status.HTTP_504_GATEWAY_TIMEOUT,
            detail="LLM inference timed out. Please try again.",
        )
    except httpx.HTTPStatusError as exc:
        logger.error("vLLM returned HTTP %d: %s", exc.response.status_code, exc.response.text)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"LLM backend error: {exc.response.status_code}",
        )
    except Exception as exc:
        logger.exception("Unexpected error calling vLLM: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error",
        )

    latency = (time.perf_counter() - t0) * 1000
    logger.info("Answer generated in %.1f ms", latency)

    return AnswerResponse(
        question=body.question,
        answer=answer,
        model=VLLM_MODEL,
        latency_ms=round(latency, 2),
    )

# ---------------------------------------------------------------------------
# Global exception handler
# ---------------------------------------------------------------------------
@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled exception on %s: %s", request.url.path, exc)
    return JSONResponse(
        status_code=500,
        content={"detail": "An unexpected error occurred."},
    )