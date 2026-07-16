#!/usr/bin/env bash
#
# bootstrap-network.sh
# Cria a rede Docker externa compartilhada entre os stacks de observabilidade.
# Precisa rodar uma única vez, antes de subir qualquer um dos stacks
# (otel-collector, prometheus, loki, grafana).
#
# Idempotente: pode rodar de novo sem efeito colateral se a rede já existir.

set -euo pipefail

NETWORK_NAME="zbx-observability-net"

if docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "[bootstrap-network] Rede '${NETWORK_NAME}' já existe — nada a fazer."
else
  docker network create "${NETWORK_NAME}"
  echo "[bootstrap-network] Rede '${NETWORK_NAME}' criada."
fi
