#!/usr/bin/env python3
"""
zabbix-api-bridge.py

Le itens internos do Zabbix (zabbix[queue], zabbix[vps,written],
zabbix[proxy_buffer,*], zabbix[wcache,*], ...) via Zabbix API (item.get) e
expoe como metricas Prometheus. Esses itens NAO existem no protocolo
zabbix.stats (stats-bridge) - so via API. Fase 2 do design doc.

- Autentica via header Authorization: Bearer <token> (Zabbix 6.4+/7.0).
- Failover entre multiplos endpoints (ex.: os dois frontends, sem VIP/DNS).
- So depende da stdlib (roda em python:3-slim sem pip install).

Config (via env, para nao vazar segredo em argv):
  ZABBIX_API_URL    = http://10.55.0.132/api_jsonrpc.php,http://10.55.0.133/api_jsonrpc.php
  ZABBIX_API_TOKEN  = <token de leitura>
  (ou --zabbix-url / --token na linha de comando)

Metricas expostas:
  zabbix_internal_item{key="zabbix[...]",host="<host>"}  <lastvalue numerico>
  zabbix_api_bridge_up  1|0  (conseguiu falar com a API)
"""

import argparse
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def api_call(url, token, method, params, timeout):
    payload = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Content-Type": "application/json-rpc",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if "error" in data:
        raise RuntimeError(f"API error: {data['error']}")
    return data.get("result", [])


def fetch_internal_items(urls, token, search, timeout):
    """Tenta cada endpoint em ordem (failover). Retorna (items, url_usada)."""
    params = {
        "output": ["key_", "lastvalue"],
        "selectHosts": ["host"],
        # search substring (LIKE) SEM wildcards - com searchWildcardsEnabled o '[' quebra
        "search": {"key_": search},
        "sortfield": "key_",
    }
    last_err = None
    for url in urls:
        try:
            return api_call(url, token, "item.get", params, timeout), url
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            continue
    raise RuntimeError(f"todos os endpoints falharam: {last_err}")


def _sanitize(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def build_metrics(items):
    lines = [
        "# HELP zabbix_internal_item Valor (lastvalue numerico) de item interno zabbix[*] via API",
        "# TYPE zabbix_internal_item gauge",
    ]
    for item in items:
        raw = item.get("lastvalue")
        try:
            val = float(raw)
        except (TypeError, ValueError):
            continue  # pula lastvalue nao-numerico (ex.: estados textuais)
        key = _sanitize(item.get("key_", ""))
        hosts = item.get("hosts") or [{}]
        host = _sanitize(hosts[0].get("host", ""))
        lines.append(f'zabbix_internal_item{{key="{key}",host="{host}"}} {val}')
    return lines


def up_metric(value):
    return [
        "# HELP zabbix_api_bridge_up Bridge conseguiu ler itens internos via API",
        "# TYPE zabbix_api_bridge_up gauge",
        f"zabbix_api_bridge_up {value}",
    ]


def make_handler(urls, token, search, timeout):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path not in ("/metrics", "/"):
                self.send_response(404)
                self.end_headers()
                return
            lines = []
            try:
                items, _ = fetch_internal_items(urls, token, search, timeout)
                lines.extend(build_metrics(items))
                lines.extend(up_metric(1))
            except Exception as exc:  # noqa: BLE001
                lines.extend(up_metric(0))
                lines.append(f"# last_error: {str(exc).replace(chr(10), ' ')}")
            body = ("\n".join(lines) + "\n").encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zabbix-url", default=os.environ.get("ZABBIX_API_URL", ""),
                        help="URL(s) da API, separadas por virgula (failover).")
    parser.add_argument("--token", default=os.environ.get("ZABBIX_API_TOKEN", ""),
                        help="Token de leitura (preferir env ZABBIX_API_TOKEN).")
    parser.add_argument("--listen-port", type=int, default=int(os.environ.get("BRIDGE_PORT", "9099")))
    parser.add_argument("--search", default=os.environ.get("ZABBIX_API_SEARCH", "zabbix["))
    parser.add_argument("--timeout", type=float, default=float(os.environ.get("API_TIMEOUT", "10")))
    args = parser.parse_args()

    urls = [u.strip() for u in args.zabbix_url.split(",") if u.strip()]
    if not urls:
        print("[erro] informe --zabbix-url ou ZABBIX_API_URL", file=sys.stderr)
        sys.exit(1)
    if not args.token:
        print("[erro] informe --token ou ZABBIX_API_TOKEN", file=sys.stderr)
        sys.exit(1)

    handler = make_handler(urls, args.token, args.search, args.timeout)
    server = ThreadingHTTPServer(("0.0.0.0", args.listen_port), handler)
    print(f"[zabbix-api-bridge] urls={urls} listen=0.0.0.0:{args.listen_port} search='{args.search}'",
          file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
