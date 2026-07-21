#!/usr/bin/env bash
#
# install.sh
#
# Instala o OTel Collector "agent" (+ bridge/exporters) em um no do ambiente.
# Papeis (--role):
#   core      : Zabbix Server            -> otel + zabbix-stats-bridge
#   proxy     : Zabbix Proxy             -> otel + zabbix-stats-bridge
#   web       : frontend nginx + php-fpm -> otel + php-fpm_exporter
#   core-web  : core que TAMBEM hospeda o frontend (HML) -> otel + bridge + php-fpm_exporter
#   db        : PostgreSQL               -> otel + postgres_exporter
#   witness   : pgpool + pgbouncer       -> otel + pgpool2_exporter + pgbouncer_exporter
#
# Copia arquivos deste repo e faz substituicao de placeholders. Credenciais de
# banco vao para EnvironmentFile (modo 600) em /etc/<exporter>/ - NUNCA no git.
# Idempotente: pode rodar de novo sem duplicar nada.

set -euo pipefail

OTEL_VERSION="0.155.0"
PFE_VERSION="2.2.0"      # php-fpm_exporter
PGE_VERSION="0.20.1"     # postgres_exporter
PBE_VERSION="0.12.1"     # pgbouncer_exporter
PPE_VERSION="1.2.2"      # pgpool2_exporter

ROLE=""
GATEWAY_HOST=""
NODE_NAME="$(hostname -s)"
ZABBIX_PORT="10051"
BRIDGE_PORT="9998"
PHPFPM_SOCKET="/run/php-fpm/www.sock"

# Banco / witness
DB_HOST="127.0.0.1"
DB_PORT="5432"
DB_NAME="postgres"
DB_USER="zbx_observability_monitor"
DB_PASSWORD=""
DB_SSLMODE="disable"
PG_LOG_DIR="/var/lib/pgsql/16/data/log"
PGBOUNCER_PORT="6432"
PGPOOL_PORT="9999"

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
    --db-host) DB_HOST="$2"; shift 2 ;;
    --db-port) DB_PORT="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    --db-sslmode) DB_SSLMODE="$2"; shift 2 ;;
    --pg-log-dir) PG_LOG_DIR="$2"; shift 2 ;;
    --pgbouncer-port) PGBOUNCER_PORT="$2"; shift 2 ;;
    --pgpool-port) PGPOOL_PORT="$2"; shift 2 ;;
    *) echo "[erro] Argumento desconhecido: $1" >&2; exit 1 ;;
  esac
done

case "$ROLE" in
  core|proxy|web|core-web|db|witness) ;;
  *) echo "[erro] --role precisa ser: core|proxy|web|core-web|db|witness" >&2; exit 1 ;;
esac

if [[ -z "$GATEWAY_HOST" ]]; then
  echo "[erro] --gateway-host e obrigatorio (IP do servidor de observabilidade)" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "[erro] Este script precisa rodar como root (sudo)." >&2
  exit 1
fi

# role_has <componente> -> 0 se o papel atual inclui o componente
role_has() {
  case "$1" in
    bridge)    [[ "$ROLE" == "core" || "$ROLE" == "proxy" || "$ROLE" == "core-web" ]] ;;
    phpfpm)    [[ "$ROLE" == "web"  || "$ROLE" == "core-web" ]] ;;
    zabbix)    [[ "$ROLE" == "core" || "$ROLE" == "proxy" || "$ROLE" == "core-web" ]] ;;
    postgres)  [[ "$ROLE" == "db" ]] ;;
    witness)   [[ "$ROLE" == "witness" ]] ;;
    *) return 1 ;;
  esac
}

# O bridge so aceita core|proxy; core-web usa "core"
if [[ "$ROLE" == "core-web" ]]; then BRIDGE_ROLE="core"; else BRIDGE_ROLE="$ROLE"; fi

echo "[install] role=${ROLE} gateway=${GATEWAY_HOST} node=${NODE_NAME}"

# Helper: baixa e instala um exporter (tar.gz com dir/binary) em /usr/local/bin
download_tar_binary() {
  local bin_name="$1" url="$2" tar_path="$3"
  local bin="/usr/local/bin/${bin_name}"
  if [[ -x "$bin" ]]; then
    echo "[install] ${bin_name} ja instalado - pulando download."
    return
  fi
  echo "[install] Baixando ${bin_name}..."
  local tmp; tmp="$(mktemp)"
  curl -sSL -o "$tmp" "$url"
  tar -xzf "$tmp" -C /usr/local/bin --strip-components=1 "$tar_path"
  chmod +x "$bin"
  rm -f "$tmp"
  echo "[install] ${bin_name} instalado em ${bin}"
}

# Helper: exige senha de banco (via --db-password) ou env file ja existente
require_db_password_or_env() {
  local env_file="$1"
  if [[ -n "$DB_PASSWORD" ]]; then return 0; fi
  if [[ -f "$env_file" ]]; then
    echo "[install] --db-password nao informado; mantendo ${env_file} existente."
    return 1
  fi
  echo "[erro] role=${ROLE} exige --db-password (ou um ${env_file} pre-existente)." >&2
  exit 1
}

# ------------------------------------------------------------------------
# 1. StatsAllowedIP (apenas papeis Zabbix)
# ------------------------------------------------------------------------
if role_has zabbix; then
  if [[ "$ROLE" == "proxy" ]]; then
    ZABBIX_CONF="/etc/zabbix/zabbix_proxy.conf"
  else
    ZABBIX_CONF="/etc/zabbix/zabbix_server.conf"
  fi
  if [[ -f "$ZABBIX_CONF" ]]; then
    if ! grep -q '^StatsAllowedIP' "$ZABBIX_CONF"; then
      echo "[aviso] '$ZABBIX_CONF' nao tem StatsAllowedIP. Adicione 'StatsAllowedIP=127.0.0.1'"
      echo "[aviso] no heredoc do setup-core.sh/setup-proxy.sh e reinicie o zabbix."
    else
      echo "[install] StatsAllowedIP ja configurado em $ZABBIX_CONF"
    fi
  else
    echo "[aviso] $ZABBIX_CONF nao encontrado - pulando checagem de StatsAllowedIP"
  fi
else
  echo "[install] role=${ROLE}: sem bridge/StatsAllowedIP (nao e no Zabbix)."
fi

# ------------------------------------------------------------------------
# 2. OTel Collector Contrib (todos)
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
# 3. Bridge de stats (papeis Zabbix)
# ------------------------------------------------------------------------
if role_has bridge; then
  echo "[install] Instalando zabbix-stats-bridge.py..."
  install -m 0755 "${SCRIPT_DIR}/zabbix-stats-bridge.py" /usr/local/bin/zabbix-stats-bridge.py
  echo "[install] Gerando unit systemd do bridge..."
  sed \
    -e "s/__ZABBIX_PORT__/${ZABBIX_PORT}/" \
    -e "s/__BRIDGE_PORT__/${BRIDGE_PORT}/" \
    -e "s/__ROLE__/${BRIDGE_ROLE}/" \
    -e "s/__NODE_NAME__/${NODE_NAME}/" \
    "${TEMPLATES_DIR}/zabbix-stats-bridge.service" > /etc/systemd/system/zabbix-stats-bridge.service
fi

# ------------------------------------------------------------------------
# 4. php-fpm_exporter (web / core-web)
# ------------------------------------------------------------------------
if role_has phpfpm; then
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
  sed -e "s#__PHPFPM_SOCKET__#${PHPFPM_SOCKET}#" \
    "${TEMPLATES_DIR}/php-fpm-exporter.service" > /etc/systemd/system/php-fpm-exporter.service
fi

# ------------------------------------------------------------------------
# 5. postgres_exporter (db)
# ------------------------------------------------------------------------
if role_has postgres; then
  download_tar_binary "postgres_exporter" \
    "https://github.com/prometheus-community/postgres_exporter/releases/download/v${PGE_VERSION}/postgres_exporter-${PGE_VERSION}.linux-amd64.tar.gz" \
    "postgres_exporter-${PGE_VERSION}.linux-amd64/postgres_exporter"

  PGE_ENV="/etc/postgres-exporter/postgres_exporter.env"
  mkdir -p /etc/postgres-exporter
  if require_db_password_or_env "$PGE_ENV"; then
    echo "[install] Gravando ${PGE_ENV} (modo 600)..."
    umask 077
    cat > "$PGE_ENV" <<EOF
DATA_SOURCE_NAME=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=${DB_SSLMODE}
EOF
    chmod 600 "$PGE_ENV"
  fi
  install -m 0644 "${TEMPLATES_DIR}/postgres-exporter.service" /etc/systemd/system/postgres-exporter.service
fi

# ------------------------------------------------------------------------
# 6. pgpool2_exporter + pgbouncer_exporter (witness)
# ------------------------------------------------------------------------
if role_has witness; then
  download_tar_binary "pgpool2_exporter" \
    "https://github.com/pgpool/pgpool2_exporter/releases/download/v${PPE_VERSION}/pgpool2_exporter-${PPE_VERSION}.linux-amd64.tar.gz" \
    "pgpool2_exporter-${PPE_VERSION}.linux-amd64/pgpool2_exporter"
  download_tar_binary "pgbouncer_exporter" \
    "https://github.com/prometheus-community/pgbouncer_exporter/releases/download/v${PBE_VERSION}/pgbouncer_exporter-${PBE_VERSION}.linux-amd64.tar.gz" \
    "pgbouncer_exporter-${PBE_VERSION}.linux-amd64/pgbouncer_exporter"

  PPE_ENV="/etc/pgpool2-exporter/pgpool2_exporter.env"
  PBE_ENV="/etc/pgbouncer-exporter/pgbouncer_exporter.env"
  mkdir -p /etc/pgpool2-exporter /etc/pgbouncer-exporter
  if require_db_password_or_env "$PPE_ENV"; then
    echo "[install] Gravando env files do witness (modo 600)..."
    umask 077
    cat > "$PPE_ENV" <<EOF
POSTGRES_USERNAME=${DB_USER}
POSTGRES_PASSWORD=${DB_PASSWORD}
POSTGRES_DATABASE=${DB_NAME}
PGPOOL_SERVICE=127.0.0.1
PGPOOL_SERVICE_PORT=${PGPOOL_PORT}
EOF
    cat > "$PBE_ENV" <<EOF
PGBOUNCER_DSN=postgres://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${PGBOUNCER_PORT}/pgbouncer?sslmode=disable
EOF
    chmod 600 "$PPE_ENV" "$PBE_ENV"
  fi
  install -m 0644 "${TEMPLATES_DIR}/pgpool2-exporter.service" /etc/systemd/system/pgpool2-exporter.service
  install -m 0644 "${TEMPLATES_DIR}/pgbouncer-exporter.service" /etc/systemd/system/pgbouncer-exporter.service
fi

# ------------------------------------------------------------------------
# 7. Config do OTel Collector agent (template por papel)
# ------------------------------------------------------------------------
mkdir -p /etc/otelcol-agent
echo "[install] Gerando config do otelcol-agent (role=${ROLE})..."
sed \
  -e "s/__BRIDGE_PORT__/${BRIDGE_PORT}/" \
  -e "s/__NODE_NAME__/${NODE_NAME}/" \
  -e "s/__GATEWAY_HOST__/${GATEWAY_HOST}/" \
  -e "s#__PG_LOG_DIR__#${PG_LOG_DIR}#" \
  "${TEMPLATES_DIR}/otel-agent-${ROLE}.yaml" > /etc/otelcol-agent/config.yaml
install -m 0644 "${TEMPLATES_DIR}/otelcol-agent.service" /etc/systemd/system/otelcol-agent.service

# ------------------------------------------------------------------------
# 8. Checagem de porta do bridge (papeis com bridge)
# ------------------------------------------------------------------------
if role_has bridge; then
  systemctl stop zabbix-stats-bridge.service 2>/dev/null || true
  if ss -tlnH "( sport = :${BRIDGE_PORT} )" 2>/dev/null | grep -q LISTEN; then
    echo "[aviso] Porta ${BRIDGE_PORT} ja em uso por outro processo neste host:"
    ss -tlnp "( sport = :${BRIDGE_PORT} )" 2>/dev/null || true
    echo "[aviso] Rode de novo com --bridge-port <outra-porta>."
  fi
fi

# ------------------------------------------------------------------------
# 9. Habilitar e (re)iniciar os servicos
# ------------------------------------------------------------------------
echo "[install] Recarregando systemd e (re)iniciando servicos..."
systemctl daemon-reload

SERVICES=()
role_has bridge    && SERVICES+=("zabbix-stats-bridge.service")
role_has phpfpm    && SERVICES+=("php-fpm-exporter.service")
role_has postgres  && SERVICES+=("postgres-exporter.service")
role_has witness   && SERVICES+=("pgpool2-exporter.service" "pgbouncer-exporter.service")
SERVICES+=("otelcol-agent.service")

systemctl enable "${SERVICES[@]}" >/dev/null
for svc in "${SERVICES[@]}"; do
  systemctl restart "$svc"
done

sleep 3
echo
echo "[install] Status:"
for svc in "${SERVICES[@]}"; do
  if systemctl is-active --quiet "$svc"; then
    echo "  ${svc}: ativo"
  else
    echo "  ${svc}: FALHOU"
  fi
done

echo
echo "[install] Concluido (role=${ROLE}). Verifique com:"
role_has bridge    && echo "  curl -s http://127.0.0.1:${BRIDGE_PORT}/metrics | grep zabbix_stats_bridge_up"
role_has phpfpm    && echo "  curl -s http://127.0.0.1:9253/metrics | grep phpfpm_up"
role_has postgres  && echo "  curl -s http://127.0.0.1:9187/metrics | grep pg_up"
role_has witness   && echo "  curl -s http://127.0.0.1:9719/metrics | grep pgpool2_up ; curl -s http://127.0.0.1:9127/metrics | grep pgbouncer_up"
echo "  journalctl -u otelcol-agent -f"
