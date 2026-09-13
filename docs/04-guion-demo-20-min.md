# 04. Guion de demo de 20 minutos

Guion operativo para la demo en vivo de la charla "Observabilidad que sí paga: del dashboard bonito al
impacto en el negocio". Todos los comandos indican si se ejecutan `[LOCAL]` (tu laptop) o
`[VM f13demo]` (dentro de la VM, normalmente a través de un `ssh azureuser@<PUBLIC_IP>` ya abierto en
una terminal). Todas las salidas mostradas aquí son **"salida esperada aproximada"**, no capturas
reales.

> Recordatorio para el expositor: absolutamente todos los valores monetarios que aparecen en pantalla
> (ingreso en riesgo, pérdida por degradación, pérdida acumulada) son **ilustrativos**, calculados con
> los valores de ejemplo de `.env.example`. Dilo en voz alta al menos una vez durante la demo.

Antes de empezar, deja abierto en el navegador (ver checklist T-2 min):

- Pestaña A: Grafana → dashboard **"F13 | Salud técnica"**
- Pestaña B: Grafana → dashboard **"F13 | Impacto en el negocio"**
- Pestaña C: Jaeger UI (`http://<PUBLIC_IP>:16686`)
- Terminal con sesión SSH ya abierta a `f13demo` (o lista para abrir con `ssh azureuser@<PUBLIC_IP>`)

## Guion minuto a minuto

### 00:00–02:00 — Objetivo y arquitectura

- Qué mostrar: diagrama `docs/images/architecture.png` (o el slide equivalente de la presentación).
- Frase sugerida: "Vamos a ver un sistema de e-commerce de juguete, 100% open source, donde una falla
  técnica en el servicio de pagos se traduce, en segundos, en un número en dólares. Todos los valores
  de negocio que verán son ilustrativos: el objetivo es el método, no los números."
- Comando: ninguno todavía.
- Plan B: si la pantalla compartida falla, describe verbalmente las 3 zonas del diagrama (cliente/
  operador, Azure/VM, servicios) mientras se resuelve.

### 02:00–05:00 — Tráfico saludable y trazas

- Qué mostrar: pestaña C (Jaeger UI). Busca el servicio `shop-api`, últimas trazas.
- Comando (opcional, para confirmar tráfico vivo):

  ```bash
  # [LOCAL]
  bash scripts/demo-start.sh
  ```

  Salida esperada aproximada: tabla `docker compose ps` con todos los contenedores `Up`/`healthy` y
  el bloque `== Estado inicial esperado ==` con `f13_fault_active = 0`.
- Frase sugerida: "Aquí ya hay tráfico continuo generado por `load-generator`. Cada compra exitosa deja
  una traza completa `shop-api -> payment-service`, correlacionada con OpenTelemetry."
- Plan B: si Jaeger no muestra trazas nuevas, sigue con logs de `load-generator`:
  `ssh azureuser@<PUBLIC_IP> "cd /opt/f13demo/repo && docker compose logs -f --tail=20 load-generator"`
  `[VM f13demo]` (ver también `docs/08-troubleshooting.md`, "Jaeger sin trazas").

### 05:00–08:00 — Dashboard técnico, SLIs/SLO

- Qué mostrar: pestaña A, dashboard **"F13 | Salud técnica"**, filas "Checkout", "Pagos" y "SLIs, SLO
  y error budget".
- Paneles a señalar explícitamente: "Throughput de checkout (por resultado)", "Tasa de error de
  checkout (ventana 5m)", "Latencia de checkout p50 / p95 / p99", "SLI técnico (checkouts < 1s /
  total, 5m)", "SLI de negocio (checkouts exitosos / total, 5m)", "Error budget restante", "SLO
  objetivo / burn rate instantáneo".
- Frase sugerida: "Definimos un SLI técnico —proporción de checkouts que responden por debajo de 1
  segundo— y un SLI de negocio —proporción de checkouts que terminan exitosamente—, ambos contra un
  SLO ilustrativo de 99.9%. Ahora mismo el error budget está casi completo porque el sistema está
  sano."
- Ver el detalle completo de estas fórmulas en `docs/06-sli-slo-error-budget.md`.

### 08:00–09:00 — Estado financiero base

- Qué mostrar: pestaña B, dashboard **"F13 | Impacto en el negocio"**, fila superior: "Ingreso en
  riesgo (USD/min)", "Pérdida por degradación (USD/min)", "Pérdida estimada acumulada (USD)".
- Frase sugerida: "Con el sistema sano, el ingreso en riesgo está en, o muy cerca de, cero dólares por
  minuto. Esa es nuestra línea base antes de romper algo."
- Plan B: si `value-exporter` aún no tiene histórico (Prometheus recién arrancó), los paneles pueden
  mostrar "No data" un momento; explica que el scrape tarda unos segundos y continúa con el guion.

### 09:00–10:00 — Inyección de falla

- Comando:

  ```bash
  # [LOCAL]
  bash scripts/inject-fault.sh --yes
  ```

  (usa los defaults del contrato: `FAULT_LATENCY_MS=1800`, `FAULT_ERROR_RATE=0.30` sobre
  `payment-service`). Salida esperada aproximada:

  ```text
  Estado ANTERIOR: {"active":false,...}
  Estado NUEVO: {"active":true,"latency_ms":1800,"error_rate":0.3}
  [INFO ] Falla activa confirmada (f13_fault_active=1). Listo para la demo.
  ```
- Frase sugerida: "Voy a activar, de forma controlada y reversible, 1.8 segundos de latencia extra y
  30% de tasa de error en el servicio de pagos. Nada de esto sale de la VM del laboratorio."
- Plan B: si el comando tarda más de lo esperado en confirmar `f13_fault_active=1`, sigue narrando
  mientras reintenta (hasta 6 intentos de 5s); si falla del todo, revisa
  `docs/08-troubleshooting.md`.

### 10:00–14:00 — Cascada técnica

- Qué mostrar: pestaña A de nuevo — panel "Estado de la falla inyectada (f13_fault_active)" pasa a 1,
  "Tasa de error de checkout" y "Latencia de checkout p50/p95/p99" empiezan a subir, "Throughput y
  errores de payment-service" muestra el pico de errores. Luego cambia a pestaña C (Jaeger) y busca
  una traza reciente con error para mostrar el span rojo en `payment-service`.
- Frase sugerida: "Vean cómo la p95 de checkout empieza a subir casi de inmediato, y cómo la traza
  individual muestra exactamente dónde: el span de `payment-service` marcado como fallido."
- Plan B: si el efecto tarda en verse (ventana de 5 minutos del dashboard), reduce temporalmente el
  rango del panel a "Last 5 minutes" con refresh de 5s, o usa el "ensayo rápido" de abajo para
  practicar el timing exacto.

### 14:00–17:00 — Impacto financiero en tiempo real

- Qué mostrar: pestaña B — "Ingreso en riesgo (USD/min)" y "Pérdida por degradación (USD/min)" suben
  en paralelo a la cascada técnica; panel "Correlación técnica <-> financiera" / "Overlay: latencia
  p95, tasa de error e ingreso en riesgo" muestra las tres curvas superpuestas.
- Frase sugerida: "Esto es lo que un dashboard técnico no te da: mientras la p95 y la tasa de error
  suben, este panel traduce lo mismo a 'cuánto ingreso se está jugando la empresa ahora mismo', minuto
  a minuto. Y aquí abajo, la nota: son valores ilustrativos, para demostrar el método."
- Referencia numérica de apoyo (ver `docs/05-modelo-financiero.md` para el cálculo completo): con
  `FAULT_ERROR_RATE=0.30`, `REQUESTS_PER_MINUTE=120` y `AVERAGE_REQUEST_VALUE_USD=50`, el ingreso en
  riesgo ilustrativo ronda **1800 USD/min**.

### 17:00–18:30 — Recuperación

- Comando:

  ```bash
  # [LOCAL]
  bash scripts/recover.sh
  ```

  Salida esperada aproximada:

  ```text
  Estado ANTERIOR: {"active":true,...}
  Estado NUEVO: {"active":false}
  [INFO ] Recuperación confirmada (f13_fault_active=0).
  ```
- Frase sugerida: "Desactivo la falla sin reiniciar nada del stack. Observen cómo el error budget deja
  de consumirse y el ingreso en riesgo empieza a caer de vuelta hacia cero."
- Qué mostrar: pestaña A y B de nuevo, curvas volviendo a la normalidad en los próximos ciclos de
  scrape (5s).
- Plan B: si algún panel no vuelve a 0 de inmediato, recuerda en voz alta que las ventanas móviles de
  5 minutos tardan en "vaciarse" del todo; no es un error, es la ventana acelerada de demostración
  (ver `docs/06-sli-slo-error-budget.md`).

### 18:30–20:00 — Marco replicable y cierre

- Qué mostrar: slide de cierre con el repositorio `https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga`.
- Frase sugerida: "Todo lo que vieron —el modelo financiero, los dashboards, los scripts de
  despliegue— está en este repositorio, con Azure CLI, Docker Compose y OpenTelemetry. Pueden
  levantarlo con su propia suscripción y adaptar las fórmulas a sus propios supuestos de negocio."
- Cierre: agradecimiento + espacio para preguntas (10 min reservados aparte de esta demo de 20 min).

## Modo "ensayo rápido" (~5 minutos)

Versión comprimida para practicar el timing de la inyección de falla sin repetir todo el guion:

1. `bash scripts/demo-reset.sh` `[LOCAL]` — deja todo en estado limpio (recupera falla + resetea
   acumulador + smoke test).
2. Muestra 30s el dashboard "F13 | Impacto en el negocio" en estado sano.
3. `bash scripts/inject-fault.sh --yes` `[LOCAL]`.
4. Observa 2 minutos la cascada técnica y financiera en paralelo (pestañas A y B).
5. `bash scripts/recover.sh` `[LOCAL]`.
6. Observa 1 minuto la recuperación.
7. `bash scripts/demo-reset.sh` `[LOCAL]` de nuevo, para dejar todo listo para el siguiente ensayo o
   para la demo real.

## Checklist antes de salir a escena

### T-30 minutos

- [ ] VM `f13demo` encendida: `bash infra/azure/status.sh` `[LOCAL]` muestra `PowerState/running`.
- [ ] `bash scripts/demo-start.sh` `[LOCAL]` confirma todos los contenedores `Up`/`healthy`.
- [ ] `bash scripts/smoke-test.sh` `[LOCAL]` termina en verde.
- [ ] `bash scripts/demo-reset.sh` `[LOCAL]` ejecutado (falla recuperada, acumulador en 0).
- [ ] Credenciales de Grafana a mano si hace falta iniciar sesión (ver `docs/03-instalacion-demo.md`).

### T-10 minutos

- [ ] Pestañas del navegador abiertas y ya autenticadas: Grafana (ambos dashboards) y Jaeger UI.
- [ ] Terminal con sesión SSH a `f13demo` ya abierta (evita el delay de la primera conexión en vivo).
- [ ] Conexión a internet probada (recarga forzada de las 3 pestañas).
- [ ] Brillo de pantalla y modo "no molestar"/notificaciones apagadas.
- [ ] Zoom de navegador ajustado para que los paneles se lean desde el fondo de la sala.

### T-2 minutos

- [ ] `bash scripts/demo-reset.sh` `[LOCAL]` una última vez (por si hubo un ensayo justo antes).
- [ ] `f13_fault_active = 0` confirmado visualmente en el dashboard técnico.
- [ ] Terminal en la carpeta del repo, lista para pegar `bash scripts/inject-fault.sh --yes`.
- [ ] Cronómetro o reloj visible para seguir los tiempos de este guion.

## Referencias

- Grafana — dashboards y paneles: https://grafana.com/docs/grafana/latest/dashboards/
- Jaeger — UI de trazas: https://www.jaegertracing.io/docs/
