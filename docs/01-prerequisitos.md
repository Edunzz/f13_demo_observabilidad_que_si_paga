# 01. Prerrequisitos

El laboratorio F13 se levanta completo dentro de un **GitHub Codespace**. No instalas nada en tu
máquina y no necesitas una suscripción de nube propia.

> Nota: todos los valores de negocio del laboratorio (ingresos, tickets, tasas de conversión) son
> **ilustrativos**. Sirven para demostrar el método, no representan datos de ninguna organización real.

## 1. Una cuenta de GitHub con Codespaces

- Cualquier cuenta personal de GitHub incluye una cuota mensual gratuita de Codespaces (horas de
  núcleo y GB de almacenamiento). La cuota vigente está en la documentación oficial de facturación de
  Codespaces (ver Referencias); no repitas cifras de memoria.
- Si usas una cuenta de organización, la organización debe permitir Codespaces para este repositorio
  y, si quieres compartir las URLs de la demo, **permitir puertos públicos** (ver
  [`07-seguridad.md`](07-seguridad.md)). Si la política los bloquea, el laboratorio funciona igual con
  puertos privados.
- El repositorio es público: basta con acceso de lectura. También puedes hacer *fork* y abrir el
  Codespace desde tu copia.

## 2. Un navegador

Chrome, Edge, Firefox o Safari recientes. El Codespace abre VS Code en el navegador; si prefieres VS
Code de escritorio, instala la extensión **GitHub Codespaces** y conéctate al mismo Codespace.

## 3. Tamaño de máquina

`.devcontainer/devcontainer.json` declara el mínimo con `hostRequirements`:

| Recurso | Mínimo | Por qué |
|---|---|---|
| CPU | 2 núcleos | 8 contenedores livianos (4 apps Python + Collector, Prometheus, Jaeger, Grafana) |
| Memoria | 8 GB | Grafana, Prometheus y Jaeger son los que más consumen |
| Disco | 32 GB | Imágenes base, volúmenes de Prometheus/Jaeger/Grafana y Docker-in-Docker |

La máquina por defecto de Codespaces (2 núcleos, 8 GB, 32 GB) cumple. Una de 4 núcleos acelera el
primer `docker compose build`, pero no es necesaria.

## 4. Lo que NO necesitas

- **Docker, Docker Compose, Python o Git en tu máquina**: todo vive dentro del Codespace
  (Docker-in-Docker, Python 3.12 y GitHub CLI vienen en el devcontainer).
- **Certificados TLS**: los servicios hablan HTTP plano. La URL de port forwarding la sirve GitHub.
- **Crear secretos a mano**: `scripts/setup-env.sh` genera la contraseña de Grafana y el token admin
  de la falla dentro del Codespace.

## Checklist rápido

- [ ] Tengo una cuenta de GitHub con cuota de Codespaces disponible.
- [ ] Puedo abrir el repositorio `Edunzz/f13_demo_observabilidad_que_si_paga` (o mi fork).
- [ ] Si voy a compartir las URLs durante la demo, mi cuenta u organización permite puertos públicos.

Siguiente: [`02-codespaces.md`](02-codespaces.md).

## Referencias

- GitHub Codespaces - documentación: https://docs.github.com/codespaces
- Facturación de Codespaces (cuota incluida y precios): https://docs.github.com/billing/managing-billing-for-your-products/managing-billing-for-github-codespaces/about-billing-for-github-codespaces
- Políticas de organización para Codespaces (visibilidad de puertos): https://docs.github.com/codespaces/managing-codespaces-for-your-organization/restricting-the-visibility-of-forwarded-ports
