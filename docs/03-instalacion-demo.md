# 03. Instalación del stack de la demo

Este documento explica cómo instalar y arrancar el stack Docker Compose del laboratorio F13 dentro de
la VM `f13demo`, una vez que `infra/azure/deploy.sh` ya corrió correctamente (ver
`docs/02-despliegue-azure.md`) y generó `.f13demo-state.env` en la raíz del repo.

## Paso 1: `remote-install.sh` `[LOCAL]`

```bash
# [LOCAL]
bash scripts/remote-install.sh

# [LOCAL] ayuda
bash scripts/remote-install.sh --help
```

Este script orquesta **por SSH**, desde tu máquina de operador, todo el proceso de instalación dentro
de la VM. En orden:

1. Carga `.f13demo-state.env`.
2. Verifica conectividad SSH contra `azureuser@<PUBLIC_IP>`.
3. Espera a que `cloud-init` termine (`sudo cloud-init status --wait`), lo cual puede tardar varios
   minutos si es la primera vez que se enciende la VM.
4. Clona `https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga.git` en
   `/opt/f13demo/repo` `[VM f13demo]` (si el repo ya existe y está limpio, hace `git fetch` +
   `pull --ff-only`; si tiene cambios locales sin commitear, se detiene sin forzar nada).
5. Crea `.env` a partir de `.env.example` **dentro de la VM**, si aún no existe, y genera ahí mismo
   los secretos (ver siguiente sección). Si `.env` ya existe, se conserva sin cambios.
6. Valida `docker version` y `docker compose version` en la VM.
7. Corre `docker compose config --quiet` para validar el compose antes de construir nada.
8. Construye las imágenes locales: `docker compose build --pull`.
9. Levanta el stack: `docker compose up -d`.
10. Espera los healthchecks de **todos** los contenedores (`f13demo-otel-collector`,
    `f13demo-jaeger`, `f13demo-prometheus`, `f13demo-grafana`, `f13demo-payment-service`,
    `f13demo-shop-api`, `f13demo-value-exporter`, `f13demo-load-generator`), con un timeout total de
    5 minutos.
11. Corre `scripts/smoke-test.sh` **dentro de la VM** (`TARGET_HOST=localhost`).
12. Imprime las URLs finales, **sin imprimir secretos**.

Salida esperada aproximada (fragmento final):

```text
== Laboratorio F13 disponible ==
Aplicación / landing demo : http://203.0.113.10:8080
Grafana                   : http://203.0.113.10:3000
Jaeger                    : http://203.0.113.10:16686

Los secretos (GF_SECURITY_ADMIN_PASSWORD, FAULT_ADMIN_TOKEN) NO se imprimen aquí.
```

## Cómo se generan las credenciales dentro de la VM

`remote-install.sh` copia `.env.example` a `.env` **dentro de la VM** (nunca en tu máquina local ni en
Git) y, solo en ese primer arranque, reemplaza dos valores marcados como `CHANGE_ME`:

- `GF_SECURITY_ADMIN_PASSWORD` (contraseña del usuario admin de Grafana)
- `FAULT_ADMIN_TOKEN` (token para la API administrativa de `payment-service`, header
  `X-Fault-Admin-Token`)

El script remoto genera cada secreto con `openssl rand -base64 24` (o, si `openssl` no está
disponible, con `head -c32 /dev/urandom | base64`) y los escribe con `sed` directamente en el `.env`
remoto. Estos valores **nunca viajan de vuelta** a tu máquina de operador ni se imprimen en la
consola local: todo el heredoc que genera los secretos corre dentro de la sesión SSH, y las variables
en memoria se hacen `unset` inmediatamente después de escribirlas en el archivo.

### Consultar las credenciales de forma segura

Para consultarlas tú mismo (nunca desde un script de CI ni pegarlas en un ticket), usa SSH
directamente:

```bash
# [LOCAL] Password de Grafana
ssh azureuser@<PUBLIC_IP> "grep GF_SECURITY_ADMIN_PASSWORD /opt/f13demo/repo/.env"

# [LOCAL] Token admin de payment-service
ssh azureuser@<PUBLIC_IP> "grep FAULT_ADMIN_TOKEN /opt/f13demo/repo/.env"
```

Salida esperada aproximada:

```text
GF_SECURITY_ADMIN_PASSWORD=Ax7...(valor real generado en tu VM)...
```

Estos comandos no quedan expuestos en la salida de `remote-install.sh` ni en ningún log versionado;
solo aparecen si tú los ejecutas manualmente y miras tu propia terminal.

## Paso 2: `smoke-test.sh` `[LOCAL]`

Aunque `remote-install.sh` ya corre un smoke test dentro de la VM como parte de su Paso 11, puedes (y
debes, antes de una demo) volver a correrlo tú mismo contra la IP pública, para validar exactamente lo
que un asistente vería desde fuera:

```bash
# [LOCAL] Prueba contra la IP pública (usa .f13demo-state.env automáticamente)
bash scripts/smoke-test.sh

# [LOCAL] ayuda
bash scripts/smoke-test.sh --help
```

`smoke-test.sh` valida, en orden: `GET /health` de `shop-api`, `POST /checkout` (HTTP 200 con campo
`"outcome"`), `GET /api/health` de Grafana y `GET /` de Jaeger UI (HTTP 200). Prometheus (9090) solo
se valida cuando el script corre con `TARGET_HOST=localhost` (dentro de la VM), porque ese puerto
nunca se expone a Internet.

Salida esperada aproximada:

```text
[INFO ] Ejecutando smoke test contra TARGET_HOST=203.0.113.10
[INFO ] OK: shop-api /health -> 200
[INFO ] OK: shop-api /checkout -> 200 con campo "outcome"
[INFO ] 3/5: omitido (Prometheus no está expuesto públicamente; solo se valida con TARGET_HOST=localhost).
[INFO ] OK: Grafana /api/health respondió correctamente.
[INFO ] OK: Jaeger UI -> 200
[INFO ] Smoke test completo: todas las verificaciones pasaron.
```

## Tabla de URLs finales

| Servicio | URL | Puerto | Acceso |
|---|---|---|---|
| Aplicación / landing demo (`shop-api`) | `http://<PUBLIC_IP>:8080` | 8080 (host) → 8000 (contenedor) | Restringido a `ADMIN_CIDR` en el NSG |
| Grafana | `http://<PUBLIC_IP>:3000` | 3000 | Restringido a `ADMIN_CIDR` en el NSG |
| Jaeger UI | `http://<PUBLIC_IP>:16686` | 16686 | Restringido a `ADMIN_CIDR` en el NSG |
| Prometheus | `http://localhost:9090` (solo dentro de la VM) | 9090 | Nunca expuesto a Internet |
| SSH | `ssh azureuser@<PUBLIC_IP>` | 22 | Restringido a `ADMIN_CIDR` en el NSG |

Para recuperar rápidamente estas URLs más adelante (por ejemplo, justo antes de salir a escena), usa:

```bash
# [LOCAL]
bash scripts/show-urls.sh
```

## Referencias

- Docker Engine — instalación en Ubuntu: https://docs.docker.com/engine/install/ubuntu/
- Docker Compose — referencia CLI: https://docs.docker.com/compose/
- Grafana — provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/
- OpenSSL — `rand`: https://docs.openssl.org/master/man1/openssl-rand/
