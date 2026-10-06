#!/usr/bin/env bash
# Imprime en la terminal una foto instantánea de las señales técnicas, el SLO
# y la capa de valor (USD ilustrativos) del laboratorio F13, consultando la
# API de Prometheus. Es la versión "texto plano" del dashboard
# "F13 | Impacto en el negocio".
#
# Uso:
#   bash scripts/business-snapshot.sh [-h|--help]
#   watch -n 5 bash scripts/business-snapshot.sh     # refresco continuo

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

usage() {
    cat <<'EOF'
Uso: bash scripts/business-snapshot.sh [-h|--help]

Consulta Prometheus (localhost:9090) e imprime:
  - Señales técnicas: falla activa, checkouts/min, tasa de error, latencia p95
  - SLO: objetivo y error budget restante
  - Capa de valor: ingreso en riesgo, pérdida por degradación y pérdida
    estimada acumulada (USD ILUSTRATIVOS)

Para verlo refrescarse solo:  watch -n 5 bash scripts/business-snapshot.sh
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Argumento no reconocido: ${arg}"
            usage
            exit 1
            ;;
    esac
done

require_cmd python3

# Dentro de `if !` para que un fallo de Python (p. ej. Prometheus caído) no
# dispare el trap ERR, que imprimiría todo el heredoc como "comando fallido".
if ! PROM_URL="http://${TARGET_HOST}:${PROMETHEUS_PORT}" python3 - <<'PY'
import json
import math
import os
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timezone

PROM_URL = os.environ["PROM_URL"]


def query(expr):
    url = f"{PROM_URL}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=5) as resp:
        result = json.load(resp).get("data", {}).get("result", [])
    if not result:
        return None
    value = float(result[0]["value"][1])
    return None if math.isnan(value) else value


def fmt(value, kind):
    if value is None:
        return "n/d"
    if kind == "bool":
        return "SI" if value >= 1 else "NO"
    if kind == "pct":
        return f"{value * 100:,.2f} %"
    if kind == "num":
        return f"{value:,.1f}"
    if kind == "sec":
        return f"{value:,.3f} s"
    if kind == "usd_min":
        return f"{value:,.2f} USD/min"
    if kind == "usd":
        return f"{value:,.2f} USD"
    return str(value)


SECTIONS = [
    ("Señales técnicas", [
        ("Falla inyectada activa", "max(f13_fault_active)", "bool"),
        ("Checkouts por minuto", "max(f13_business_requests_per_minute)", "num"),
        ("Tasa de error de checkout (1m)", "max(f13_business_error_rate_ratio)", "pct"),
        ("Latencia p95 de checkout (1m)",
         "histogram_quantile(0.95, sum by (le) (rate(f13_checkout_duration_seconds_bucket[1m])))", "sec"),
    ]),
    ("SLO (ventana acelerada de demo)", [
        ("SLO objetivo", "max(f13_slo_target_ratio)", "pct"),
        ("Error budget restante", "max(f13_slo_error_budget_remaining_ratio)", "pct"),
    ]),
    ("Capa de valor (valores ILUSTRATIVOS)", [
        ("Ingreso en riesgo", "max(f13_business_revenue_at_risk_usd_per_minute)", "usd_min"),
        ("Pérdida por degradación", "max(f13_business_degradation_loss_usd_per_minute)", "usd_min"),
        ("Pérdida estimada acumulada", "max(f13_business_estimated_loss_usd_total)", "usd"),
    ]),
]

now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
print(f"== F13 · snapshot técnico + negocio ({now}) ==")
try:
    for title, rows in SECTIONS:
        print(title)
        for label, expr, kind in rows:
            print(f"  {label:<36} {fmt(query(expr), kind):>18}")
except OSError as exc:
    print(f"No se pudo consultar Prometheus en {PROM_URL}: {exc}", file=sys.stderr)
    print("¿Está arriba el stack? Revisa con: bash scripts/status.sh", file=sys.stderr)
    sys.exit(1)
PY
then
    exit 1
fi
