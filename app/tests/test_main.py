"""
Unit and integration tests for the QA FastAPI service.

The vLLM backend is mocked with httpx.MockTransport so these tests run
fully in isolation — no real LLM or network call is made.
"""

import pytest
from unittest.mock import AsyncMock, patch
from fastapi.testclient import TestClient
import httpx

# Import after setting the env vars the app reads at import time
import os

os.environ.setdefault("VLLM_BASE_URL", "http://fake-vllm:8000")
os.environ.setdefault("VLLM_MODEL", "HuggingFaceTB/SmolLM2-135M-Instruct")
os.environ.setdefault("APP_ENV", "test")

from main import app  # noqa: E402  (must come after env setup)


# ─────────────────────────────────────────────────────────────────────────────
# Fixtures
# ─────────────────────────────────────────────────────────────────────────────

@pytest.fixture()
def client():
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


MOCK_VLLM_RESPONSE = {
    "id": "cmpl-test",
    "object": "text_completion",
    "model": "HuggingFaceTB/SmolLM2-135M-Instruct",
    "choices": [
        {
            "text": "The capital of France is Paris.",
            "index": 0,
            "finish_reason": "stop",
        }
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# /health
# ─────────────────────────────────────────────────────────────────────────────

class TestHealth:
    def test_health_ok_when_vllm_up(self, client):
        with patch("httpx.AsyncClient.get", new_callable=AsyncMock) as mock_get:
            mock_get.return_value = httpx.Response(200)
            resp = client.get("/health")
        assert resp.status_code == 200
        body = resp.json()
        assert body["status"] == "ok"
        assert body["vllm_reachable"] is True

    def test_health_ok_when_vllm_down(self, client):
        """Service should still return 200; vllm_reachable just flips to False."""
        with patch("httpx.AsyncClient.get", side_effect=httpx.ConnectError("refused")):
            resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["vllm_reachable"] is False


# ─────────────────────────────────────────────────────────────────────────────
# POST /ask — happy path
# ─────────────────────────────────────────────────────────────────────────────

class TestAskHappyPath:
    def _mock_post(self, *args, **kwargs):
        return httpx.Response(200, json=MOCK_VLLM_RESPONSE)

    def test_returns_answer(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = httpx.Response(200, json=MOCK_VLLM_RESPONSE)
            resp = client.post("/ask", json={"question": "What is the capital of France?"})

        assert resp.status_code == 200
        body = resp.json()
        assert body["answer"] == "The capital of France is Paris."
        assert body["question"] == "What is the capital of France?"
        assert "model" in body
        assert "latency_ms" in body
        assert isinstance(body["latency_ms"], float)

    def test_response_schema_complete(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = httpx.Response(200, json=MOCK_VLLM_RESPONSE)
            resp = client.post("/ask", json={"question": "Hello?"})

        assert resp.status_code == 200
        keys = set(resp.json().keys())
        assert keys == {"question", "answer", "model", "latency_ms"}


# ─────────────────────────────────────────────────────────────────────────────
# POST /ask — validation
# ─────────────────────────────────────────────────────────────────────────────

class TestAskValidation:
    def test_empty_question_rejected(self, client):
        resp = client.post("/ask", json={"question": ""})
        assert resp.status_code == 422

    def test_missing_question_rejected(self, client):
        resp = client.post("/ask", json={})
        assert resp.status_code == 422

    def test_question_too_long_rejected(self, client):
        resp = client.post("/ask", json={"question": "x" * 2001})
        assert resp.status_code == 422

    def test_question_at_max_length_accepted(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = httpx.Response(200, json=MOCK_VLLM_RESPONSE)
            resp = client.post("/ask", json={"question": "x" * 2000})
        assert resp.status_code == 200

    def test_non_string_question_rejected(self, client):
        resp = client.post("/ask", json={"question": 42})
        assert resp.status_code == 422


# ─────────────────────────────────────────────────────────────────────────────
# POST /ask — error handling
# ─────────────────────────────────────────────────────────────────────────────

class TestAskErrorHandling:
    def test_504_on_timeout(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.side_effect = httpx.TimeoutException("timed out")
            resp = client.post("/ask", json={"question": "Hello?"})
        assert resp.status_code == 504
        assert "timed out" in resp.json()["detail"].lower()

    def test_502_on_vllm_5xx(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = httpx.Response(
                503,
                request=httpx.Request("POST", "http://fake/v1/completions"),
            )
            # Raise the status error manually (as httpx.AsyncClient would)
            mock_post.side_effect = httpx.HTTPStatusError(
                "503",
                request=httpx.Request("POST", "http://fake/v1/completions"),
                response=httpx.Response(503),
            )
            resp = client.post("/ask", json={"question": "Hello?"})
        assert resp.status_code == 502

    def test_request_id_header_present(self, client):
        with patch("httpx.AsyncClient.post", new_callable=AsyncMock) as mock_post:
            mock_post.return_value = httpx.Response(200, json=MOCK_VLLM_RESPONSE)
            resp = client.post("/ask", json={"question": "Hi?"})
        assert "x-request-id" in resp.headers
