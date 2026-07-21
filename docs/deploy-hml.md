# Deploy — passo a passo (HML → replicável para PROD)

Procedimento de rollout dos agentes de observabilidade. Escrito para o
ambiente **HML** e anotado com as diferenças de **PROD**.

## Topologia

| Ambiente | Cores | Web | Banco | Witness |
|----------|-------|-----|-------|---------|
| **HML** | 2 cores que **também** rodam o frontend (nginx+php) em HA | junto no core (`--role core-web`) | 2 PostgreSQL em HA via pgpool (`10.55.0.134`, `10.55.0.135`) | 1 nó `10.55.0.136` (pgpool + pgbouncer) |
| **PROD** | cores dedicados (`--role core`) | **web separado** (`--role web`) | igual (`--role db`) | igual (`--role witness`) |

> **Gateway (servidor de observabilidade):** `10.55.0.155` (`sv-tools-dev02`).
> Se o HML tiver um gateway próprio, troque o `--gateway-host` em todos os comandos.

## Pré-requisitos gerais

- Rodar como **root**, a partir do repo clonado no próprio nó:
  ```bash
  git clone https://github.com/ThiagoRubio/observability.git && cd observability
  ```
- Cada nó precisa alcançar o gateway na **4317/tcp**: `nc -vz 10.55.0.155 4317`.
- **Segurança:** a senha do usuário de monitoração vai só em `EnvironmentFile`
  (modo 600, em `/etc/<exporter>/`), **nunca no git**. Rotacione a senha usada
  na POC antes de PROD.

---

## 1. Cores + Web (HML: `--role core-web`)

**Pré-requisitos no nó:**

1. `StatsAllowedIP=127.0.0.1` no `zabbix_server.conf` (+ restart do zabbix-server).
   Persistir no heredoc do `setup-core.sh`.
2. nginx `stub_status` em `127.0.0.1:8080`:
   ```bash
   cat > /etc/nginx/conf.d/stub_status.conf <<'EOF'
   server {
       listen 127.0.0.1:8080;
       location /nginx_status { stub_status; access_log off; }
       location / { return 404; }
   }
   EOF
   nginx -t && systemctl reload nginx
   ```
3. php-fpm status: `pm.status_path = /status` no pool + `systemctl restart php-fpm`.

**Instalar** (confirme o `ListenPort` real — nos cores costuma ser `10080`):

```bash
sudo ./agent/install.sh --role core-web \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) --zabbix-port 10080
```

**Validar:**
```bash
curl -s http://127.0.0.1:9998/metrics | grep zabbix_stats_bridge_up   # esperado: 1 (ou 0 se HA standby)
curl -s http://127.0.0.1:8080/nginx_status
curl -s http://127.0.0.1:9253/metrics | grep phpfpm_up                # esperado: 1
```

> **PROD:** cores e web são nós separados. No core rode `--role core` (só
> bridge/zabbix); no web rode `--role web` (nginx + php-fpm). Tudo o mais igual.

---

## 2. Banco PostgreSQL (`--role db`) — em `10.55.0.134` e `10.55.0.135`

**Pré-requisito:** o usuário `zbx_observability_monitor` deve existir com o role
`pg_monitor` (já confirmado em HML):
```sql
CREATE USER zbx_observability_monitor PASSWORD '***';
GRANT pg_monitor TO zbx_observability_monitor;
```
E `pg_hba.conf` permitindo conexão local do usuário ao banco.

**Instalar** (em cada nó de banco):
```bash
sudo ./agent/install.sh --role db \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) \
  --db-host 127.0.0.1 --db-port 5432 --db-name postgres \
  --db-user zbx_observability_monitor --db-password '<SENHA>' \
  --db-sslmode disable --pg-log-dir /var/lib/pgsql/16/data/log
```

**Validar:**
```bash
curl -s http://127.0.0.1:9187/metrics | grep '^pg_up'    # esperado: pg_up 1
systemctl status postgres-exporter otelcol-agent --no-pager
```
Se `pg_up 0`: cheque o DSN em `/etc/postgres-exporter/postgres_exporter.env`
(`journalctl -u postgres-exporter -n 20`).

---

## 3. Witness — pgpool + pgbouncer (`--role witness`) — `10.55.0.136`

**⚠ Pré-requisito (bloqueio atual): autorizar o usuário de monitoração.**
O exporter não coleta enquanto o `zbx_observability_monitor` não puder conectar:

- **pgpool** (`pool_hba.conf` + `pool_passwd` se scram/md5): liberar o usuário
  conectando na porta 9999. Recarregar o pgpool.
- **pgbouncer** (`pgbouncer.ini`): incluir o usuário em `stats_users`
  (ou `admin_users`) e no `userlist.txt`/`auth_query`. Recarregar o pgbouncer.

Teste antes de instalar:
```bash
PGPASSWORD='<SENHA>' psql -U zbx_observability_monitor -h 127.0.0.1 -p 9999 -d postgres -tAc "show pool_version;"
PGPASSWORD='<SENHA>' psql -U zbx_observability_monitor -h 127.0.0.1 -p 6432 -d pgbouncer -tAc "SHOW VERSION;"
```

**Instalar:**
```bash
sudo ./agent/install.sh --role witness \
  --gateway-host 10.55.0.155 --node-name $(hostname -s) \
  --db-user zbx_observability_monitor --db-password '<SENHA>' \
  --db-name postgres --pgpool-port 9999 --pgbouncer-port 6432
```

**Validar:**
```bash
curl -s http://127.0.0.1:9719/metrics | grep pgpool2_up      # esperado: 1
curl -s http://127.0.0.1:9127/metrics | grep pgbouncer_up    # esperado: 1
```
Se ficar `0`, é auth do pgpool/pgbouncer — reveja o pré-requisito acima
(`journalctl -u pgpool2-exporter -u pgbouncer-exporter -n 30`).

---

## 4. Verificação central (no gateway `sv-tools-dev02`)

Depois que cada nó reportar, confirme os dados chegando (por `zbx_node`):

```bash
# nomes das metricas por familia (para montar os paineis do dashboard)
docker exec zbx-prometheus wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' \
  | tr ',' '\n' | grep -E 'pg_|pgpool2_|pgbouncer_'

# confirmar o no reportando
docker exec zbx-prometheus wget -qO- 'http://localhost:9090/api/v1/series?match[]=pg_up' | tr '}' '\n'
```

Os painéis de **PostgreSQL / pgpool / pgbouncer** do dashboard são montados
**após** este passo, usando os nomes reais das métricas (evita "No data").

---

## Resumo de portas dos exporters (todas em `127.0.0.1`)

| Exporter | Porta | Papéis |
|----------|-------|--------|
| zabbix-stats-bridge | 9998 | core, proxy, core-web |
| php-fpm_exporter | 9253 | web, core-web |
| postgres_exporter | 9187 | db |
| pgpool2_exporter | 9719 | witness |
| pgbouncer_exporter | 9127 | witness |
