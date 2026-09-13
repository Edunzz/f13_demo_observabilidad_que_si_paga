"""Test mínimo del generador de montos aleatorios (función pura)."""

import random

from src.amounts import random_amount_usd


def test_random_amount_usd_dentro_del_rango_esperado():
    rng = random.Random(42)  # semilla fija -> determinista
    amount = random_amount_usd(50.0, 0.2, rng=rng)
    assert 40.0 <= amount <= 60.0


def test_random_amount_usd_nunca_negativo_con_jitter_extremo():
    rng = random.Random(1)
    amount = random_amount_usd(10.0, 1.0, rng=rng)  # jitter 100% -> rango [0, 20]
    assert amount >= 1.0  # se acota a un mínimo de 1.0 USD


def test_random_amount_usd_jitter_fuera_de_rango_se_acota():
    rng = random.Random(7)
    amount = random_amount_usd(50.0, 5.0, rng=rng)  # jitter > 1 se acota a 1.0
    assert 0.0 <= amount <= 100.0
