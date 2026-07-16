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
└── agent/                      # roda em cada core/proxy Zabbix
    ├── install.sh               # instala bridge + collector agent, idempotente
    ├── zabbix-stats-bridge.py   # fala o protocolo ZBXD, expõe zabbix.stats como Prometheus
    └── templates/               # units systemd + configs do collector (por papel)
```

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
node a node, para não gerar falso positivo.

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
