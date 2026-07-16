#!/usr/bin/env bash
#
# install.sh
#
# Instala o OTel Collector "agent" + o bridge de stats do Zabbix em um
# core ou proxy node, a partir dos arquivos deste repositorio (nao gera
# nada via heredoc - copia e faz substituicao de placeholders).
#
# Rode a partir da raiz do repo clonado no proprio no:
#   git clone <repo> && cd zabbix-observability
#   sudo ./agent/install.sh --role core  --gateway-host <ip> --node-name core1
#   sudo ./agent/install.sh --role proxy --gateway-host <ip> --node-name proxy1
#
# Idempotente: pode rodar de novo sem duplicar nada.

set -euo pipefail

OTEL_VERSION="0.155.0"
ROLE=""
GATEWAY_HOST=""
NODE_NAME="$(hostname -s)"
ZABBIX_PORT="10051"
BRIDGE_PORT="9998"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# ------------------------------------------------------------------------
# 0. Parse de argumentos
# ------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --gateway-host) GATEWAY_HOST="$2"; shift 2 ;;
    --node-name) NODE_NAME="$2"; shift 2 ;;
    --zabbix-port) ZABBIX_PORT="$2"; shift 2 ;;
    --bridge-port) BRIDGE_PORT="$2"; shift 2 ;;
    *) echo "[erro] Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ "$ROLE" != "core" && "$ROLE" != "proxy" ]]; then
  echo "[erro] --role precisa ser 'core' ou 'proxy'" >&2
  exit 1
fi

if [[ -z "$GATEWAY_HOST" ]]; then
  echo "[erro] --gateway-host e obrigatorio (IP do servidor de observabilidade)" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "[erro] Este script precisa rodar como root (sudo)." >&2
  exit 1
fi

echo "[install] role=${ROLE} gateway=${GATEWAY_HOST} node=${NODE_NAME} zabbix_port=${ZABBIX_PORT} bridge_port=${BRIDGE_PORT}"

# ------------------------------------------------------------------------
# 1. Checar StatsAllowedIP (nao editamos automaticamente - ver README)
# ------------------------------------------------------------------------
if [[ "$ROLE" == "core" ]]; then
  ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
else
  ZABBIX_CONF="/etc/zabbix/zabbix_proxy.conf"
fi

if [[ -f "$ZABBIX_CONF" ]]; then
  if ! grep -q '^StatsAllowedIP' "$ZABBIX_CONF"; then
    echo "[aviso] '$ZABBIX_CONF' nao tem StatsAllowedIP configurado."
    echo "[aviso] Adicione 'StatsAllowedIP=127.0.0.1' la (preferencialmente no"
    echo "[aviso] heredoc do setup-core.sh/setup-proxy.sh, para persistir em"
    echo "[aviso] futuras regeracoes) e reinicie o zabbix-server/zabbix-proxy."
  else
    echo "[install] StatsAllowedIP ja configurado em $ZABBIX_CONF"
  fi
else
  echo "[aviso] $ZABBIX_CONF nao encontrado - pulando checagem de StatsAllowedIP"
fi

# ------------------------------------------------------------------------
# 2. Instalar o OTel Collector Contrib (binario)
# ------------------------------------------------------------------------
OTEL_BIN="/usr/local/bin/otelcol-contrib"

if [[ -x "$OTEL_BIN" ]] && "$OTEL_BIN" --version 2>/dev/null | grep -q "$OTEL_VERSION"; then
  echo "[install] otelcol-contrib ${OTEL_VERSION} ja instalado - pulando download."
else
  echo "[install] Baixando otelcol-contrib ${OTEL_VERSION}..."
  TMP_TAR="$(mktemp)"
  curl -sSL -o "$TMP_TAR" \
    "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz"
  tar -xzf "$TMP_TAR" -C /usr/local/bin otelcol-contrib
  chmod +x "$OTEL_BIN"
  rm -f "$TMP_TAR"
  echo "[install] otelcol-contrib instalado em ${OTEL_BIN}"
fi

# ------------------------------------------------------------------------
# 3. Instalar o bridge (copia do repo, sem heredoc)
# ------------------------------------------------------------------------
echo "[install] Instalando zabbix-stats-bridge.py..."
install -m 0755 "${SCRIPT_DIR}/zabbix-stats-bridge.py" /usr/local/bin/zabbix-stats-bridge.py

# ------------------------------------------------------------------------
# 4. Unit systemd do bridge (template com substituicao de placeholders)
# ------------------------------------------------------------------------
echo "[install] Gerando unit systemd do bridge..."
sed \
  -e "s/__ZABBIX_PORT__/${ZABBIX_PORT}/" \
  -e "s/__BRIDGE_PORT__/${BRIDGE_PORT}/" \
  -e "s/__ROLE__/${ROLE}/" \
  -e "s/__NODE_NAME__/${NODE_NAME}/" \
  "${TEMPLATES_DIR}/zabbix-stats-bridge.service" > /etc/systemd/system/zabbix-stats-bridge.service

# ------------------------------------------------------------------------
# 5. Config do OTel Collector agent (template por papel de no)
# ------------------------------------------------------------------------
mkdir -p /etc/otelcol-agent
echo "[install] Gerando config do otelcol-agent (role=${ROLE})..."
sed \
  -e "s/__BRIDGE_PORT__/${BRIDGE_PORT}/" \
  -e "s/__NODE_NAME__/${NODE_NAME}/" \
  -e "s/__GATEWAY_HOST__/${GATEWAY_HOST}/" \
  "${TEMPLATES_DIR}/otel-agent-${ROLE}.yaml" > /etc/otelcol-agent/config.yaml

# ------------------------------------------------------------------------
# 6. Unit systemd do OTel Collector agent (sem placeholders)
# ------------------------------------------------------------------------
install -m 0644 "${TEMPLATES_DIR}/otelcol-agent.service" /etc/systemd/system/otelcol-agent.service

# ------------------------------------------------------------------------
# 7. Parar o bridge antes de checar a porta (evita falso-positivo com
#    nossa propria instancia anterior)
# ------------------------------------------------------------------------
systemctl stop zabbix-stats-bridge.service 2>/dev/null || true

if ss -tlnH "( sport = :${BRIDGE_PORT} )" 2>/dev/null | grep -q LISTEN; then
  echo "[aviso] A porta ${BRIDGE_PORT} ja esta em uso por outro processo neste host (nao e o nosso bridge):"
  ss -tlnp "( sport = :${BRIDGE_PORT} )" 2>/dev/null || true
  echo "[aviso] Rode de novo com --bridge-port <outra-porta> para evitar conflito."
fi

# ------------------------------------------------------------------------
# 8. Habilitar e (re)iniciar os servicos - restart explicito, nao
#    'enable --now' (que nao reaplica binario/config se ja estiver ativo)
# ------------------------------------------------------------------------
echo "[install] Recarregando systemd e (re)iniciando servicos..."
systemctl daemon-reload
systemctl enable zabbix-stats-bridge.service otelcol-agent.service >/dev/null
systemctl restart zabbix-stats-bridge.service
systemctl restart otelcol-agent.service

sleep 3
echo
echo "[install] Status:"
systemctl is-active zabbix-stats-bridge.service && echo "  zabbix-stats-bridge: ativo" || echo "  zabbix-stats-bridge: FALHOU"
systemctl is-active otelcol-agent.service && echo "  otelcol-agent: ativo" || echo "  otelcol-agent: FALHOU"

echo
echo "[install] Concluido. Verifique com:"
echo "  curl -s http://127.0.0.1:${BRIDGE_PORT}/metrics | grep zabbix_stats_bridge_up"
echo "  journalctl -u zabbix-stats-bridge -u otelcol-agent -f"
