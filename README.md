# Zabbix Observability (OpenTelemetry)

POC de observabilidade 360º do ambiente Zabbix (cores, proxies, frontend web e
camada de banco PostgreSQL/pgpool) usando OpenTelemetry Collector + Prometheus +
Loki + Grafana.

Ver [`docs/arquitetura-v2.md`](docs/arquitetura-v2.md) para o design completo,
decisões, gaps conhecidos e roadmap de fases.

## Estrutura

```
zabbix-observability/
├── docs/
│   └── arquitetura-v2.md       # design doc completo
├── server/                     # roda no servidor central de observabilidade
│   ├── bootstrap-network.sh    # cria a rede docker compartilhada (1x)
│   ├── otel-collector/         # gateway: recebe OTLP, exporta pra prometheus/loki
│   ├── prometheus/
│   ├── loki/
│   └── grafana/
│       └── provisioning/
│           ├── datasources/    # datasources com uid fixo
│           └── dashboards/     # dashboards versionados (auto-carregados)
└── agent/                      # roda em cada core/proxy/web Zabbix
    ├── install.sh               # instala collector agent (+ bridge/exporter), idempotente
    ├── zabbix-stats-bridge.py   # fala o protocolo ZBXD, expõe zabbix.stats como Prometheus
    └── templates/               # units systemd + configs do collector (por papel)
```

Papéis de agente (`--role`):

| Papel | Onde roda | Componentes instalados | Coleta |
|-------|-----------|------------------------|--------|
| `core`  | Zabbix Server | otel-agent + zabbix-stats-bridge | hostmetrics, `zabbix.stats`, logs do server |
| `proxy` | Zabbix Proxy  | otel-agent + zabbix-stats-bridge | hostmetrics, `zabbix.stats`, logs do proxy |
| `web`   | frontend (nginx + php-fpm) | otel-agent + php-fpm_exporter | hostmetrics, nginx `stub_status`, php-fpm status, logs nginx/php-fpm |
| `core-web` | core que **também** hospeda o frontend (HML) | otel-agent + bridge + php-fpm_exporter | tudo de core + web num único nó |
| `db`    | PostgreSQL | otel-agent + postgres_exporter | hostmetrics, métricas PG (`pg_*`), logs do postgres |
| `witness` | pgpool + pgbouncer | otel-agent + pgpool2_exporter + pgbouncer_exporter | hostmetrics, métricas pgpool/pgbouncer |

**Manual de instalação do zero** (por tipo de nó, com validação e troubleshooting):
[`docs/manual-instalacao.md`](docs/manual-instalacao.md). Visão HML→PROD resumida em
[`docs/deploy-hml.md`](docs/deploy-hml.md). Credenciais de banco vão em
`EnvironmentFile` (modo 600, fora do git).

## Deploy — servidor de observabilidade

Cada stack é um compose independente, comunicando via rede docker externa
compartilhada. Requer Docker + Docker Compose plugin já instalados.

```bash
cd server
./bootstrap-network.sh          # cria a rede (1x, idempotente)

cd prometheus && docker compose up -d && cd ..
cd loki        && docker compose up -d && cd ..
cd otel-collector && docker compose up -d && cd ..
cd grafana     && docker compose up -d && cd ..
```

Grafana fica em `http://<ip-do-servidor>:3001` (porta `3000` já ocupada por
outro serviço no host em produção — ver ressalva no design doc).

Login inicial: `admin` / senha definida em `grafana/docker-compose.yml`
(`GF_SECURITY_ADMIN_PASSWORD` — troque antes de expor a outras pessoas).

### Dashboards (provisionados, tag `zabbix-obs`)

Divididos em **Overview + 5 detalhes**, com drill-down (as variáveis `$role`/`$node`
e o intervalo de tempo carregam ao navegar entre eles):

| Dashboard | UID | Foco |
|-----------|-----|------|
| **Overview** | `zbx-observability` | KPIs, status por nó (Zabbix + PostgreSQL), php-fpm up, heartbeat dos nós |
| **Zabbix interno** | `zbx-internals` | processos busy%, preprocessing |
| **Host** | `zbx-host` | CPU/mem/disco/rede/load |
| **Web** | `zbx-web` | nginx + php-fpm |
| **Banco** | `zbx-database` | PostgreSQL (pgpool/pgbouncer pendente do witness) |
| **Logs** | `zbx-logs` | Loki, filtrável por nó/papel/origem |

## Deploy — agente (core ou proxy Zabbix)

**Pré-requisito:** `StatsAllowedIP=127.0.0.1` já configurado no
`zabbix_server.conf`/`zabbix_proxy.conf` do nó (o `install.sh` avisa se
estiver faltando, mas não edita automaticamente — ver nota abaixo).

```bash
git clone <url-do-repo> && cd zabbix-observability

sudo ./agent/install.sh --role core  --gateway-host <ip-do-servidor> --node-name <hostname>
sudo ./agent/install.sh --role proxy --gateway-host <ip-do-servidor> --node-name <hostname>
```

Parâmetros opcionais:
- `--zabbix-port <porta>` — padrão `10051`. **Verifique o `ListenPort` real**
  do `zabbix_server.conf`/`zabbix_proxy.conf` de cada nó antes de rodar —
  já houve caso de core com `ListenPort=10080` customizado.
- `--bridge-port <porta>` — padrão `9998`. Já houve conflito de porta com
  serviços pré-existentes (`apollodb_proxy.py`) em produção — o script
  detecta e avisa antes de subir.

Validação:
```bash
curl -s http://127.0.0.1:9998/metrics | grep zabbix_stats_bridge_up
# esperado: zabbix_stats_bridge_up{role="...",node="..."} 1
```

### Nota sobre `StatsAllowedIP`

O `install.sh` **não edita** o `zabbix_server.conf`/`zabbix_proxy.conf`
automaticamente. Isso é proposital: esses arquivos são regenerados pelos
scripts de provisionamento do Zabbix (`setup-core.sh`/`setup-proxy.sh`), e
uma edição externa seria perdida na próxima regeração. Adicione
`StatsAllowedIP=127.0.0.1` diretamente no heredoc desses scripts.

### Nota sobre HA (cores)

Em topologia HA nativa do Zabbix 7.0, **só o nó ativo** abre a porta do
trapper — o bridge no nó standby vai reportar `zabbix_stats_bridge_up 0`
permanentemente, o que é esperado, não é falha. Ao consultar/alertar sobre
essa métrica para `role="core"`, use agregação (`max()`) em vez de checar
node a node, para não gerar falso positivo. O dashboard já trata isso:
mostra o standby como **STANDBY** (azul), não DOWN, e traz um KPI
"Cores ativos (HA)" que só fica vermelho se o par inteiro cair.

## Deploy — agente web (nginx + php-fpm)

Os web servers hospedam o frontend Zabbix (nginx + php-fpm). Eles **não**
rodam Zabbix, então o agente web instala só o otel-collector + o
`php-fpm_exporter` (sem bridge, sem `StatsAllowedIP`).

**Pré-requisitos:**

1. **nginx `stub_status`** habilitado num server local (as métricas de nginx
   dependem dele). Exemplo de drop-in em `/etc/nginx/conf.d/stub_status.conf`:
   ```nginx
   server {
       listen 127.0.0.1:8080;
       location /nginx_status { stub_status; access_log off; }
       location / { return 404; }
   }
   ```
   `nginx -t && systemctl reload nginx`. A porta `8080` é a esperada pelo
   template; se estiver ocupada, ajuste o conf e o endpoint em
   `otel-agent-web.yaml`.

2. **php-fpm status page** habilitado no pool (`pm.status_path = /status` em
   `/etc/php-fpm.d/www.conf`) + `systemctl restart php-fpm`.

```bash
git clone <url-do-repo> && cd zabbix-observability
sudo ./agent/install.sh --role web --gateway-host <ip-do-servidor> --node-name <hostname>
```

Parâmetro opcional: `--phpfpm-socket <path>` — padrão `/run/php-fpm/www.sock`.
Confira o `listen = ...` do `www.conf` do nó.

Validação:
```bash
curl -s http://127.0.0.1:8080/nginx_status          # stub_status respondendo
curl -s http://127.0.0.1:9253/metrics | grep phpfpm_up   # esperado: phpfpm_up ... 1
```

## Impacto nos nós e cadência de coleta

Os agentes são projetados para footprint baixo — coleta a cada 30 s, teto de
memória via `memory_limiter`, nada persistido no nó (sem fila em disco ainda).

**Componentes por nó e consumo aproximado:**

| Componente | Papéis | RAM (teto/típico) | CPU | Observação |
|------------|--------|-------------------|-----|------------|
| `otelcol-agent` | todos | `memory_limiter` 256 MiB (spike +64); na prática bem menos | desprezível | roda como `root`; lê `/proc` e faz tail dos logs |
| `zabbix-stats-bridge` | core, proxy, core-web | ~20–40 MiB (Python) | desprezível | 1 conexão TCP local ao trapper a cada scrape |
| `php-fpm_exporter` | web, core-web | ~15–20 MiB (Go) | desprezível | lê o status page via socket local |
| `postgres_exporter` | db | ~15–25 MiB (Go) | desprezível | conecta no PostgreSQL local (user `pg_monitor`) |
| `pgpool2_exporter` + `pgbouncer_exporter` | witness | ~15–25 MiB cada (Go) | desprezível | leem `SHOW pool_*` / stats via socket local |

**Cadência (intervalos configurados nos templates):**

| Fonte | Intervalo |
|-------|-----------|
| hostmetrics (CPU/mem/disco/rede/load) | 30 s |
| `zabbix.stats` (scrape do bridge) | 30 s |
| nginx `stub_status` | 30 s |
| php-fpm status (scrape do exporter) | 30 s |
| logs (filelog) | tempo real (tail, `start_at: end`) |
| flush/batch para o gateway | a cada 10 s ou 1024 itens |
| retenção no Prometheus (gateway) | 30 dias |

**Impacto no serviço monitorado:** mínimo. O bridge só abre uma conexão local
(`127.0.0.1`) ao trapper pedindo `zabbix.stats` a cada 30 s — não interfere na
coleta do Zabbix. hostmetrics lê `/proc`; nginx/php-fpm são lidos pelos status
locais. Export ao gateway é em lote e comprimido (banda baixa). O
`memory_limiter` garante o teto de RAM mesmo sob pico.

## Estado atual

**Implementado e validado:**

- Transporte OTLP → gateway → Prometheus/Loki → Grafana (com dado real).
- `zabbix.stats` (processos, preprocessing, hosts/items) via bridge ZBXD.
- Host metrics (CPU/mem/disco/rede/load) por nó — com `zbx_node`/`zbx_role`
  (via `resource_to_telemetry_conversion` no gateway; sem isso os `system_*`
  colidiam entre nós).
- Web: nginx (`stub_status`) + php-fpm (`php-fpm_exporter`).
- PostgreSQL (`postgres_exporter`): status/replica, lag, conexões, TPS, cache hit.
- Logs no Loki (zabbix/nginx/php/postgres), filtráveis por nó/origem.
- Dashboards divididos (Overview + 5 detalhes) com drill-down.
- Tratamento de HA de core (STANDBY ≠ DOWN) e detecção de nó caído (heartbeat).
- Fila / VPS via Zabbix API (`zabbix-api-bridge`) — o preditor de coleta (Fase 2).
- Alertmanager + regras preditivas (down de serviço, split-brain, fila crescendo,
  nó silencioso) — notificação em modo **UI** por ora.

**Pendências:**

- **Witness (pgpool/pgbouncer):** exporters prontos, mas dependem de liberar o
  `zbx_observability_monitor` no `pool_hba.conf`/`pool_passwd` e `stats_users`.
  Painéis do dashboard entram quando o exporter reportar.
- **Canal de alerta:** o Alertmanager roda em modo **UI** (`:9093`); falta plugar
  um receiver real (Teams/Slack/e-mail) — trocar o `receiver: null` no
  `alertmanager.yml` e por o segredo fora do git.
- **Proxy buffer via API:** os itens `zabbix[proxy_buffer,*]` entram no dashboard
  quando confirmados por proxy (a bridge ja expoe o que existir).
- **`file_storage`** (Fase 3): fila do Collector em disco (zero perda em blip
  de rede) ainda não implementada.
- **Labels canônicos `dc`/`env`** (Fase 3): ainda não aplicados nos agentes.
- **Logs do banco pobres:** dependem da DBA ligar `log_min_duration_statement`
  etc. no PostgreSQL (a coleta já está pronta).
- **Stack single-node:** o gateway (`sv-tools-dev02`) não tem HA — Fase 2.
- **Retenção não dimensionada:** Prometheus 30d + Loki 30d contra disco não medido.
