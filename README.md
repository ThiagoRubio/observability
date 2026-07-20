# Zabbix Observability (OpenTelemetry)

POC de observabilidade 360º do ambiente Zabbix (cores, proxies, e futuramente
camada de banco) usando OpenTelemetry Collector + Prometheus + Loki + Grafana.

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

Três papéis de agente (`--role`):

| Papel | Onde roda | Componentes instalados | Coleta |
|-------|-----------|------------------------|--------|
| `core`  | Zabbix Server | otel-agent + zabbix-stats-bridge | hostmetrics, `zabbix.stats`, logs do server |
| `proxy` | Zabbix Proxy  | otel-agent + zabbix-stats-bridge | hostmetrics, `zabbix.stats`, logs do proxy |
| `web`   | frontend (nginx + php-fpm) | otel-agent + php-fpm_exporter | hostmetrics, nginx `stub_status`, php-fpm status, logs nginx/php-fpm |

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
| `zabbix-stats-bridge` | core, proxy | ~20–40 MiB (Python) | desprezível | 1 conexão TCP local ao trapper a cada scrape |
| `php-fpm_exporter` | web | ~15–20 MiB (Go) | desprezível | lê o status page via socket local |

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

## Gaps conhecidos (ver design doc para detalhes)

- `zabbix[queue]`, `zabbix[proxy_buffer,*]` e `zabbix[vps,written]` **não
  existem** no protocolo `zabbix.stats` — são itens internos, só acessíveis
  via Zabbix API. Bridge separado (`zabbix-api-bridge.py`) ainda não
  implementado (Fase 2 do design doc).
- Camada de banco (PostgreSQL/PgBouncer/pgpool) ainda não integrada —
  depende de negociação com a DBA team (Fase 0/7, caminho crítico).
- Stack de observabilidade é single-node (sem HA) na POC.
- `file_storage` (fila do Collector em disco, zero perda de dado em blip de
  rede) ainda não implementado — Fase 3.
