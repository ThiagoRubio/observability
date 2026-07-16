# Observabilidade Zabbix 360º — Arquitetura v2

**Status:** Proposta
**Objetivo da POC:** determinar a adesão de OpenTelemetry como padrão de observabilidade na Claranet
**Critério de sucesso:** prever incidentes em vez de reagir a eles, com rastreabilidade ponta a ponta (sintoma → causa)

---

## 1. Premissas travadas

| Decisão | Escolha | Consequência |
|---|---|---|
| HA da stack | Single-node na POC | HA vira Fase 2, documentado como ressalva explícita |
| Camada de banco | Sem exporters hoje, requer negociação | **Caminho crítico** — pedido deve sair imediatamente |
| Zabbix API | Token de leitura disponível | Bridge de API desbloqueado |

---

## 2. Por que v1 não atende

A v1 provou o transporte (bridge ZBXD → Collector → Prometheus → Grafana, validado com dado real
em produção). O que ela **não** entrega:

| Lacuna | Impacto no objetivo |
|---|---|
| Sem fila do Zabbix (`zabbix[queue]`) | Sem o principal preditor de incidente de coleta |
| Sem camada de banco | Cego exatamente onde os incidentes reais nascem (write timeout) |
| Logs nunca validados chegando no Loki | Metade da rastreabilidade é hipótese, não fato |
| Labels de métrica e log podem não bater | Dois silos, não observabilidade |
| Zero alertas | Dashboard não prevê nada; ninguém olha tela às 3h |
| Collector perde dado em blip de rede (`Dropping data` observado) | Ferramenta que perde dado queima a POC |
| Entrega por heredoc no terminal | Não é processo, não é versionado, não é auditável |

---

## 3. Arquitetura v2

```
┌─ NÓS MONITORADOS ────────────────────────────────────────────────┐
│                                                                   │
│  CORES (sv-zbx-srv01/02)          PROXIES (prxcln*, prxvcp*)      │
│  ├─ bridge ZBXD (stats)           ├─ bridge ZBXD (stats)          │
│  ├─ bridge API  (queue, vps,      ├─ bridge API (proxy_buffer)    │
│  │   proxy_buffer)                ├─ hostmetrics                  │
│  ├─ nginx + php-fpm               ├─ filelog (zabbix_proxy.log)   │
│  ├─ keepalived (estado VRRP)      └─ SQLite size                  │
│  ├─ hostmetrics                                                   │
│  └─ filelog (server, nginx, php)                                  │
│         │                                  │                      │
│         └──── OTel Collector (agent) ──────┘                      │
│                  file_storage (fila em disco = zero perda)        │
│                  resource attrs: node, role, dc, env              │
└──────────────────────┬────────────────────────────────────────────┘
                       │ OTLP gRPC :4317
┌──────────────────────▼────────────────────────────────────────────┐
│  SERVIDOR DE OBSERVABILIDADE (sv-tools-dev02)                     │
│                                                                    │
│  OTel Collector (gateway)                                          │
│    ├─ metrics ──▶ Prometheus  (remote_write)                       │
│    └─ logs    ──▶ Loki        (OTLP nativo)                        │
│                                                                    │
│  Prometheus ──▶ Alertmanager ──▶ (canal a definir)                 │
│  Grafana: dashboards + data links métrica↔log                      │
└──────────────────────▲────────────────────────────────────────────┘
                       │ scrape
┌──────────────────────┴────────────────────────────────────────────┐
│  CAMADA DE BANCO  ⚠ DEPENDE DE NEGOCIAÇÃO — CAMINHO CRÍTICO       │
│  postgres_exporter · pgbouncer_exporter · pgpool                   │
└───────────────────────────────────────────────────────────────────┘
```

---

## 4. Mudanças estruturais em relação à v1

### 4.1 Zero perda de dado (`file_storage`)

Na v1 o Collector agent descartou telemetria quando a rede falhou
(`Exporting failed. Dropping data. dropped_items: 6`). Numa POC de adoção isso é fatal:
a ferramenta perde dado justamente durante o incidente que deveria explicar.

**Correção:** extensão `file_storage` + `sending_queue.storage` no exporter OTLP. A fila passa a
ser persistida em disco: sobrevive a queda de rede, restart do serviço e reboot do nó.

### 4.2 Labels canônicos (pré-requisito de rastreabilidade)

Sem labels idênticos entre métrica e log, não existe navegação sintoma → causa.
Contrato único, aplicado por `resource` processor em **todos** os pipelines de **todos** os papéis:

| Label | Exemplo | Origem |
|---|---|---|
| `node` | `sv-zbx-prxvcp03` | `--node-name` |
| `role` | `core` \| `proxy` \| `db` | `--role` |
| `dc` | `vcp` \| `cln` \| `sp2` | novo — derivado do nome/parâmetro |
| `env` | `prd` | novo |

O `dc` é o que permite responder "o incidente é de um datacenter ou global?" — pergunta que
o desenho atual não consegue responder.

### 4.3 Bridge de API (o preditor que falta)

Descoberta da v1: `zabbix[queue]`, `zabbix[vps,written]` e `zabbix[proxy_buffer,*]` **não existem**
no protocolo `zabbix.stats`. São itens internos, acessíveis apenas via Zabbix API.

Segundo bridge (`zabbix-api-bridge.py`), token de leitura, expõe:

| Métrica | Por que importa |
|---|---|
| `zabbix[queue]`, `zabbix[queue,10m]` | **Principal preditor.** Fila crescendo antecede quase todo incidente de coleta |
| `zabbix[proxy_buffer,state,changes]` | Denuncia o ciclo disco↔memória — diretamente ligado à instabilidade de proxy já vivida |
| `zabbix[proxy_buffer,buffer,*]` | Saturação do buffer antes do overflow |
| `zabbix[vps,written]` | Throughput real de escrita no banco |
| `zabbix[discovery_queue]` | Fila de descoberta |

### 4.4 Alerting (sem isso não existe "prever")

Alertmanager + regras preditivas, não reativas. Alertam **tendência**, não estado:

| Regra | Condição | Antecipa |
|---|---|---|
| Fila crescendo sustentado | `deriv(zabbix_queue[15m]) > 0` por 30min | Coleta degradando antes de estourar |
| Proxy trocando de buffer | `increase(zabbix_proxy_buffer_state_changes[10m]) > N` | Instabilidade de proxy |
| Processo saturando | `busy% > 75` por 10min | Esgotamento de worker |
| Bridge cego | `max(zabbix_stats_bridge_up{role="core"}) == 0` | **Ambos** os cores fora (agregado — standby=0 é normal) |
| Ingestão parada | `absent(zabbix_stats_bridge_up{node="X"})` | Nó parou de reportar |

### 4.5 Entrega versionada (fim do heredoc)

O processo atual (colar arquivo no terminal) já causou: JSON truncado, linhas duplicadas,
pasta aninhada, versão desatualizada rodando sem ninguém perceber. Não é aceitável num
projeto que se propõe "impecável".

**Correção:** repositório Git. Os nós têm egress (baixaram imagens Docker e o binário do
Collector). Deploy passa a ser `git pull` + script idempotente, com hash verificável.

---

## 5. Cobertura 360º — matriz de gaps

| Camada | v1 | v2 | Observação |
|---|---|---|---|
| Processos internos Zabbix | ✅ validado | ✅ | Mantido |
| Fila / buffer / vps | ❌ | ✅ | Via bridge de API |
| Host (CPU/mem/disco/rede) | ⚠ configurado, nunca verificado | ✅ | **Validar antes de declarar pronto** |
| Logs Zabbix/nginx/php | ⚠ configurado, nunca verificado | ✅ | **Validar antes de declarar pronto** |
| nginx / php-fpm | ⚠ só cores, bloqueado por GMUD | ✅ | Depende de 15/07 |
| keepalived / VRRP | ❌ | ✅ | Estado MASTER/BACKUP |
| **Banco (PG/PgBouncer/pgpool)** | ❌ | ⚠ **negociação** | **Caminho crítico** |
| Traces | ❌ | ⚠ | Só faz sentido no frontend PHP. Zabbix server/proxy não geram traces — dizer isso abertamente é melhor que fingir cobertura |
| Alerting | ❌ | ✅ | Alertmanager |
| Rastreabilidade métrica↔log | ❌ | ✅ | Labels canônicos + data links |
| HA da stack | ❌ | ❌ | Ressalva explícita — Fase 2 |

---

## 6. Fases

| Fase | Entrega | Bloqueio |
|---|---|---|
| **0 — hoje** | Pedido formal à DBA team | Nenhum. **Sai hoje ou vira gargalo** |
| **1** | Validar logs + hostmetrics + labels chegando de fato | Nenhum |
| **2** | Bridge de API (queue, buffer, vps) | Token (disponível) |
| **3** | `file_storage` + labels canônicos nos agentes | Nenhum |
| **4** | Alertmanager + regras preditivas | Canal de notificação a definir |
| **5** | Data links métrica↔log no Grafana | Fase 1 e 3 |
| **6** | Cores (nginx, php-fpm, keepalived) | GMUD 15/07 |
| **7** | Camada de banco | Fase 0 |
| **8** | Migração para Git + rollout aos demais nós | Nenhum |

---

## 7. Ressalvas honestas (levar para a apresentação)

Uma POC que omite limitação perde credibilidade na primeira pergunta difícil. Declarar antes:

1. **A stack é single-node.** Se `sv-tools-dev02` cai, a observabilidade cai junto. HA é Fase 2.
2. **Não há traces reais de Zabbix server/proxy.** Não é limitação do OpenTelemetry — esses
   binários não são instrumentados. Traces só no frontend PHP, se houver interesse.
3. **Retenção não foi dimensionada.** Prometheus 30d + Loki 30d contra disco não medido.
4. **`22.551 items sem suporte`** apareceu no primeiro proxy medido (~42% dos items).
   É achado do ambiente, não da ferramenta — mas é exatamente o tipo de coisa que a
   observabilidade deveria ter tornado visível antes, e é um bom argumento a favor dela.

---

## 8. Pendências abertas

- Canal de alerta (e-mail, Teams, Slack, PagerDuty?)
- CIDR/inventário definitivo dos nós a monitorar
- Dimensionamento de disco em `sv-tools-dev02`
- Definição do label `dc` por nó
- Consistência do `sv-zbx-prxcln04` (corrigido por sed manual, não pelo script atual)
