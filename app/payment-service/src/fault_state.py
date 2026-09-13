"""Estado de la falla inyectada de payment-service.

Vive en memoria del proceso (protegido con un lock) e INACTIVO por defecto,
sin importar lo que diga un archivo de estado previo: cada arranque de
contenedor es un lab "limpio" (ver decisión documentada abajo). El archivo
`/tmp/f13-fault-state.json` se reescribe en cada cambio para que el estado
sea inspeccionable manualmente (`cat /tmp/f13-fault-state.json` dentro del
contenedor) o para futuras herramientas de reinicio.
"""

import json
import os
import threading
from dataclasses import asdict, dataclass

STATE_FILE_PATH = "/tmp/f13-fault-state.json"


@dataclass
class FaultState:
    active: bool
    latency_ms: int
    error_rate: float


class FaultStateStore:
    """Contenedor thread-safe del estado de la falla."""

    def __init__(self, initial: FaultState, state_file: str = STATE_FILE_PATH):
        self._lock = threading.Lock()
        self._state = initial
        self._state_file = state_file
        self._persist()

    def snapshot(self) -> FaultState:
        with self._lock:
            return FaultState(**asdict(self._state))

    def update(self, active: bool | None = None, latency_ms: int | None = None, error_rate: float | None = None) -> FaultState:
        with self._lock:
            if active is not None:
                self._state.active = active
            if latency_ms is not None:
                self._state.latency_ms = latency_ms
            if error_rate is not None:
                self._state.error_rate = error_rate
            self._persist()
            return FaultState(**asdict(self._state))

    def _persist(self) -> None:
        try:
            with open(self._state_file, "w", encoding="utf-8") as fh:
                json.dump(asdict(self._state), fh)
        except OSError:
            # No es crítico para el funcionamiento del servicio: el archivo es
            # solo para inspección/depuración local.
            pass


def build_initial_state_from_env() -> FaultState:
    """Decisión de diseño: `active` SIEMPRE arranca en False, sin importar el
    contenido previo de `/tmp/f13-fault-state.json`. Solo `/admin/fault`
    (POST) puede activarla. `latency_ms`/`error_rate` sí toman su valor
    inicial de las variables de entorno para que el operador de la demo no
    tenga que repetirlos en cada llamada admin si no quiere.
    """
    return FaultState(
        active=False,
        latency_ms=int(os.environ.get("FAULT_LATENCY_MS", "1800")),
        error_rate=float(os.environ.get("FAULT_ERROR_RATE", "0.30")),
    )
