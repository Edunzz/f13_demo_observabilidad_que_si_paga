#!/usr/bin/env bash
# Smoke test del laboratorio F13. Corre en el Codespace (o donde viva el
# stack) contra los puertos publicados por compose.yaml en localhost.
#
# Uso:
#   bash scripts/smoke-test.sh
#   TARGET_HOST=<host> bash scripts/smoke-test.sh
#   bash scripts/smoke-test.sh -h|--help

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
install_error_trap

CURL_TIMEOUT=10
RETRY_ATTEMPTS=12
RETRY_SECONDS=5

# Métricas mínimas que deben existir en Prometheus. Se usan los nombres de
# serie EXACTOS tal como los expone prometheus_client (con sufijo
# _total/_bucket), porque la API de consulta no resuelve el nombre "base" de
# un Counter/Histogram.
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
REQUIRED_DASHBOARDS=(f13-tecnico f13-impacto-negocio)
REQUIRED_TRACE_SERVICES=(shop-api payment-service)

usage() {
    cat <<'EOF'
Uso: bash scripts/smoke-test.sh [-h|--help]

Prueba, en orden, que el laboratorio F13 responde correctamente:
  1. GET  /health de shop-api (puerto 8080)
  2. POST /checkout de shop-api: HTTP 200 y JSON con "outcome"
  3. Prometheus (9090) tiene todas las métricas f13_* requeridas
  4. GET  /api/health de Grafana (puerto 3000)
  5. Grafana tiene provisionados los dashboards f13-tecnico y f13-impacto-negocio
  6. Jaeger UI (puerto 16686) responde HTTP 200
  7. Jaeger ya recibió trazas de shop-api y payment-service

Los pasos 3, 5 y 7 reintentan hasta ~60s (el scrape, el polling de
value-exporter y el batch del Collector tardan unos segundos tras arrancar).

Variables de entorno:
  TARGET_HOST   host contra el que se prueba (default: localhost)
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

fail() {
    log_error "$1"
    exit 1
}

log_info "Ejecutando smoke test contra TARGET_HOST=${TARGET_HOST}"

# 1. GET /health de shop-api ----------------------------------------------------
log_info "1/7: GET http://${TARGET_HOST}:${SHOP_API_PORT}/health"
health_code="$(curl -s -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' "http://${TARGET_HOST}:${SHOP_API_PORT}/health" || echo "000")"
if [[ "${health_code}" != "200" ]]; then
    fail "shop-api /health respondió HTTP ${health_code} (se esperaba 200)."
fi
log_info "OK: shop-api /health -> 200"

# 2. POST /checkout ----------------------------------------------------------------
checkout_body='{"order_id":"smoke-test-order","amount_usd":50.0}'
log_info "2/7: POST http://${TARGET_HOST}:${SHOP_API_PORT}/checkout"
checkout_response="$(mktemp)"
checkout_code="$(curl -s -m "${CURL_TIMEOUT}" -o "${checkout_response}" -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d "${checkout_body}" \
    "http://${TARGET_HOST}:${SHOP_API_PORT}/checkout" || echo "000")"
if [[ "${checkout_code}" != "200" ]]; then
    log_error "Respuesta de /checkout: $(cat "${checkout_response}")"
    rm -f "${checkout_response}"
    fail "shop-api /checkout respondió HTTP ${checkout_code} (se esperaba 200). ¿Quedó una falla activa? Prueba: bash scripts/recover.sh"
fi
if ! grep -q '"outcome"' "${checkout_response}"; then
    log_error "Respuesta de /checkout: $(cat "${checkout_response}")"
    rm -f "${checkout_response}"
    fail "La respuesta de /checkout no contiene el campo \"outcome\"."
fi
rm -f "${checkout_response}"
log_info "OK: shop-api /checkout -> 200 con campo \"outcome\""

# 3. Métricas f13_* en Prometheus ----------------------------------------------------
log_info "3/7: verificando métricas f13_* en Prometheus (http://${TARGET_HOST}:${PROMETHEUS_PORT})"
missing_metrics=()
for attempt in $(seq 1 "${RETRY_ATTEMPTS}"); do
    missing_metrics=()
    for metric in "${REQUIRED_METRICS[@]}"; do
        # `|| true` deliberado: un curl fallido deja query_result vacío y el
        # chequeo de abajo lo reporta como métrica ausente (no se oculta).
        query_result="$(curl -s -m "${CURL_TIMEOUT}" -G --data-urlencode "query=${metric}" \
            "http://${TARGET_HOST}:${PROMETHEUS_PORT}/api/v1/query" || true)"
        if [[ -z "${query_result}" ]] || ! grep -q '"result":\[.\+\]' <<<"${query_result}"; then
            missing_metrics+=("${metric}")
        fi
    done
    if [[ "${#missing_metrics[@]}" -eq 0 ]]; then
        break
    fi
    log_info "  intento ${attempt}/${RETRY_ATTEMPTS}: faltan ${missing_metrics[*]}; esperando ${RETRY_SECONDS}s..."
    sleep "${RETRY_SECONDS}"
done
if [[ "${#missing_metrics[@]}" -gt 0 ]]; then
    fail "Prometheus no tiene (o aún no scrapeó) estas métricas requeridas: ${missing_metrics[*]}"
fi
log_info "OK: todas las métricas f13_* requeridas están presentes en Prometheus."

# 4. Grafana /api/health -------------------------------------------------------------
log_info "4/7: GET http://${TARGET_HOST}:${GRAFANA_PORT}/api/health"
grafana_response="$(curl -s -m "${CURL_TIMEOUT}" "http://${TARGET_HOST}:${GRAFANA_PORT}/api/health" || true)"
if [[ -z "${grafana_response}" ]] || ! grep -q '"database"' <<<"${grafana_response}"; then
    fail "Grafana /api/health no respondió el JSON esperado. Respuesta: ${grafana_response}"
fi
log_info "OK: Grafana /api/health respondió correctamente."

# 5. Dashboards provisionados ---------------------------------------------------------
log_info "5/7: verificando dashboards provisionados en Grafana"
# Se autentica con el admin de .env pasando las credenciales a curl por stdin
# (`-K -`), nunca como argumento visible en `ps`.
grafana_search() {
    local user password
    user="$(env_value GF_SECURITY_ADMIN_USER)"
    password="$(env_value GF_SECURITY_ADMIN_PASSWORD)"
    if [[ -n "${user}" && -n "${password}" ]]; then
        printf 'user = "%s:%s"\n' "${user}" "${password}" |
            curl -s -m "${CURL_TIMEOUT}" -K - "http://${TARGET_HOST}:${GRAFANA_PORT}/api/search?type=dash-db&query=F13" || true
    else
        curl -s -m "${CURL_TIMEOUT}" "http://${TARGET_HOST}:${GRAFANA_PORT}/api/search?type=dash-db&query=F13" || true
    fi
}
missing_dashboards=()
for attempt in $(seq 1 "${RETRY_ATTEMPTS}"); do
    search_result="$(grafana_search)"
    missing_dashboards=()
    for uid in "${REQUIRED_DASHBOARDS[@]}"; do
        if ! grep -q "\"uid\":\"${uid}\"" <<<"${search_result}"; then
            missing_dashboards+=("${uid}")
        fi
    done
    if [[ "${#missing_dashboards[@]}" -eq 0 ]]; then
        break
    fi
    log_info "  intento ${attempt}/${RETRY_ATTEMPTS}: faltan dashboards ${missing_dashboards[*]}; esperando ${RETRY_SECONDS}s..."
    sleep "${RETRY_SECONDS}"
done
if [[ "${#missing_dashboards[@]}" -gt 0 ]]; then
    fail "Grafana no tiene provisionados estos dashboards: ${missing_dashboards[*]}"
fi
log_info "OK: dashboards ${REQUIRED_DASHBOARDS[*]} provisionados."

# 6. Jaeger UI -----------------------------------------------------------------------
log_info "6/7: GET http://${TARGET_HOST}:${JAEGER_PORT}/"
jaeger_code="$(curl -s -o /dev/null -m "${CURL_TIMEOUT}" -w '%{http_code}' "http://${TARGET_HOST}:${JAEGER_PORT}/" || echo "000")"
if [[ "${jaeger_code}" != "200" ]]; then
    fail "Jaeger UI respondió HTTP ${jaeger_code} (se esperaba 200)."
fi
log_info "OK: Jaeger UI -> 200"

# 7. Trazas en Jaeger -----------------------------------------------------------------
log_info "7/7: verificando que Jaeger recibió trazas de ${REQUIRED_TRACE_SERVICES[*]}"
missing_services=()
for attempt in $(seq 1 "${RETRY_ATTEMPTS}"); do
    services_result="$(curl -s -m "${CURL_TIMEOUT}" "http://${TARGET_HOST}:${JAEGER_PORT}/api/services" || true)"
    missing_services=()
    for service in "${REQUIRED_TRACE_SERVICES[@]}"; do
        if ! grep -q "\"${service}\"" <<<"${services_result}"; then
            missing_services+=("${service}")
        fi
    done
    if [[ "${#missing_services[@]}" -eq 0 ]]; then
        break
    fi
    log_info "  intento ${attempt}/${RETRY_ATTEMPTS}: Jaeger aún no tiene trazas de ${missing_services[*]}; esperando ${RETRY_SECONDS}s..."
    sleep "${RETRY_SECONDS}"
done
if [[ "${#missing_services[@]}" -gt 0 ]]; then
    fail "Jaeger no tiene trazas de: ${missing_services[*]} (revisa: docker compose logs otel-collector)"
fi
log_info "OK: Jaeger tiene trazas de ${REQUIRED_TRACE_SERVICES[*]}."

log_info "Smoke test completo: todas las verificaciones pasaron."
