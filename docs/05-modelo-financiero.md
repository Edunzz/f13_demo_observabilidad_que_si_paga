# 05. Modelo financiero (capa de valor)

> **Aviso repetido a propósito, porque es el punto más importante de este documento:** todas las
> cifras de este documento —y todas las que verá el público en los dashboards de la demo— son
> **ILUSTRATIVAS**. Se calculan con los valores de ejemplo de `.env.example` para demostrar un
> **método** de traducir señales técnicas a lenguaje de negocio. No representan ingresos, tickets ni
> tasas de conversión de ninguna organización real, ni deben usarse como referencia de negocio fuera
> de este laboratorio.

Este documento explica, en detalle, las 3 fórmulas que implementa `app/value-exporter` (código en
`app/value-exporter/src/formulas.py`) y las recalcula paso a paso con los valores por defecto de
`.env.example`.

## Variables de entrada (valores por defecto de `.env.example`)

| Variable | Valor por defecto | Significado |
|---|---|---|
| `REQUESTS_PER_MINUTE` | `120` | Tráfico ilustrativo generado por `load-generator` (checkouts/min en estado sano). |
| `AVERAGE_REQUEST_VALUE_USD` | `50` | Valor ilustrativo promedio de un checkout, en USD. |
| `BASELINE_CONVERSION_RATE` | `0.15` | Tasa de conversión ilustrativa en estado sano (referencia narrativa; no interviene directamente en las 3 fórmulas de abajo). |
| `BASELINE_ABANDONMENT_RATE` | `0.10` | Abandono ilustrativo en estado sano. |
| `DEGRADED_ABANDONMENT_RATE` | `0.35` | Abandono ilustrativo mientras la falla está activa. |
| `AVERAGE_TICKET_USD` | `50` | Ticket promedio ilustrativo usado en la fórmula de pérdida por degradación. |
| `FAULT_ERROR_RATE` | `0.30` | Tasa de error inyectada por `scripts/inject-fault.sh` en `payment-service`. |
| `FAULT_LATENCY_MS` | `1800` | Latencia adicional inyectada (no entra directamente en las fórmulas financieras, pero es la causa técnica del error/abandono). |

En producción, `error_rate`, `success_rate` y `requests_per_minute` reales se calculan a partir de
Prometheus (ventana móvil de 1 minuto sobre `f13_checkout_requests_total`, ver
`app/value-exporter/src/main.py`); en este documento los tratamos como constantes iguales a los
valores por defecto de arriba, solo para poder hacer el cálculo a mano de punta a punta.

## Fórmula 1: Ingreso en riesgo (USD/min)

```text
ingreso_en_riesgo_usd_min = error_rate * requests_per_minute * average_request_value_usd
```

Representa cuánto ingreso "se está jugando" la empresa **cada minuto**, mientras la tasa de error se
mantenga en ese nivel. No es pérdida ya consumada: es exposición (checkouts que están fallando ahora
mismo).

### Ejemplo numérico paso a paso

Con `FAULT_ERROR_RATE=0.30`, `REQUESTS_PER_MINUTE=120`, `AVERAGE_REQUEST_VALUE_USD=50`:

```text
ingreso_en_riesgo_usd_min = 0.30 * 120 * 50
                           = 36 * 50
                           = 1800 USD/min
```

**Resultado: 1800 USD/min de ingreso en riesgo (ilustrativo)**, mientras dure la falla con esa tasa de
error.

## Fórmula 2: Pérdida por degradación (USD/min)

```text
perdida_degradacion_usd_min = max(degraded_abandonment - baseline_abandonment, 0) * conversions_per_minute * average_ticket_usd
```

Representa la pérdida atribuible al **exceso de abandono** de usuarios durante la degradación
(usuarios que, además de encontrarse con errores directos, abandonan la compra por la mala
experiencia), comparado contra el abandono de referencia en estado sano. El `max(..., 0)` evita
valores negativos si el sistema está sano (abandono actual ≤ baseline).

`conversions_per_minute` se aproxima, en este laboratorio, como los checkouts exitosos por minuto:
`requests_per_minute * success_rate` (ver `conversions_per_minute()` en `formulas.py`). Con
`FAULT_ERROR_RATE=0.30`, `success_rate = 1 - error_rate = 0.70`.

### Ejemplo numérico paso a paso

Con `DEGRADED_ABANDONMENT_RATE=0.35`, `BASELINE_ABANDONMENT_RATE=0.10`,
`REQUESTS_PER_MINUTE=120`, `success_rate=0.70`, `AVERAGE_TICKET_USD=50`:

```text
exceso_abandono          = max(0.35 - 0.10, 0) = 0.25
conversions_per_minute   = 120 * 0.70 = 84
perdida_degradacion_usd_min = 0.25 * 84 * 50
                            = 21 * 50
                            = 1050 USD/min
```

**Resultado: 1050 USD/min de pérdida por degradación (ilustrativa)**, mientras se mantenga ese nivel
de abandono.

## Fórmula 3: Pérdida estimada acumulada (USD)

```text
perdida_estimada_total_usd = integral temporal de las pérdidas por minuto durante la degradación
```

`value-exporter` la implementa como una **integral discreta (suma simple, no trapezoidal)**: en cada
ciclo de polling (cada ~5 s), toma la suma de las dos fórmulas anteriores
(`loss_per_minute_total = ingreso_en_riesgo_usd_min + perdida_degradacion_usd_min`) y la multiplica
por los minutos transcurridos desde la última muestra, sumándola al acumulador — **solo mientras
`f13_fault_active = 1`** (ver `accumulate_loss_usd()` en `formulas.py`). Esta aproximación asume que la
pérdida por minuto se mantuvo aproximadamente constante durante cada intervalo corto de polling, lo
cual es razonable para intervalos de ~5 s pero sería una simplificación mayor en ventanas más largas.

### Ejemplo numérico paso a paso

Combinando los dos resultados anteriores:

```text
loss_per_minute_total = 1800 + 1050 = 2850 USD/min
```

Si, solo a modo de ejemplo ilustrativo de cómo se integra en el tiempo, la falla permaneciera activa
durante 4 minutos continuos con esos mismos valores constantes:

```text
perdida_estimada_total_usd ≈ 2850 USD/min * 4 min = 11 400 USD (ilustrativo)
```

En la demo real, `f13_business_estimated_loss_usd_total` se resetea explícitamente al inicio de cada
corrida con `scripts/demo-reset.sh` (`POST /admin/reset-accumulator` en `value-exporter`, puerto 9200
interno), por lo que el valor que el público ve depende exactamente de cuánto tiempo estuvo activa la
falla durante esa demo puntual — no es un valor fijo.

## Panel de supuestos en los dashboards

El dashboard **"F13 | Impacto en el negocio"** incluye un panel de texto fijo, "Nota sobre los valores
mostrados", con el recordatorio "Valores ilustrativos para demostrar el método". Este panel debe
permanecer visible durante toda la demo.

## Limitaciones del modelo (decláralas siempre)

- **Aproximación lineal simplificada**: las tres fórmulas son lineales en `error_rate` /
  `abandonment_rate`; un sistema real de negocio rara vez responde de forma perfectamente lineal a la
  degradación técnica.
- **No modela elasticidad real de demanda**: no contempla que usuarios reales podrían reintentar más
  tarde, migrar a otro canal, o que el "ticket promedio" cambie según el tipo de degradación.
- **`average_request_value_usd` y `average_ticket_usd` son constantes de configuración**, no se
  derivan de datos reales de catálogo, precios o mezcla de productos.
- **La integral de pérdida acumulada es una suma discreta simple** (no trapezoidal), válida como
  aproximación para el intervalo corto de polling de este laboratorio (~5 s), pero no es un método de
  contabilidad financiera.
- **`conversions_per_minute` asume que todo checkout exitoso equivale a una conversión de negocio**;
  en un sistema real, conversión ≠ checkout exitoso (puede haber abandono post-pago, up-sell, devoluciones, etc.).
- **El objetivo es pedagógico**: mostrar cómo conectar señales técnicas (latencia, tasa de error) con
  una capa de valor expresada en dinero, no ofrecer un modelo de pricing/finanzas de producción.

## Referencias

- Google SRE Book — Service Level Objectives (contexto de por qué se conectan señales técnicas con
  objetivos medibles): https://sre.google/sre-book/service-level-objectives/
- Prometheus — funciones `rate()` e `histogram_quantile()` usadas como insumo de estas fórmulas:
  https://prometheus.io/docs/prometheus/latest/querying/functions/
