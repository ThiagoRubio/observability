# Manual de Instalação — Agentes de Observabilidade (do zero)

Runbook para instalar os agentes em cada tipo de nó. Feito para ser seguido
**em tempo real, de cima para baixo**. Cada seção tem: pré-requisitos →
instalação → validação (com a saída esperada).

- **Gateway (servidor de observabilidade):** `10.55.0.155` (`sv-tools-dev02`)
- **Usuário de monitoração do banco:** `zbx_observability_monitor`
- **Senha:** troque `<SENHA>` pela senha real (nunca fica no git — vai em `EnvironmentFile` 600)

> Papéis: `core-web` (HML: core+frontend), `proxy`, `db`, `witness`.
> Em **PROD** o web é separado: use `core` e `web` no lugar de `core-web`.

---

## 0. Pré-requisitos comuns (todo nó)

1. Rodar como **root**.
2. O nó precisa alcançar o gateway na porta OTLP:
   ```bash
   nc -vz 10.55.0.155 4317        # tem que dar "succeeded"
   ```
3. Clonar o repositório (o nó tem egress pro GitHub):
   ```bash
   cd /root
   git clone https://github.com/ThiagoRubio/observability.git
   cd observability
   ```
   > Se já existe a pasta: `cd observability && git pull`.

O `install.sh` é **idempotente** — pode rodar de novo sem duplicar nada.

---

## 1. CORE + WEB (HML) — `--role core-web`

Nó que é Zabbix Server **e** hospeda o frontend (nginx + php-fpm).

### 1.1 Pré-requisitos
```bash
# a) StatsAllowedIP no zabbix_server.conf (+ restart). Confirme tambem o ListenPort.
grep -E '^StatsAllowedIP|^ListenPort' /etc/zabbix/zabbix_server.conf
# se faltar StatsAllowedIP:
echo 'StatsAllowedIP=127.0.0.1' >> /etc/zabbix/zabbix_server.conf
systemctl restart zabbix-server
# (persistir: adicionar tambem no heredoc do setup-core.sh)

# b) nginx stub_status em 127.0.0.1:8080
cat > /etc/nginx/conf.d/stub_status.conf <<'EOF'
server {
    listen 127.0.0.1:8080;
    location /nginx_status { stub_status; access_log off; }
    location / { return 404; }
}
EOF
nginx -t
systemctl enable --now nginx        # sobe/habilita se nao estiver rodando
systemctl reload nginx              # aplica o stub_status
curl -s http://127.0.0.1:8080/nginx_status      # deve responder "Active connections: ..."

# c) php-fpm status page
sed -i 's|^;*\s*pm.status_path\s*=.*|pm.status_path = /status|' /etc/php-fpm.d/www.conf
grep -q '^pm.status_path' /etc/php-fpm.d/www.conf || echo 'pm.status_path = /status' >> /etc/php-fpm.d/www.conf
systemctl restart php-fpm
```

### 1.2 Instalar (ajuste `--zabbix-port` ao ListenPort real — nos cores costuma ser 10080)
```bash
sudo ./agent/install.sh --role core-web \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) --zabbix-port 10080
```

### 1.3 Validar
```bash
curl -s http://127.0.0.1:9998/metrics | grep zabbix_stats_bridge_up   # 1 (ou 0 se HA standby)
curl -s http://127.0.0.1:9253/metrics | grep phpfpm_up                # phpfpm_up ... 1
curl -s http://127.0.0.1:8080/nginx_status
systemctl is-active otelcol-agent zabbix-stats-bridge php-fpm-exporter
```
Esperado: os 3 serviços `active`. Se o bridge vier `0`, veja o Troubleshooting.

> **PROD:** rode `--role core` no core e `--role web` no web (dois nós). O resto igual.

---

## 2. PROXY — `--role proxy`

### 2.1 Pré-requisitos
```bash
# StatsAllowedIP + ListenPort do proxy (padrao 10051, mas CONFIRME)
grep -E '^StatsAllowedIP|^ListenPort' /etc/zabbix/zabbix_proxy.conf
# se faltar StatsAllowedIP:
echo 'StatsAllowedIP=127.0.0.1' >> /etc/zabbix/zabbix_proxy.conf
systemctl restart zabbix-proxy
```

### 2.2 Instalar (acrescente `--zabbix-port <porta>` se o ListenPort nao for 10051)
```bash
sudo ./agent/install.sh --role proxy \
  --gateway-host 10.55.0.155 --node-name $(hostname -s)
```

### 2.3 Validar
```bash
curl -s http://127.0.0.1:9998/metrics | grep -E 'zabbix_stats_bridge_up|last_error'
# esperado: zabbix_stats_bridge_up{role="proxy",node="..."} 1
systemctl is-active otelcol-agent zabbix-stats-bridge
```

---

## 3. BANCO PostgreSQL — `--role db`  (ex.: 10.55.0.134, 10.55.0.135)

### 3.1 Pré-requisitos (uma vez, no cluster)
Usuário de monitoração com `pg_monitor` e liberado no `pg_hba.conf` **de cada nó**
(pg_hba **não** é replicado):
```sql
CREATE USER zbx_observability_monitor PASSWORD '<SENHA>';
GRANT pg_monitor TO zbx_observability_monitor;
```
```bash
# testar a conexao local ANTES de instalar:
PGPASSWORD='<SENHA>' psql -U zbx_observability_monitor -h 127.0.0.1 -d postgres -c 'select 1;'
```
> Se der `connection refused`, o postgres pode não escutar em 127.0.0.1 →
> use `--db-host <IP-do-no>` no install. Se `no pg_hba.conf entry`, adicione a
> regra e `SELECT pg_reload_conf();`.

### 3.2 Instalar (em cada nó de banco)
```bash
sudo ./agent/install.sh --role db \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) \
  --db-host 127.0.0.1 --db-port 5432 --db-name postgres \
  --db-user zbx_observability_monitor --db-password '<SENHA>' \
  --db-sslmode disable --pg-log-dir /var/lib/pgsql/16/data/log
```

### 3.3 Validar
```bash
curl -s http://127.0.0.1:9187/metrics | grep '^pg_up'    # esperado: pg_up 1
systemctl is-active otelcol-agent postgres-exporter
```
Se `pg_up 0`: `journalctl -u postgres-exporter -n 20 --no-pager` (mostra o motivo — porta/host/pg_hba).

---

## 4. WITNESS (pgpool + pgbouncer) — `--role witness`  (ex.: 10.55.0.136)

### 4.1 Pré-requisitos (auth — **bloqueia o exporter se faltar**)
Liberar o `zbx_observability_monitor`:
- **pgpool**: no `pool_hba.conf` (+ `pool_passwd` se scram/md5), conectando na 9999. Reload do pgpool.
- **pgbouncer**: em `stats_users` no `pgbouncer.ini` (+ `userlist.txt`/`auth_query`). Reload do pgbouncer.

Testar ANTES de instalar:
```bash
PGPASSWORD='<SENHA>' psql -U zbx_observability_monitor -h 127.0.0.1 -p 9999 -d postgres -tAc "show pool_version;"
PGPASSWORD='<SENHA>' psql -U zbx_observability_monitor -h 127.0.0.1 -p 6432 -d pgbouncer -tAc "SHOW VERSION;"
```

### 4.2 Instalar
```bash
sudo ./agent/install.sh --role witness \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) \
  --db-user zbx_observability_monitor --db-password '<SENHA>' \
  --db-name postgres --pgpool-port 9999 --pgbouncer-port 6432
```

### 4.3 Validar
```bash
curl -s http://127.0.0.1:9719/metrics | grep pgpool2_up      # esperado: 1
curl -s http://127.0.0.1:9127/metrics | grep pgbouncer_up    # esperado: 1
systemctl is-active otelcol-agent pgpool2-exporter pgbouncer-exporter
```
Se `0`: é auth do pgpool/pgbouncer → reveja 4.1 (`journalctl -u pgpool2-exporter -u pgbouncer-exporter -n 30`).

---

## 5. Verificação central (no gateway `sv-tools-dev02`)

Depois de instalar cada nó, confirme que o dado chegou:
```bash
# nos reportando host metrics (heartbeat):
docker exec zbx-prometheus wget -qO- 'http://localhost:9090/api/v1/series?match[]=system_cpu_load_average_1m' | tr '}' '\n' | grep -o '"zbx_node":"[^"]*"' | sort -u

# nomes das metricas por familia (para conferir cobertura):
docker exec zbx-prometheus wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' \
  | tr ',' '\n' | grep -E 'pg_up|pgpool2_up|pgbouncer_up|phpfpm_up|zabbix_stats_bridge_up|nginx_'
```

**Dashboards** (Grafana `http://10.55.0.155:3001`, tag `zabbix-obs`):
- **Overview** — status por nó (Zabbix + PostgreSQL), php-fpm up, heartbeat
- **Host / Web / Banco / Zabbix interno / Logs** — detalhe por camada (drill-down carrega nó+tempo)

---

## 6. Troubleshooting

| Sintoma | Causa provável | Correção |
|---|---|---|
| `zabbix_stats_bridge_up 0` + `last_error: Conexao fechada` | falta `StatsAllowedIP=127.0.0.1` | adicionar + `systemctl restart zabbix-server/proxy` (restart, não reload) |
| `zabbix_stats_bridge_up 0` + `last_error: Connection refused` | porta errada do trapper | reinstalar com `--zabbix-port <ListenPort real>` |
| `zabbix_stats_bridge_up 0` sem erro (core) | **HA standby** (só o ativo abre o trapper) | esperado, não é falha — dashboard mostra STANDBY |
| `pg_up 0` + `connection refused` | postgres não escuta em 127.0.0.1 / porta | `--db-host <IP>` / `--db-port <porta>` |
| `pg_up 0` + `no pg_hba.conf entry` | regra faltando no nó | adicionar em `pg_hba.conf` + `pg_reload_conf()` |
| `pgpool2_up`/`pgbouncer_up 0` | auth do pgpool/pgbouncer | liberar user (pool_hba/pool_passwd, stats_users) |
| painel de nginx/php "No data" | filtro `Nó` desatualizado | trocar o time range (força refresh) ou Nó=All |
| logs sem linhas de uma origem | serviço logando pouco (ex.: postgres sem `log_min_duration_statement`) | ajustar logging no serviço (DBA) |
| exporter não baixou (binário 0 bytes) | nó sem egress pro GitHub | baixar via proxy / copiar o binário manualmente |

Para gerar um log de teste (validar o pipeline de logs do banco):
```bash
psql -U usuario_inexistente -h 127.0.0.1 -d postgres   # falha e loga um FATAL -> aparece no Loki em ~30s
```

---

## 7. Notas importantes

- **Segurança:** senhas de banco vão em `EnvironmentFile` (modo 600) em `/etc/*-exporter/` — nunca no git. Rotacione a senha da POC.
- **HA de core:** só o nó ativo abre o trapper; o standby fica `up 0` por design. Alertar com `max(zabbix_stats_bridge_up{role="core"})`.
- **HA de web:** ambos ativos — os dois devem aparecer saudáveis.
- **Portas dos exporters (todas em 127.0.0.1):** bridge `9998`, php-fpm `9253`, postgres `9187`, pgpool `9719`, pgbouncer `9127`.
- **Gateway já configurado** com `resource_to_telemetry_conversion` (host metrics ganham `zbx_node`/`zbx_role`). Não precisa mexer.
