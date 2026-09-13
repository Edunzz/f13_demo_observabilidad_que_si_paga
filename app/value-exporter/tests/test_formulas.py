"""Tests de las fórmulas de negocio de value-exporter (funciones puras)."""

import pytest

from src.formulas import (
    accumulate_loss_usd,
    conversions_per_minute,
    ingreso_en_riesgo_usd_min,
    perdida_degradacion_usd_min,
    slo_error_budget_remaining_ratio,
)


def test_conversions_per_minute():
    assert conversions_per_minute(120, 0.9) == 108.0
    assert conversions_per_minute(120, 0.0) == 0.0
    assert conversions_per_minute(-10, 0.5) == 0.0  # nunca negativo


def test_ingreso_en_riesgo_usd_min():
    # 30% de error, 120 req/min, ticket promedio 50 USD -> 1800 USD/min en riesgo
    assert ingreso_en_riesgo_usd_min(0.30, 120, 50) == 1800.0


def test_ingreso_en_riesgo_usd_min_sin_error_es_cero():
    assert ingreso_en_riesgo_usd_min(0.0, 120, 50) == 0.0


def test_perdida_degradacion_usd_min_con_degradacion():
    # abandono pasa de 10% a 35% (exceso 25%), 108 conversiones/min, ticket 50
    resultado = perdida_degradacion_usd_min(0.35, 0.10, 108, 50)
    assert resultado == pytest.approx(0.25 * 108 * 50)


def test_perdida_degradacion_usd_min_sin_degradacion_es_cero():
    # abandono igual o menor al baseline -> no hay pérdida atribuible
    assert perdida_degradacion_usd_min(0.10, 0.10, 108, 50) == 0.0
    assert perdida_degradacion_usd_min(0.05, 0.10, 108, 50) == 0.0


def test_accumulate_loss_usd_suma_perdida_por_intervalo():
    total = accumulate_loss_usd(previous_total=0.0, loss_per_minute=60.0, elapsed_minutes=0.5)
    assert total == 30.0

    total2 = accumulate_loss_usd(previous_total=total, loss_per_minute=60.0, elapsed_minutes=0.5)
    assert total2 == 60.0


def test_accumulate_loss_usd_no_suma_si_no_hay_perdida():
    total = accumulate_loss_usd(previous_total=100.0, loss_per_minute=0.0, elapsed_minutes=1.0)
    assert total == 100.0


def test_slo_error_budget_remaining_ratio_sano():
    # SLO 99.9%, success_rate 100% -> budget completo
    assert slo_error_budget_remaining_ratio(0.999, 1.0) == 1.0


def test_slo_error_budget_remaining_ratio_degradado():
    # SLO 99.9% (budget de error 0.1%), success_rate 70% (error 30%) -> budget agotado
    assert slo_error_budget_remaining_ratio(0.999, 0.70) == 0.0


def test_slo_error_budget_remaining_ratio_parcial():
    # allowed_error_rate = 0.01 (SLO 99%), error_rate real = 0.005 -> mitad del budget consumido
    result = slo_error_budget_remaining_ratio(0.99, 0.995)
    assert round(result, 4) == 0.5
