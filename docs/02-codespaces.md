# 02. Cómo está armado el Codespace

Este documento explica qué pasa cuando abres el repositorio en GitHub Codespaces: el devcontainer, el
ciclo de vida que levanta el laboratorio, los puertos y el archivo `.env`.

## Crear el Codespace

- Botón **Abrir en GitHub Codespaces** del `README.md`, o
- En GitHub: **Code → Codespaces → Create codespace on main**, o
- Con GitHub CLI desde tu máquina: `gh codespace create -R Edunzz/f13_demo_observabilidad_que_si_paga`.

## El devcontainer (`.devcontainer/devcontainer.json`)

| Elemento | Valor | Para qué |
|---|---|---|
| Imagen | `mcr.microsoft.com/devcontainers/python:1-3.12-bookworm` | Debian 12 con Python 3.12, `make`, `curl`, `git` |
| Feature | `docker-in-docker:2` | Docker Engine + Compose v2 **dentro** del Codespace |
| Feature | `github-cli:1` | `gh`, usado por `scripts/publish-ports.sh` |
| `hostRequirements` | 2 CPU, 8 GB, 32 GB | Mínimo para los 8 contenedores |
| `forwardPorts` | `3000`, `16686`, `9090`, `8080` | Las 4 webs del laboratorio, con etiqueta en la pestaña PORTS |
| `portsAttributes.*.protocol` | `http` | Los servicios hablan HTTP plano; Codespaces no espera TLS del backend |
| `otherPortsAttributes` | `ignore` | `8001` y `9200` (APIs admin) no se reenvían |

**¿Por qué Docker-in-Docker?** Con el daemon de Docker corriendo dentro del Codespace, las rutas
relativas de `compose.yaml` (`./observability/...`) y los puertos publicados (`localhost:3000`, etc.)
son los del propio Codespace. Así el mismo `compose.yaml` sirve para el Codespace y para el CI.

## Ciclo de vida: qué se ejecuta solo

| Momento | Comando | Script | Qué hace |
|---|---|---|---|
| Al crear el Codespace (una vez) | `postCreateCommand` | `scripts/setup-env.sh` | Crea `.env` desde `.env.example`, genera secretos y ajusta `GF_SERVER_ROOT_URL` a la URL del Codespace |
| Cada vez que el Codespace arranca | `postStartCommand` | `scripts/lab-up.sh` | Espera a Docker, `docker compose up -d --build`, espera healthchecks, smoke test, publica los puertos web e imprime URLs |

La primera vez tarda 3–5 minutos (descarga de imágenes y build de las 4 apps). Los arranques
siguientes reutilizan las imágenes y tardan menos de un minuto.

El resultado del `postStartCommand` aparece en una terminal del Codespace. Si la cerraste o quieres
confirmar el estado:

```bash
bash scripts/status.sh
```

Si algo falló, vuelve a correr `bash scripts/lab-up.sh`: es idempotente.

## Puertos y URLs

| Puerto | Servicio | Etiqueta en PORTS | Visibilidad tras `lab-up.sh` |
|---|---|---|---|
| `3000` | Grafana | *Grafana (dashboards)* | Public |
| `16686` | Jaeger UI | *Jaeger (trazas)* | Public |
| `9090` | Prometheus | *Prometheus (PromQL)* | Public |
| `8080` | shop-api (Swagger en `/docs`) | *shop-api (Swagger en /docs)* | Public |
| `8001` | API admin de `payment-service` | — | No se reenvía |
| `9200` | API admin y `/metrics` de `value-exporter` | — | No se reenvía |

- Los servicios hablan **HTTP plano**; no hay TLS en el laboratorio.
- La URL de cada puerto tiene la forma `<codespace>-<puerto>.app.github.dev`. Es el proxy de port
  forwarding de GitHub, que GitHub sirve siempre con su propio `https` en el borde. No hay nada que
  configurar del lado del laboratorio.
- `scripts/publish-ports.sh` cambia la visibilidad a **Public** con
  `gh codespace ports visibility` para que puedas compartir las URLs durante la demo.
  `bash scripts/publish-ports.sh --private` las vuelve a privadas (solo tu cuenta de GitHub).
- `bash scripts/show-urls.sh` imprime las URLs completas, incluidos los enlaces directos a los dos
  dashboards.

## El archivo `.env`

`scripts/setup-env.sh` crea `.env` (ignorado por Git, permisos `600`) a partir de `.env.example`:

- Reemplaza `CHANGE_ME` de `GF_SECURITY_ADMIN_PASSWORD` y `FAULT_ADMIN_TOKEN` por secretos aleatorios
  (`openssl rand -hex 24`). Nunca los imprime.
- En Codespaces ajusta `GF_SERVER_ROOT_URL` a la URL de port forwarding de Grafana, para que los
  enlaces y el WebSocket de Grafana Live usen la URL correcta.
- Si `.env` ya existe, lo conserva y solo agrega claves nuevas de `.env.example`.

Las variables y su efecto están en [`03-operacion-scripts.md`](03-operacion-scripts.md).

## Reconstruir o empezar de cero

| Quiero... | Comando |
|---|---|
| Reiniciar los servicios | `docker compose restart` |
| Aplicar cambios de `.env` | `docker compose up -d` |
| Reconstruir las apps tras editar `app/*` | `docker compose up -d --build` |
| Borrar métricas, trazas y estado de Grafana | `docker compose down -v && bash scripts/lab-up.sh` |
| Reconstruir el devcontainer (tras editar `.devcontainer/`) | Paleta de comandos → **Codespaces: Rebuild Container** |

## Fuera de Codespaces

El mismo devcontainer funciona con VS Code + la extensión **Dev Containers** (*Reopen in Container*)
sobre Docker Desktop: los scripts detectan que no están en Codespaces y usan `http://localhost:<puerto>`.

## Referencias

- Dev containers en Codespaces: https://docs.github.com/codespaces/setting-up-your-project-for-codespaces/adding-a-dev-container-configuration/introduction-to-dev-containers
- Especificación `devcontainer.json`: https://containers.dev/implementors/json_reference/
- Feature Docker-in-Docker: https://github.com/devcontainers/features/tree/main/src/docker-in-docker
- Port forwarding en Codespaces: https://docs.github.com/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace
- `gh codespace ports`: https://cli.github.com/manual/gh_codespace_ports
