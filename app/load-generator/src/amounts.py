"""Generador de montos ilustrativos para el tráfico sintético.

Función pura (sin I/O) para que sea fácil de testear de forma determinista
inyectando la fuente de aleatoriedad.
"""

import random


def random_amount_usd(center: float, jitter_ratio: float, rng: random.Random | None = None) -> float:
    """Devuelve un monto USD alrededor de `center` con variación `jitter_ratio`.

    Ej.: center=50, jitter_ratio=0.2 -> monto uniforme en [40, 60].
    `jitter_ratio` se acota a [0, 1] para evitar montos negativos o
    absurdamente amplios ante una env var mal configurada.
    """
    rng = rng or random
    ratio = min(max(jitter_ratio, 0.0), 1.0)
    low = center * (1.0 - ratio)
    high = center * (1.0 + ratio)
    amount = rng.uniform(low, high)
    return round(max(amount, 1.0), 2)
