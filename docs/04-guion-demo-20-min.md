# 04. Guion de demo de 20 minutos

Guion operativo para la demo en vivo de la charla "Observabilidad que sí paga: del dashboard bonito al
impacto en el negocio". Todo corre en un **GitHub Codespace**: los comandos se pegan en la terminal del
Codespace y las webs se abren desde la pestaña **PORTS** (o con `bash scripts/show-urls.sh`). Las
salidas mostradas son **"salida esperada aproximada"**, no capturas reales.

> Recordatorio para el expositor: absolutamente todos los valores monetarios que aparecen en pantalla
> (ingreso en riesgo, pérdida por degradación, pérdida acumulada) son **ilustrativos**, calculados con
> los valores de ejemplo de `.env.example`. Dilo en voz alta al menos una vez durante la demo.

Antes de empezar, deja abierto en el navegador (ver checklist T-2 min):

- Pestaña A: Grafana → dashboard **"F13 | Salud tecnica"**
- Pestaña B: Grafana → dashboard **"F13 | Impacto en el negocio"**
- Pestaña C: Jaeger UI (puerto `16686`)
- Pestaña D: el Codespace (VS Code web) con la terminal dividida en dos:
  - Terminal 1: `watch -n 5 bash scripts/business-snapshot.sh`
  - Terminal 2: lista para pegar `bash scripts/inject-fault.sh --yes`

## Guion minuto a minuto

### 00:00-02:00 - Objetivo y arquitectura

- Qué mostrar: diagrama `docs/images/architecture.png` (o el slide equivalente de la presentación).
- Frase sugerida: "Vamos a ver un sistema de e-commerce de juguete, 100% open source, corriendo
  completo en un GitHub Codespace, donde una falla técnica en el servicio de pagos se traduce, en
  segundos, en un número en dólares. Todos los valores de negocio que verán son ilustrativos: el
  objetivo es el método, no los números."
- Comando: ninguno todavía.
- Plan B: si la pantalla compartida falla, describe verbalmente las 3 zonas del diagrama (tu
  navegador, el Codespace con Docker-in-Docker, los servicios) mientras se resuelve.

### 02:00-05:00 - Tráfico saludable y trazas

- Qué mostrar: pestaña C (Jaeger UI). Busca el servicio `shop-api`, últimas trazas.
- Comando (opcional, para confirmar que todo está arriba):

  ```bash
  bash scripts/status.sh
  ```

  Salida esperada aproximada: tabla de contenedores en `running` con `(healthy)` y la falla con
  `"active":false`.
- Frase sugerida: "Aquí ya hay tráfico continuo generado por `load-generator`. Cada compra deja una
  traza completa `shop-api -> payment-service`, correlacionada con OpenTelemetry, y cada log trae su
  `trace_id`."
- Plan B: si Jaeger no muestra trazas nuevas, sigue con los logs del generador:
  `docker compose logs -f --tail=20 load-generator` (ver también `docs/08-troubleshooting.md`,
  "Jaeger sin trazas").

### 05:00-08:00 - Dashboard técnico, SLIs/SLO

- Qué mostrar: pestaña A, dashboard **"F13 | Salud tecnica"**, filas "Checkout", "Pagos" y "SLIs, SLO
  y error budget".
- Paneles a señalar explícitamente: "Throughput de checkout (por resultado)", "Tasa de error de
  checkout (ventana 5m)", "Latencia de checkout p50 / p95 / p99", "SLI tecnico (checkouts < 1s /
  total, 5m)", "SLI de negocio (checkouts exitosos / total, 5m)", "Error budget restante", "SLO
  objetivo / burn rate instantaneo".
- Frase sugerida: "Definimos un SLI técnico (proporción de checkouts que responden por debajo de 1
  segundo) y un SLI de negocio (proporción de checkouts que terminan exitosamente), ambos contra un
  SLO ilustrativo de 99.9%. Ahora mismo el error budget está casi completo porque el sistema está
  sano."
- Ver el detalle completo de estas fórmulas en `docs/06-sli-slo-error-budget.md`.

### 08:00-09:00 - Estado financiero base

- Qué mostrar: pestaña B, dashboard **"F13 | Impacto en el negocio"**, fila superior: "Ingreso en
  riesgo (USD/min)", "Perdida por degradacion (USD/min)", "Perdida estimada acumulada (USD)". Si
  prefieres la terminal, la Terminal 1 muestra lo mismo con `business-snapshot.sh`.
- Frase sugerida: "Con el sistema sano, el ingreso en riesgo está en, o muy cerca de, cero dólares por
  minuto. Esa es nuestra línea base antes de romper algo."
- Plan B: si `value-exporter` aún no tiene histórico (el stack acaba de arrancar), los paneles pueden
  mostrar "No data" un momento; explica que el scrape tarda unos segundos y continúa con el guion.

### 09:00-10:00 - Inyección de falla

- Comando (Terminal 2):

  ```bash
  bash scripts/inject-fault.sh --yes
  ```

  (usa los defaults `FAULT_LATENCY_MS=1800`, `FAULT_ERROR_RATE=0.30` sobre `payment-service`). Salida
  esperada aproximada:

  ```text
  Estado ANTERIOR: {"active":false,"latency_ms":1800,"error_rate":0.3}
  Estado NUEVO: {"active":true,"latency_ms":1800,"error_rate":0.3}
  [INFO ] Falla activa confirmada (f13_fault_active=1).
  ```
- Frase sugerida: "Voy a activar, de forma controlada y reversible, 1.8 segundos de latencia extra y
  30% de tasa de error en el servicio de pagos. La API que lo permite no está publicada: solo se
  llama desde esta terminal y con un token."
- Plan B: si el comando tarda en confirmar `f13_fault_active=1`, sigue narrando mientras reintenta
  (hasta 6 intentos de 5 s); si falla del todo, revisa `docs/08-troubleshooting.md`.

### 10:00-14:00 - Cascada técnica

- Qué mostrar: pestaña A de nuevo - panel "Estado de la falla inyectada (f13_fault_active)" pasa a 1,
  "Tasa de error de checkout" y "Latencia de checkout p50/p95/p99" empiezan a subir, "Throughput y
  errores de payment-service" muestra el pico de errores. Luego cambia a pestaña C (Jaeger): Service
  `payment-service`, Tags `business.payment.outcome=error`, y abre una traza de ~1.8 s.
- Frase sugerida: "Vean cómo la p95 de checkout sube casi de inmediato, y cómo la traza individual
  muestra exactamente dónde: el span de `payment-service`."
- Plan B: si el efecto tarda en verse (ventana de 5 minutos del dashboard), reduce el rango a "Last 5
  minutes" con refresh de 5 s, o apóyate en la Terminal 1 (ventana de 1 minuto).

### 14:00-17:00 - Impacto financiero en tiempo real

- Qué mostrar: pestaña B - "Ingreso en riesgo (USD/min)" y "Perdida por degradacion (USD/min)" suben
  en paralelo a la cascada técnica; el panel "Overlay: latencia p95, tasa de error e ingreso en
  riesgo" muestra las tres curvas superpuestas.
- Frase sugerida: "Esto es lo que un dashboard técnico no te da: mientras la p95 y la tasa de error
  suben, este panel traduce lo mismo a 'cuánto ingreso se está jugando la empresa ahora mismo', minuto
  a minuto. Y aquí abajo, la nota: son valores ilustrativos, para demostrar el método."
- Referencia numérica de apoyo (ver `docs/05-modelo-financiero.md`): con tráfico constante de 120
  checkouts/min, la fórmula daría ~1 800 USD/min de ingreso en riesgo. En la demo verás **cientos** de
  USD/min, porque `load-generator` es un cliente secuencial y la latencia extra reduce el tráfico
  observado: buen momento para decir que "la latencia también se come el tráfico".

### 17:00-18:30 - Recuperación

- Comando (Terminal 2):

  ```bash
  bash scripts/recover.sh
  ```

  Salida esperada aproximada:

  ```text
  Estado ANTERIOR: {"active":true,"latency_ms":1800,"error_rate":0.3}
  Estado NUEVO: {"active":false,"latency_ms":1800,"error_rate":0.3}
  [INFO ] Recuperación confirmada (f13_fault_active=0).
  ```
- Frase sugerida: "Desactivo la falla sin reiniciar nada del stack. Observen cómo el error budget deja
  de consumirse y el ingreso en riesgo cae de vuelta hacia cero. La pérdida acumulada se queda: es el
  costo total del incidente."
- Plan B: si algún panel no vuelve a 0 de inmediato, recuerda en voz alta que las ventanas móviles de
  1-5 minutos tardan en "vaciarse" del todo; no es un error, es la ventana acelerada de demostración
  (ver `docs/06-sli-slo-error-budget.md`).

### 18:30-20:00 - Marco replicable y cierre

- Qué mostrar: slide de cierre con el repositorio `https://github.com/Edunzz/f13_demo_observabilidad_que_si_paga`.
- Frase sugerida: "Todo lo que vieron (el modelo financiero, los dashboards, los scripts) está en este
  repositorio. Con un clic en 'Open in Codespaces' lo levantan igual que yo, sin instalar nada, y
  pueden cambiar las fórmulas y los supuestos de negocio en `.env`."
- Cierre: agradecimiento + espacio para preguntas (10 min reservados aparte de esta demo de 20 min).

## Modo "ensayo rápido" (~5 minutos)

Versión comprimida para practicar el timing de la inyección de falla sin repetir todo el guion:

1. `bash scripts/demo-reset.sh` - deja todo en estado limpio (recupera falla + resetea acumulador +
   smoke test).
2. Muestra 30 s el dashboard "F13 | Impacto en el negocio" en estado sano.
3. `bash scripts/inject-fault.sh --yes`.
4. Observa 2 minutos la cascada técnica y financiera en paralelo (pestañas A y B, Terminal 1).
5. `bash scripts/recover.sh`.
6. Observa 1 minuto la recuperación.
7. `bash scripts/demo-reset.sh` de nuevo, para dejar todo listo para el siguiente ensayo o para la
   demo real.

## Checklist antes de salir a escena

### T-30 minutos

- [ ] Codespace encendido (si estaba detenido, ábrelo: `lab-up.sh` corre solo al arrancar).
- [ ] `bash scripts/status.sh` muestra todos los contenedores `running`/`healthy`.
- [ ] `bash scripts/smoke-test.sh` termina en verde.
- [ ] `bash scripts/demo-reset.sh` ejecutado (falla recuperada, acumulador en 0).
- [ ] Puertos web en **Public** si vas a compartir URLs con el público (`bash scripts/publish-ports.sh`).
- [ ] Tiempo de inactividad del Codespace mayor que la duración de la charla (GitHub → Settings →
      Codespaces → *Default idle timeout*), para que no se detenga en medio de la demo.

### T-10 minutos

- [ ] Pestañas del navegador abiertas: Grafana (ambos dashboards), Jaeger UI y el Codespace.
- [ ] Terminal 1 con `watch -n 5 bash scripts/business-snapshot.sh` corriendo.
- [ ] Conexión a internet probada (recarga forzada de las pestañas).
- [ ] Brillo de pantalla y modo "no molestar"/notificaciones apagadas.
- [ ] Zoom de navegador y tamaño de fuente de la terminal ajustados para leerse desde el fondo de la sala.

### T-2 minutos

- [ ] `bash scripts/demo-reset.sh` una última vez (por si hubo un ensayo justo antes).
- [ ] `f13_fault_active = 0` confirmado visualmente en el dashboard técnico.
- [ ] Terminal 2 en la raíz del repo, lista para pegar `bash scripts/inject-fault.sh --yes`.
- [ ] Cronómetro o reloj visible para seguir los tiempos de este guion.

## Referencias

- Grafana - dashboards y paneles: https://grafana.com/docs/grafana/latest/dashboards/
- Jaeger - UI de trazas: https://www.jaegertracing.io/docs/
- GitHub Codespaces - tiempo de inactividad: https://docs.github.com/codespaces/setting-your-user-preferences/setting-your-timeout-period-for-github-codespaces
