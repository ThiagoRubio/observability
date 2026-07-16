#!/usr/bin/env python3
"""
zabbix-stats-bridge.py

Le a stats interface do Zabbix Server/Proxy (StatsAllowedIP) falando
diretamente o protocolo trapper (header ZBXD + JSON), e expoe o resultado
como metricas Prometheus via um servidor HTTP local minimo, para o
OTel Collector (prometheus receiver) fazer scrape.

Nao depende de zabbix_get nem de Zabbix Agent - fala o protocolo de trapper
diretamente, o mesmo usado internamente pelo item "zabbix[stats,<ip>,<port>]"
quando um Zabbix Server consulta outro.

Protocolo (fonte: codigo-fonte oficial do Zabbix, zbxcomms/trapper):
  Request:  b"ZBXD" + bytes([0x01]) + struct.pack("<I", len(payload)) + b"\x00\x00\x00\x00" + payload
  payload:  b'{"request":"zabbix.stats"}'
  Response: mesmo header, seguido do JSON de resposta.

Validado em producao contra core (porta customizada 10080) e proxies
(porta padrao 10051), Zabbix 7.0, em 16/07/2026.

Uso:
  zabbix-stats-bridge.py --zabbix-host 127.0.0.1 --zabbix-port 10051 \
                          --listen-port 9998 --role proxy --node-name sv-zbx-prxvcp03
"""

import argparse
import json
import socket
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ZBXD_HEADER = b"ZBXD"
ZBXD_FLAG_UNCOMPRESSED = 0x01
HEADER_LEN = 13  # "ZBXD" (4) + flags (1) + datalen (4) + reserved (4)


class ZabbixStatsError(Exception):
    pass


def fetch_zabbix_stats(host: str, port: int, timeout: float = 5.0) -> dict:
    """Conecta no trapper do Zabbix Server/Proxy e pede zabbix.stats."""
    payload = json.dumps({"request": "zabbix.stats"}).encode("utf-8")
    header = (
        ZBXD_HEADER
        + bytes([ZBXD_FLAG_UNCOMPRESSED])
        + struct.pack("<I", len(payload))
        + struct.pack("<I", 0)
    )

    with socket.create_connection((host, port), timeout=timeout) as sock:
        sock.sendall(header + payload)

        resp_header = _recv_exact(sock, HEADER_LEN, timeout)
        if resp_header[:4] != ZBXD_HEADER:
            raise ZabbixStatsError(
                f"Header de resposta invalido: {resp_header[:4]!r}"
            )

        flags = resp_header[4]
        (data_len,) = struct.unpack("<I", resp_header[5:9])

        if flags & 0x02:
            raise ZabbixStatsError(
                "Resposta comprimida (flag 0x02) nao suportada por este bridge"
            )

        body = _recv_exact(sock, data_len, timeout)

    try:
        parsed = json.loads(body.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ZabbixStatsError(f"JSON invalido na resposta: {exc}") from exc

    if parsed.get("response") != "success":
        raise ZabbixStatsError(f"Zabbix respondeu erro: {parsed}")

    return parsed.get("data", {})


def _recv_exact(sock: socket.socket, n: int, timeout: float) -> bytes:
    sock.settimeout(timeout)
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ZabbixStatsError("Conexao fechada antes de receber todos os dados")
        buf += chunk
    return buf


def _sanitize_label(name: str) -> str:
    """Converte nomes de processo Zabbix (ex: 'history syncer') em algo
    seguro para valor de label Prometheus."""
    return name.replace('"', '\\"')


def stats_to_prometheus(stats: dict, role: str, node_name: str) -> str:
    """Converte o JSON de zabbix.stats em texto no formato de exposicao
    do Prometheus. Agrupa amostras por nome de metrica para respeitar o
    formato de exposicao (HELP/TYPE aparecem uma unica vez por metrica)."""
    metrics: dict = {}

    def add_sample(name, value, labels=None, help_text=None, mtype="gauge"):
        entry = metrics.setdefault(name, {"type": mtype, "help": help_text, "samples": []})
        entry["samples"].append((labels or {}, value))

    base_labels = {"role": role, "node": node_name}

    scalar_keys = {
        "boottime": "zabbix_boottime_seconds",
        "uptime": "zabbix_uptime_seconds",
        "hosts": "zabbix_hosts_monitored",
        "items": "zabbix_items_monitored",
        "items_unsupported": "zabbix_items_unsupported",
        "preprocessing_queue": "zabbix_preprocessing_queue",
    }
    for key, metric_name in scalar_keys.items():
        if key in stats:
            add_sample(metric_name, stats[key], base_labels)

    preprocessing = stats.get("preprocessing", {})
    for sub in ("queued", "direct"):
        entry = preprocessing.get(sub, {})
        for field in ("count", "size"):
            if field in entry:
                labels = dict(base_labels, stage=sub)
                add_sample(f"zabbix_preprocessing_{field}", entry[field], labels)

    process = stats.get("process", {})
    for proc_name, proc_data in process.items():
        proc_label = _sanitize_label(proc_name.replace(" ", "_"))
        labels = dict(base_labels, process=proc_label)

        if "count" in proc_data:
            add_sample("zabbix_process_count", proc_data["count"], labels)

        for state in ("busy", "idle"):
            state_data = proc_data.get(state, {})
            for agg in ("avg", "max", "min"):
                if agg in state_data:
                    m_labels = dict(labels, state=state, agg=agg)
                    add_sample("zabbix_process_busy_percent", state_data[agg], m_labels)

    # NOTA (16/07/2026): em producao, os dois campos abaixo nunca vieram
    # preenchidos pela stats interface real (so no servidor fake de teste).
    # Mantidos aqui por seguranca/compatibilidade futura, mas o dado real
    # de fila/buffer/vps vem do zabbix-api-bridge.py (via Zabbix API),
    # nao deste bridge.
    proxy_buffer = stats.get("proxy_buffer", {})
    if proxy_buffer:
        for k, v in proxy_buffer.items():
            if isinstance(v, (int, float)):
                labels = dict(base_labels, buffer_metric=k)
                add_sample("zabbix_proxy_buffer", v, labels)

    vps = stats.get("vps", {})
    if "written" in vps:
        add_sample("zabbix_vps_written_total", vps["written"], base_labels, mtype="counter")

    add_sample(
        "zabbix_stats_bridge_up",
        1,
        base_labels,
        help_text="Bridge conseguiu falar com a stats interface",
    )

    lines = []
    for name, entry in metrics.items():
        if entry["help"]:
            lines.append(f"# HELP {name} {entry['help']}")
        lines.append(f"# TYPE {name} {entry['type']}")
        for labels, value in entry["samples"]:
            label_str = ""
            if labels:
                parts = [f'{k}="{v}"' for k, v in labels.items()]
                label_str = "{" + ",".join(parts) + "}"
            lines.append(f"{name}{label_str} {value}")

    return "\n".join(lines) + "\n"


def error_metric(role: str, node_name: str, error: str) -> str:
    safe_error = error.replace('"', "'").replace("\n", " ")
    return (
        "# HELP zabbix_stats_bridge_up Bridge conseguiu falar com a stats interface\n"
        "# TYPE zabbix_stats_bridge_up gauge\n"
        f'zabbix_stats_bridge_up{{role="{role}",node="{node_name}"}} 0\n'
        f"# last_error: {safe_error}\n"
    )


def make_handler(zabbix_host: str, zabbix_port: int, role: str, node_name: str):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/metrics", "/"):
                self.send_response(404)
                self.end_headers()
                return
            try:
                stats = fetch_zabbix_stats(zabbix_host, zabbix_port)
                body = stats_to_prometheus(stats, role, node_name)
            except (ZabbixStatsError, OSError) as exc:
                body = error_metric(role, node_name, str(exc))

            encoded = body.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, fmt, *args):
            pass  # log via journald fica a cargo do systemd

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zabbix-host", default="127.0.0.1")
    parser.add_argument("--zabbix-port", type=int, default=10051)
    parser.add_argument("--listen-port", type=int, default=9998)
    parser.add_argument("--role", default="core", choices=["core", "proxy"])
    parser.add_argument(
        "--node-name",
        default=None,
        help="Nome do no (ex: sv-zbx-srv01). Se omitido, usa o hostname local.",
    )
    args = parser.parse_args()

    node_name = args.node_name or socket.gethostname().split(".")[0]

    handler = make_handler(args.zabbix_host, args.zabbix_port, args.role, node_name)
    server = ThreadingHTTPServer(("127.0.0.1", args.listen_port), handler)
    print(
        f"[zabbix-stats-bridge] role={args.role} node={node_name} "
        f"zabbix={args.zabbix_host}:{args.zabbix_port} "
        f"listen=127.0.0.1:{args.listen_port}",
        file=sys.stderr,
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
