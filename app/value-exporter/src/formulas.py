"""Fórmulas de negocio de value-exporter, como funciones puras (sin I/O).

Todos los valores de entrada/salida son ILUSTRATIVOS: sirven para demostrar el
método (traducir señales técnicas a lenguaje de negocio), no representan datos
financieros de ninguna organización real.
"""


def conversions_per_minute(requests_per_minute: float, success_rate: float) -> float:
    """Aproxima las "conversiones" por minuto como los checkouts exitosos.

    # Supuesto ilustrativo para la demo: tratamos todo checkout exitoso como
    # una conversión de negocio. En un sistema real, conversión != checkout
    # exitoso (puede haber abandono post-pago, up-sell, etc.), pero para este
    # laboratorio esa distinción no aporta y sí añade ruido conceptual.
    """
    return max(requests_per_minute, 0.0) * max(success_rate, 0.0)


def ingreso_en_riesgo_usd_min(
    error_rate: float, requests_per_minute: float, average_request_value_usd: float
) -> float:
    """Ingreso en riesgo por minuto = tasa de error * tráfico * ticket promedio.

    Representa cuánto ingreso "se juega" cada minuto por los checkouts que
    están fallando ahora mismo (no es pérdida ya consumada, es exposición).
    """
    return max(error_rate, 0.0) * max(requests_per_minute, 0.0) * max(average_request_value_usd, 0.0)


def perdida_degradacion_usd_min(
    degraded_abandonment_rate: float,
    baseline_abandonment_rate: float,
    conversions_per_minute_value: float,
    average_ticket_usd: float,
) -> float:
    """Pérdida por degradación = exceso de abandono (vs. baseline) * conversiones * ticket.

    Si el abandono actual es igual o menor al baseline, la pérdida es 0 (no
    hay degradación atribuible a la falla). `max(..., 0)` evita valores
    negativos cuando el sistema está sano.
    """
    exceso_abandono = max(degraded_abandonment_rate - baseline_abandonment_rate, 0.0)
    return exceso_abandono * max(conversions_per_minute_value, 0.0) * max(average_ticket_usd, 0.0)


def accumulate_loss_usd(previous_total: float, loss_per_minute: float, elapsed_minutes: float) -> float:
    """Integra (suma simple, no trapezoidal) la pérdida acumulada en el tiempo.

    `perdida_por_minuto * intervalo_en_minutos` asume que la pérdida por
    minuto se mantuvo aprox. constante durante el intervalo transcurrido
    desde la última muestra (válido para intervalos cortos de polling, p.ej.
    los ~5s del loop de value-exporter).
    """
    if elapsed_minutes <= 0 or loss_per_minute <= 0:
        return previous_total
    return previous_total + loss_per_minute * elapsed_minutes


def slo_error_budget_remaining_ratio(slo_target_ratio: float, success_rate: float) -> float:
    """Fracción restante del error budget dado un SLO objetivo.

    # Supuesto ilustrativo para la demo: error_budget_total = 1 - slo_target.
    # consumido = tasa_error_actual / error_budget_total; remaining = 1 - consumido,
    # acotado a [0, 1] porque no modelamos "budget negativo" (solo se
    # reporta como agotado).
    """
    allowed_error_rate = 1.0 - slo_target_ratio
    error_rate = 1.0 - success_rate
    if allowed_error_rate <= 0:
        return 0.0
    consumed_ratio = error_rate / allowed_error_rate
    remaining = 1.0 - consumed_ratio
    return min(max(remaining, 0.0), 1.0)
