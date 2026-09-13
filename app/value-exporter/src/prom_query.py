"""Cliente mínimo para la API HTTP de consultas instantáneas de Prometheus."""

import httpx


async def query_instant(client: httpx.AsyncClient, base_url: str, promql: str) -> float | None:
    """Ejecuta una consulta instantánea (`/api/v1/query`) y devuelve el
    primer valor numérico del vector resultado.

    Devuelve:
    - `float` con el valor (0.0 si la consulta es válida pero sin series,
      p.ej. aún no hay tráfico).
    - `None` si hubo un error de red/HTTP/parseo (el llamador debe mantener
      el último valor conocido en ese caso, no asumir 0).
    """
    try:
        resp = await client.get(f"{base_url}/api/v1/query", params={"query": promql}, timeout=4.0)
        resp.raise_for_status()
        data = resp.json()
        result = data.get("data", {}).get("result", [])
        if not result:
            return 0.0
        # Se espera una serie ya agregada (sum()/max()), tomamos la primera.
        _timestamp, value_str = result[0]["value"]
        return float(value_str)
    except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError):
        return None
