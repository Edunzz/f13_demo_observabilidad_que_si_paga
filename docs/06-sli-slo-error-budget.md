# 06. SLI, SLO y error budget

Este documento define los indicadores de nivel de servicio (SLI), el objetivo de nivel de servicio
(SLO) y el presupuesto de error (error budget) usados por el laboratorio F13, siguiendo la
terminología del SRE Book y el SRE Workbook de Google
`{ref SLI/SLO/error budget https://sre.google/sre-book/service-level-objectives/}`.

## SLI técnico

**Definición:** proporción de checkouts que terminan **por debajo de un umbral de latencia** definido
(en este laboratorio, 1 segundo), sobre el total de checkouts en la ventana de observación.

En el dashboard **"F13 | Salud técnica"** este SLI se muestra en el panel **"SLI técnico (checkouts <
1s / total, 5m)"**, calculado sobre el histograma `f13_checkout_duration_seconds_bucket` con
`histogram_quantile` / conteo de buckets vía las *recording rules* de
`observability/prometheus/rules.yml` (grupo `f13-latency`, ventana móvil de 5 minutos).

## SLI de negocio

**Definición:** proporción de checkouts que **terminan exitosamente** (`outcome="success"`) sobre el
total de checkouts en la ventana de observación.

En el dashboard técnico aparece en el panel **"SLI de negocio (checkouts exitosos / total, 5m)"**,
calculado con las *recording rules* `f13:checkout_success_rate_5m` /
`f13:checkout_error_rate_5m` (grupo `f13-rates` en `rules.yml`):

```promql
f13:checkout_success_rate_5m =
  sum(rate(f13_checkout_requests_total{outcome="success"}[5m]))
  /
  sum(rate(f13_checkout_requests_total[5m]))
```

`value-exporter` recalcula esta misma proporción de forma independiente (con una ventana de 1 minuto,
ver más abajo) para derivar de ahí el error budget y las métricas financieras.

## SLO ilustrativo: 99.9%

El SLO objetivo de este laboratorio es **99.9%** de éxito (`SLO_TARGET_RATIO=0.999` en
`.env.example`), aplicado sobre el SLI de negocio. Es un valor **ilustrativo**, elegido por ser un
objetivo común y fácil de explicar (equivale a "permitir" un 0.1% de tasa de error), no una
recomendación de negocio para ningún sistema real.

## Cómo se calcula el error budget restante

`app/value-exporter/src/formulas.py` implementa `slo_error_budget_remaining_ratio()` con esta lógica
(simplificación deliberada para la demo):

```text
allowed_error_rate = 1 - slo_target_ratio        # p.ej. 1 - 0.999 = 0.001
error_rate_actual  = 1 - success_rate_actual
consumed_ratio     = error_rate_actual / allowed_error_rate
error_budget_remaining = clamp(1 - consumed_ratio, 0, 1)
```

En estado sano (`success_rate ≈ 1`), `error_rate_actual ≈ 0`, por lo que `consumed_ratio ≈ 0` y el
error budget restante es cercano a `1` (100% del presupuesto disponible). Con la falla activa
(`FAULT_ERROR_RATE=0.30` ⇒ `success_rate ≈ 0.70` ⇒ `error_rate_actual ≈ 0.30`), el presupuesto
permitido (`0.001`) se agota casi instantáneamente:

```text
consumed_ratio ≈ 0.30 / 0.001 = 300  →  se acota (clamp) a "presupuesto agotado" (remaining = 0)
```

Este comportamiento es intencional para la demo: con un SLO de 99.9% y una falla que produce 30% de
error, el error budget se agota en segundos, no en horas — precisamente porque estamos usando una
**ventana acelerada de demostración** (ver siguiente sección), no una ventana de producción de 30
días.

## Burn rate

El *burn rate* es la velocidad relativa a la que se consume el error budget frente al ritmo "esperado"
si el sistema consumiera su presupuesto de forma uniforme durante toda la ventana del SLO. El panel
**"SLO objetivo / burn rate instantáneo"** del dashboard técnico muestra el `SLO_TARGET_RATIO`
configurado junto al burn rate instantáneo derivado del error budget restante.

Como referencia del patrón de alerta por burn-rate (multi-ventana, multi-burn-rate) descrito por
Google SRE, `observability/prometheus/rules.yml` incluye una regla de alerta **ilustrativa**
(`F13ErrorBudgetBurnRateHigh`, grupo `f13-burn-rate-illustrative`) que se dispara cuando
`f13_slo_error_budget_remaining_ratio < 0.10`. Esta regla es visible en la UI de Prometheus
(`http://localhost:9090/alerts`, no publicada al host) solo para ilustrar el patrón: **este
laboratorio no despliega Alertmanager**, por lo que la regla nunca envía una notificación real.

## Ventana acelerada de demostración vs. ventana de producción

| | Ventana acelerada (esta demo) | Ventana de producción típica |
|---|---|---|
| Ventana de las *recording rules* de tasa/latencia | 5 minutos (`rate(...[5m])`, `interval: 5s` en `rules.yml`) | 30 días (rolling) |
| Ventana de la consulta que alimenta el error budget en `value-exporter` | 1 minuto (`rate(...[1m])`, polling cada 5s) | 30 días (rolling) |
| Objetivo | Que el efecto de inyectar/recuperar una falla sea **visible en segundos**, dentro de una demo de 20 minutos | Medir cumplimiento del SLO de forma estadísticamente representativa a lo largo de un mes |
| Riesgo de usar la ventana corta en producción | El error budget se agota/reponerse de forma artificialmente rápida ante picos cortos; no refleja el comportamiento real del servicio a lo largo del mes | N/A (es el enfoque recomendado) |

Es fundamental declarar esto en voz alta durante la demo (ver `docs/04-guion-demo-20-min.md`, sección
05:00–08:00): la ventana corta existe **solo para que el público vea el efecto en 20 minutos**, no
porque sea la práctica recomendada para gestionar un SLO real.

### Ejemplo de consulta PromQL equivalente para 30 días (no usada en vivo)

Para referencia, así se vería la misma tasa de éxito de checkout con una ventana de producción de 30
días en lugar de los 5 minutos usados en la demo (no se ejecuta durante la demo por el volumen de
datos y retención que requeriría; ver `docs/07-seguridad.md` sobre la política de retención corta de
este laboratorio):

```promql
sum(rate(f13_checkout_requests_total{outcome="success"}[30d]))
/
sum(rate(f13_checkout_requests_total[30d]))
```

Y el error budget restante equivalente, sustituyendo la ventana de 1 minuto de `value-exporter` por
una ventana de 30 días:

```promql
1 - (
  (1 - (
    sum(rate(f13_checkout_requests_total{outcome="success"}[30d]))
    /
    sum(rate(f13_checkout_requests_total[30d]))
  ))
  /
  (1 - 0.999)
)
```

## Principios de referencia (Google SRE)

Este laboratorio sigue, de forma simplificada, los conceptos descritos en la documentación pública de
Google SRE:

- SLI, SLO y error budget: SRE Book, capítulo "Service Level Objectives".
- Alerta por burn-rate multi-ventana: SRE Workbook, capítulo "Alerting on SLOs".

## Referencias

- Google SRE — sitio oficial: https://sre.google
- Google SRE Book — Service Level Objectives: https://sre.google/sre-book/service-level-objectives/
- Google SRE Workbook — Alerting on SLOs: https://sre.google/workbook/alerting-on-slos/
- Prometheus — `rate()` y `histogram_quantile()`: https://prometheus.io/docs/prometheus/latest/querying/functions/
- Prometheus — reglas de grabación (recording rules): https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
