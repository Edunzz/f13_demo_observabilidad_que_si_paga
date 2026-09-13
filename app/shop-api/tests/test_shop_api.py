"""Tests de shop-api. payment-service se mockea con respx (no hay red real)."""

import httpx
import respx
from fastapi.testclient import TestClient

from src.main import PAYMENT_SERVICE_URL, app

client = TestClient(app)


def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


@respx.mock
def test_checkout_success():
    respx.post(f"{PAYMENT_SERVICE_URL}/pay").mock(
        return_value=httpx.Response(
            200,
            json={"outcome": "success", "fault_active": False, "duration_ms": 12.3},
        )
    )

    resp = client.post("/checkout", json={"amount_usd": 42.0})

    assert resp.status_code == 200
    body = resp.json()
    assert body["outcome"] == "success"
    assert body["amount_usd"] == 42.0
    assert "order_id" in body and len(body["order_id"]) > 0
    assert "duration_ms" in body


@respx.mock
def test_checkout_error_when_payment_fails():
    respx.post(f"{PAYMENT_SERVICE_URL}/pay").mock(
        return_value=httpx.Response(
            500,
            json={"outcome": "error", "fault_active": True, "duration_ms": 1800.0},
        )
    )

    resp = client.post("/checkout", json={"order_id": "abc123", "amount_usd": 10.0})

    assert resp.status_code == 502
    body = resp.json()
    assert body["outcome"] == "error"
    assert body["order_id"] == "abc123"


@respx.mock
def test_metrics_exposes_checkout_counter():
    respx.post(f"{PAYMENT_SERVICE_URL}/pay").mock(
        return_value=httpx.Response(
            200,
            json={"outcome": "success", "fault_active": False, "duration_ms": 5.0},
        )
    )
    client.post("/checkout", json={"amount_usd": 15.0})

    resp = client.get("/metrics")
    assert resp.status_code == 200
    text = resp.text
    assert "f13_checkout_requests_total" in text
    assert "f13_checkout_duration_seconds_bucket" in text
    assert "f13_checkout_value_usd_sum" in text
