# Imagen base del Codespace del laboratorio F13 (Debian 12 + Python 3.12).
FROM mcr.microsoft.com/devcontainers/python:1-3.12-bookworm

# La imagen trae un repositorio APT de Yarn cuya llave GPG ya no verifica
# ("NO_PUBKEY 62D54FD4003F6525"). Con él presente, el `apt-get update` de la
# feature docker-in-docker falla y el devcontainer no se construye. El
# laboratorio no usa Yarn, así que se elimina ese repositorio.
RUN for f in /etc/apt/sources.list.d/*; do \
        if grep -q 'dl.yarnpkg.com' "$f" 2>/dev/null; then rm -f "$f"; fi; \
    done
