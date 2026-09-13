"""Tests de payment-service. `random.random` se mockea para determinismo."""

from fastapi.testclient import TestClient

import src.main as main_module

client = TestClient(main_module.app)

ADMIN_TOKEN = "test-token"  # debe coincidir con FAULT_ADMIN_TOKEN en conftest.py


def _reset_fault():
    client.post(
        "/admin/fault",
        json={"active": False},
        headers={"X-Fault-Admin-Token": ADMIN_TOKEN},
    )


def teardown_function(_):
    _reset_fault()


def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_pay_success_without_fault():
    _reset_fault()
    resp = client.post("/pay", json={"order_id": "o1", "amount_usd": 10.0})
    assert resp.status_code == 200
    body = resp.json()
    assert body["outcome"] == "success"
    assert body["fault_active"] is False


def test_pay_fails_when_fault_active_and_random_below_error_rate(monkeypatch):
    client.post(
        "/admin/fault",
        json={"active": True, "latency_ms": 1, "error_rate": 0.5},
        headers={"X-Fault-Admin-Token": ADMIN_TOKEN},
    )
    monkeypatch.setattr(main_module.random, "random", lambda: 0.1)  # < 0.5 -> error

    resp = client.post("/pay", json={"order_id": "o2", "amount_usd": 10.0})

    assert resp.status_code == 500
    body = resp.json()
    assert body["outcome"] == "error"
    assert body["fault_active"] is True


def test_pay_succeeds_when_fault_active_but_random_above_error_rate(monkeypatch):
    client.post(
        "/admin/fault",
        json={"active": True, "latency_ms": 1, "error_rate": 0.5},
        headers={"X-Fault-Admin-Token": ADMIN_TOKEN},
    )
    monkeypatch.setattr(main_module.random, "random", lambda: 0.9)  # >= 0.5 -> success

    resp = client.post("/pay", json={"order_id": "o3", "amount_usd": 10.0})

    assert resp.status_code == 200
    assert resp.json()["outcome"] == "success"


def test_admin_fault_requires_valid_token():
    resp = client.post("/admin/fault", json={"active": True})
    assert resp.status_code == 401

    resp = client.post(
        "/admin/fault", json={"active": True}, headers={"X-Fault-Admin-Token": "wrong"}
    )
    assert resp.status_code == 401


def test_admin_fault_get_reflects_state():
    client.post(
        "/admin/fault",
        json={"active": True, "latency_ms": 500, "error_rate": 0.2},
        headers={"X-Fault-Admin-Token": ADMIN_TOKEN},
    )
    resp = client.get("/admin/fault")
    assert resp.status_code == 200
    body = resp.json()
    assert body == {"active": True, "latency_ms": 500, "error_rate": 0.2}


def test_metrics_exposes_fault_gauge_and_payment_counter():
    resp = client.get("/metrics")
    assert resp.status_code == 200
    text = resp.text
    assert "f13_payment_requests_total" in text
    assert "f13_payment_duration_seconds_bucket" in text
    assert "f13_fault_active" in text
