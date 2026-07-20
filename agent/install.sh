#!/usr/bin/env bash
#
# install.sh
#
# Instala o OTel Collector "agent" em um no do ambiente. Tres papeis:
#   - core  : Zabbix Server  -> otel-agent + zabbix-stats-bridge
#   - proxy : Zabbix Proxy   -> otel-agent + zabbix-stats-bridge
#   - web   : frontend Zabbix (nginx + php-fpm) -> SOMENTE otel-agent
#             (sem bridge, sem StatsAllowedIP - nao e um no Zabbix)
#
# Copia arquivos deste repo e faz substituicao de placeholders (nao gera
# nada via heredoc).
#
# Rode a partir da raiz do repo clonado no proprio no:
#   git clone <repo> && cd zabbix-observability
#   sudo ./agent/install.sh --role core  --gateway-host <ip> --node-name core1
#   sudo ./agent/install.sh --role proxy --gateway-host <ip> --node-name proxy1
#   sudo ./agent/install.sh --role web   --gateway-host <ip> --node-name web1
#
# Idempotente: pode rodar de novo sem duplicar nada.

set -euo pipefail

OTEL_VERSION="0.155.0"
ROLE=""
GATEWAY_HOST=""
NODE_NAME="$(hostname -s)"
ZABBIX_PORT="10051"
BRIDGE_PORT="9998"
PHPFPM_SOCKET="/run/php-fpm/www.sock"
PFE_VERSION="2.2.0"

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
    --phpfpm-socket) PHPFPM_SOCKET="$2"; shift 2 ;;
    *) echo "[erro] Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

if [[ "$ROLE" != "core" && "$ROLE" != "proxy" && "$ROLE" != "web" ]]; then
  echo "[erro] --role precisa ser 'core', 'proxy' ou 'web'" >&2
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
# 1. Checar StatsAllowedIP (apenas core/proxy - web nao e no Zabbix)
# ------------------------------------------------------------------------
if [[ "$ROLE" == "web" ]]; then
  echo "[install] role=web: sem bridge e sem checagem de StatsAllowedIP."
else
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
fi

# ------------------------------------------------------------------------
# 2. Instalar o OTel Collector Contrib (binario) - todos os papeis
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
# 3+4. Bridge + unit systemd (apenas core/proxy)
# ------------------------------------------------------------------------
if [[ "$ROLE" != "web" ]]; then
  echo "[install] Instalando zabbix-stats-bridge.py..."
  install -m 0755 "${SCRIPT_DIR}/zabbix-stats-bridge.py" /usr/local/bin/zabbix-stats-bridge.py

  echo "[install] Gerando unit systemd do bridge..."
  sed \
    -e "s/__ZABBIX_PORT__/${ZABBIX_PORT}/" \
    -e "s/__BRIDGE_PORT__/${BRIDGE_PORT}/" \
    -e "s/__ROLE__/${ROLE}/" \
    -e "s/__NODE_NAME__/${NODE_NAME}/" \
    "${TEMPLATES_DIR}/zabbix-stats-bridge.service" > /etc/systemd/system/zabbix-stats-bridge.service
fi

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
# 6b. php-fpm_exporter (apenas web) - expoe metricas de php-fpm em :9253
#     para o prometheus receiver do otel-agent scrapear. Exige status page
#     habilitado no pool (pm.status_path = /status).
# ------------------------------------------------------------------------
if [[ "$ROLE" == "web" ]]; then
  PFE_BIN="/usr/local/bin/php-fpm_exporter"
  if [[ -x "$PFE_BIN" ]]; then
    echo "[install] php-fpm_exporter ja instalado - pulando download."
  else
    echo "[install] Baixando php-fpm_exporter ${PFE_VERSION}..."
    curl -sSL -o "$PFE_BIN" \
      "https://github.com/hipages/php-fpm_exporter/releases/download/v${PFE_VERSION}/php-fpm_exporter_${PFE_VERSION}_linux_amd64"
    chmod +x "$PFE_BIN"
    echo "[install] php-fpm_exporter instalado em ${PFE_BIN}"
  fi

  echo "[install] Gerando unit systemd do php-fpm_exporter (socket=${PHPFPM_SOCKET})..."
  sed \
    -e "s#__PHPFPM_SOCKET__#${PHPFPM_SOCKET}#" \
    "${TEMPLATES_DIR}/php-fpm-exporter.service" > /etc/systemd/system/php-fpm-exporter.service
fi

# ------------------------------------------------------------------------
# 7. Checagem de porta do bridge (apenas core/proxy)
# ------------------------------------------------------------------------
if [[ "$ROLE" != "web" ]]; then
  # Parar o bridge antes de checar a porta (evita falso-positivo com nossa
  # propria instancia anterior)
  systemctl stop zabbix-stats-bridge.service 2>/dev/null || true

  if ss -tlnH "( sport = :${BRIDGE_PORT} )" 2>/dev/null | grep -q LISTEN; then
    echo "[aviso] A porta ${BRIDGE_PORT} ja esta em uso por outro processo neste host (nao e o nosso bridge):"
    ss -tlnp "( sport = :${BRIDGE_PORT} )" 2>/dev/null || true
    echo "[aviso] Rode de novo com --bridge-port <outra-porta> para evitar conflito."
  fi
fi

# ------------------------------------------------------------------------
# 8. Habilitar e (re)iniciar os servicos
# ------------------------------------------------------------------------
echo "[install] Recarregando systemd e (re)iniciando servicos..."
systemctl daemon-reload
if [[ "$ROLE" == "web" ]]; then
  systemctl enable php-fpm-exporter.service otelcol-agent.service >/dev/null
  systemctl restart php-fpm-exporter.service
  systemctl restart otelcol-agent.service
else
  systemctl enable zabbix-stats-bridge.service otelcol-agent.service >/dev/null
  systemctl restart zabbix-stats-bridge.service
  systemctl restart otelcol-agent.service
fi

sleep 3
echo
echo "[install] Status:"
if [[ "$ROLE" != "web" ]]; then
  systemctl is-active zabbix-stats-bridge.service && echo "  zabbix-stats-bridge: ativo" || echo "  zabbix-stats-bridge: FALHOU"
fi
if [[ "$ROLE" == "web" ]]; then
  systemctl is-active php-fpm-exporter.service && echo "  php-fpm-exporter: ativo" || echo "  php-fpm-exporter: FALHOU"
fi
systemctl is-active otelcol-agent.service && echo "  otelcol-agent: ativo" || echo "  otelcol-agent: FALHOU"

echo
echo "[install] Concluido. Verifique com:"
if [[ "$ROLE" == "web" ]]; then
  echo "  journalctl -u otelcol-agent -u php-fpm-exporter -f"
  echo "  curl -s http://127.0.0.1:9253/metrics | grep phpfpm_up"
  echo "  # nginx: exige stub_status em http://127.0.0.1:8080/nginx_status"
  echo "  # php-fpm: exige 'pm.status_path = /status' no pool + restart do php-fpm"
else
  echo "  curl -s http://127.0.0.1:${BRIDGE_PORT}/metrics | grep zabbix_stats_bridge_up"
  echo "  journalctl -u zabbix-stats-bridge -u otelcol-agent -f"
fi
