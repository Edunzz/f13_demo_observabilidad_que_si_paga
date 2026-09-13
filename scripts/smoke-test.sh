#!/usr/bin/env bash
# [LOCAL o VM f13demo] Smoke test del laboratorio F13. Modo dual:
#
#   - Corrido en la máquina del operador (LOCAL): prueba contra la IP pública
#     de la VM (TARGET_HOST=<PUBLIC_IP>, tomado de .f13demo-state.env si no
#     se exporta explícitamente). Solo valida lo expuesto a Internet: 8080,
#     3000 y 16686 (NO Prometheus, que nunca está expuesto públicamente).
#   - Corrido DENTRO de la VM f13demo (normalmente invocado por
#     remote-install.sh o demo-reset.sh vía SSH): TARGET_HOST=localhost.
#     En ese modo también valida Prometheus en localhost:9090, ya que ese
#     puerto solo es alcanzable dentro de la propia VM.
#
# Mapeo de puertos: 8080 (shop-api), 3000 (Grafana) y 16686 (Jaeger) son
# IDÉNTICOS en ambos modos, porque docker compose los publica en la interfaz
# de red del host de la VM (no en un puerto interno distinto); lo único que
# cambia es si accedemos por la IP pública o por localhost. Prometheus
# (9090) solo se prueba en modo localhost porque el compose.yaml del
# laboratorio no lo publica hacia afuera de la VM.
#
# Uso:
#   TARGET_HOST=localhost bash scripts/smoke-test.sh
#   bash scripts/smoke-test.sh                 # usa la IP pública del estado
#   bash scripts/smoke-test.sh -h|--help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

SHOP_API_PORT=8080
GRAFANA_PORT=3000
JAEGER_PORT=16686
PROMETHEUS_PORT=9090
CURL_TIMEOUT=10

# Métricas mínimas que el contrato del laboratorio exige encontrar en
# Prometheus (ver INSTRUCCIONES_AGENTE_SONNET_LAB_F13.md, "Modelo de
# métricas"). IMPORTANTE: se usan los nombres de serie EXACTOS tal como los
# expone prometheus_client (con sufijo _total/_bucket incluido), porque la
# API de consulta de Prometheus no resuelve el nombre "base" de un Counter/
# Histogram: hay que preguntar por el nombre de serie real.
REQUIRED_METRICS=(
    f13_checkout_requests_total
    f13_checkout_duration_seconds_bucket
    f13_payment_requests_total
    f13_payment_duration_seconds_bucket
    f13_business_revenue_at_risk_usd_per_minute
    f13_business_degradation_loss_usd_per_minute
    f13_slo_target_ratio
    f13_fault_active
)

usage() {
    cat <<'EOF'
Uso: TARGET_HOST=<host> bash scripts/smoke-test.sh [-h|--help]

Prueba, en orden, que el laboratorio F13 responde correctamente:
  1. GET  /health          en shop-api (puerto 8080)
  2. POST /checkout        en shop-api, espera HTTP 200 y JSON con "outcome"
  3. (solo si TARGET_HOST=localhost) Prometheus (9090) tiene las métricas f13_*
  4. GET  /api/health       en Grafana (puerto 3000)
  5. GET  /                en Jaeger UI (puerto 16686), espera HTTP 200

Falla (exit != 0) con mensaje claro ante cualquier verificación no exitosa.

Variables de entorno:
  TARGET_HOST   host contra el que se prueba. Si no se define, se usa la IP
                pública guardada en .f13demo-state.env (modo LOCAL). Pasa
                TARGET_HOST=localhost para correr dentro de la VM f13demo.
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

require_cmd curl

if [[ -z "${TARGET_HOST:-}" ]]; then
    log_info "TARGET_HOST no definido; cargando IP pública desde ${STATE_FILE}..."
    load_state_file
    TARGET_HOST="${PUBLIC_IP}"
fi

log_info "Ejecutando smoke test contra TARGET_HOST=${TARGET_HOST}"

fail() {
    log_error "$1"
    exit 1
}

# 1. GET /health de shop-api ----------------------------------------------------
log_info "1/5: GET http://${TARGET_HOST}:${SHOP_API_PORT}/health"
health_code="$(curl -s -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' "http://${TARGET_HOST}:${SHOP_API_PORT}/health" || echo "000")"
if [[ "${health_code}" != "200" ]]; then
    fail "shop-api /health respondió HTTP ${health_code} (se esperaba 200)."
fi
log_info "OK: shop-api /health -> 200"

# 2. POST /checkout con body de ejemplo ------------------------------------------
# NOTA / SUPUESTO: el esquema exacto de /checkout depende de app/shop-api
# (en construcción en paralelo). Usamos un body mínimo consistente con las
# variables del modelo financiero (.env.example: AVERAGE_REQUEST_VALUE_USD).
# Si el esquema real difiere, este paso fallará explícitamente (no se oculta
# el error), señalando la necesidad de ajustar el body de ejemplo aquí.
checkout_body='{"order_id":"smoke-test-order","amount_usd":50.0}'
log_info "2/5: POST http://${TARGET_HOST}:${SHOP_API_PORT}/checkout"
checkout_response="$(mktemp)"
checkout_code="$(curl -s -m "${CURL_TIMEOUT}" -o "${checkout_response}" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d "${checkout_body}" \
    "http://${TARGET_HOST}:${SHOP_API_PORT}/checkout" || echo "000")"
if [[ "${checkout_code}" != "200" ]]; then
    log_error "Respuesta de /checkout: $(cat "${checkout_response}")"
    rm -f "${checkout_response}"
    fail "shop-api /checkout respondió HTTP ${checkout_code} (se esperaba 200)."
fi
if ! grep -q '"outcome"' "${checkout_response}"; then
    log_error "Respuesta de /checkout: $(cat "${checkout_response}")"
    rm -f "${checkout_response}"
    fail "La respuesta de /checkout no contiene el campo \"outcome\"."
fi
rm -f "${checkout_response}"
log_info "OK: shop-api /checkout -> 200 con campo \"outcome\""

# 3. Prometheus (solo en modo localhost, dentro de la VM) ------------------------
if [[ "${TARGET_HOST}" == "localhost" || "${TARGET_HOST}" == "127.0.0.1" ]]; then
    log_info "3/5: verificando métricas f13_* en Prometheus (http://localhost:${PROMETHEUS_PORT})"
    missing_metrics=()
    for metric in "${REQUIRED_METRICS[@]}"; do
        # `|| true` deliberado: si curl falla (p. ej. timeout), dejamos
        # query_result vacío a propósito; el chequeo de abajo lo trata igual
        # que "métrica ausente" y lo reporta en missing_metrics (no se oculta).
        query_result="$(curl -s -m "${CURL_TIMEOUT}" -G --data-urlencode "query=${metric}" \
            "http://localhost:${PROMETHEUS_PORT}/api/v1/query" || true)"
        if [[ -z "${query_result}" ]] || ! grep -q '"result":\[.\+\]' <<<"${query_result}"; then
            missing_metrics+=("${metric}")
        fi
    done
    if [[ "${#missing_metrics[@]}" -gt 0 ]]; then
        fail "Prometheus no tiene (o aún no scrapeó) estas métricas requeridas: ${missing_metrics[*]}"
    fi
    log_info "OK: todas las métricas f13_* requeridas están presentes en Prometheus."
else
    log_info "3/5: omitido (Prometheus no está expuesto públicamente; solo se valida con TARGET_HOST=localhost)."
fi

# 4. Grafana ----------------------------------------------------------------------
log_info "4/5: GET http://${TARGET_HOST}:${GRAFANA_PORT}/api/health"
# `|| true` deliberado: un curl fallido deja grafana_response vacío, lo que
# el chequeo siguiente ya trata como fallo explícito (no se enmascara nada).
grafana_response="$(curl -s -m "${CURL_TIMEOUT}" "http://${TARGET_HOST}:${GRAFANA_PORT}/api/health" || true)"
if [[ -z "${grafana_response}" ]] || ! grep -q '"database"' <<<"${grafana_response}"; then
    fail "Grafana /api/health no respondió el JSON esperado. Respuesta: ${grafana_response}"
fi
log_info "OK: Grafana /api/health respondió correctamente."

# 5. Jaeger UI ----------------------------------------------------------------------
log_info "5/5: GET http://${TARGET_HOST}:${JAEGER_PORT}/"
jaeger_code="$(curl -s -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' "http://${TARGET_HOST}:${JAEGER_PORT}/" || echo "000")"
if [[ "${jaeger_code}" != "200" ]]; then
    fail "Jaeger UI respondió HTTP ${jaeger_code} (se esperaba 200)."
fi
log_info "OK: Jaeger UI -> 200"

log_info "Smoke test completo: todas las verificaciones pasaron."
