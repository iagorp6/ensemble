#!/usr/bin/env python3
"""maestro — drafts a plain-English likely-cause note for an alert.

Layer 7 of ensemble, and the only one that runs on the workstation rather than
in the cluster.

    ./triage.py serve                 # listen for Alertmanager webhooks
    ./triage.py analyse app.log       # one-shot on a log excerpt
    kubectl logs deploy/x | ./triage.py analyse -

WHAT THIS DELIBERATELY DOES NOT DO
----------------------------------
It has no cluster credentials, runs no commands, and changes nothing. It reads
an alert, reads some logs, and writes a paragraph.

That boundary is the whole design. "AIOps" usually gets sold as software that
remediates on its own, and a language model that can restart your deployments
is a language model that can restart your deployments at 3am because it
misread a log line. What is actually useful — and honest — is the five minutes
of orientation before a human decides anything.

WHY LOCAL-ONLY
--------------
Two reasons, and the second is the one that would survive a review.

Log excerpts are among the worst things to ship to a third-party API: they
contain hostnames, IPs, user identifiers, occasionally a token someone logged
by accident. Running inference on hardware you already own means that question
never has to be asked.

And the model is the one component that genuinely wants a GPU. There is no GPU
on the Always Free tier, so this is where the hosting split stops being
symmetric — documented in the README rather than glossed over.

ZERO DEPENDENCIES
-----------------
Standard library only, same as `score`. Ollama speaks plain HTTP+JSON, so
urllib is enough, and the tool stays something you can drop on any machine with
Python and run.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PROMPTS = Path(__file__).parent / "prompts"

# Hard caps on what reaches the model.
#
# A crash-looping pod emits the same stack trace thousands of times a minute. A
# 128k-context model will cheerfully accept all of it, and on 6 GB of VRAM the
# KV cache for a context that size does not fit — Ollama spills layers to CPU
# and a 20-second inference becomes several minutes. Truncating is not just
# tidiness, it is what keeps the tool usable on this hardware.
MAX_LOG_LINES = 200
MAX_LOG_CHARS = 12_000


# =============================================================================
# Config
# =============================================================================

def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def ollama_url() -> str:
    return env("OLLAMA_URL", "http://localhost:11434").rstrip("/")


def model() -> str:
    return env("OLLAMA_MODEL", "llama3.2:3b")


# =============================================================================
# Ollama
# =============================================================================

def ask(prompt: str) -> str:
    """Send a prompt to Ollama and return the completion."""
    body = json.dumps({
        "model": model(),
        "prompt": prompt,
        # One shot, no streaming. Streaming would matter for a chat UI; here
        # nobody is watching the tokens arrive.
        "stream": False,
        "options": {
            # Low temperature. This is not a creative writing task — the same
            # alert should produce the same note twice, or the tool is not
            # something anyone can build a habit around.
            "temperature": 0.2,
            # Bound the output. The prompt asks for six sentences; this is the
            # backstop for when it doesn't listen.
            "num_predict": 400,
        },
    }).encode()

    req = urllib.request.Request(
        f"{ollama_url()}/api/generate",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    timeout = int(env("OLLAMA_TIMEOUT", "180"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp).get("response", "").strip()
    except urllib.error.URLError as exc:
        # Degrade to a useful message rather than a traceback. maestro being
        # down must never be the reason an alert goes unnoticed — Alertmanager
        # has already done its job by the time this runs.
        return (
            f"[maestro could not reach Ollama at {ollama_url()}: {exc}]\n"
            f"Is `ollama serve` running, and is {model()} pulled?"
        )
    except TimeoutError:
        return f"[maestro timed out after {timeout}s waiting for {model()}]"


# =============================================================================
# Loki (optional)
# =============================================================================

def fetch_logs(namespace: str, pod: str = "") -> str:
    """Pull recent lines from Loki, if LOKI_URL is set.

    Optional on purpose. Without it maestro still works from the alert payload
    alone; with it the note is about what the application actually said rather
    than about the shape of the alert.
    """
    base = env("LOKI_URL")
    if not base or not namespace:
        return ""

    selector = f'{{namespace="{namespace}"}}' if not pod else f'{{namespace="{namespace}", pod="{pod}"}}'
    query = urllib.parse.urlencode({
        "query": selector,
        "limit": env("LOKI_LINES", "200"),
        "direction": "backward",
    })

    try:
        with urllib.request.urlopen(f"{base.rstrip('/')}/loki/api/v1/query_range?{query}", timeout=15) as resp:
            payload = json.load(resp)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return f"[maestro could not query Loki: {exc}]"

    lines: list[str] = []
    for stream in payload.get("data", {}).get("result", []):
        for _ts, line in stream.get("values", []):
            lines.append(line)

    # Loki returns newest-first; read them oldest-first, the way a human would.
    return "\n".join(reversed(lines))


# =============================================================================
# Prompt assembly
# =============================================================================

def clamp(text: str) -> str:
    """Cut a log excerpt down to something a small model can actually hold."""
    if not text:
        return "(none available)"

    lines = text.splitlines()
    dropped_lines = 0
    if len(lines) > MAX_LOG_LINES:
        dropped_lines = len(lines) - MAX_LOG_LINES
        # Keep the TAIL. In an incident the most recent lines are the ones that
        # matter; the beginning of a crash loop is the same as its middle.
        lines = lines[-MAX_LOG_LINES:]

    out = "\n".join(lines)
    if len(out) > MAX_LOG_CHARS:
        out = out[-MAX_LOG_CHARS:]
        dropped_lines += 1

    if dropped_lines:
        out = f"[truncated to the most recent {MAX_LOG_LINES} lines]\n{out}"
    return out


def render(template: str, **fields: str) -> str:
    """Fill a prompt template.

    Deliberately not str.format or an f-string: the substituted values are log
    lines from a production system and will contain braces, percent signs and
    anything else. A formatter would try to interpret them and either raise or,
    worse, silently mangle the evidence.
    """
    text = (PROMPTS / template).read_text(encoding="utf-8")
    for key, value in fields.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def summarise_alert(payload: dict) -> str:
    """Turn an Alertmanager webhook payload into a note."""
    alerts = payload.get("alerts", [])
    if not alerts:
        return "[maestro received a webhook with no alerts in it]"

    described = []
    namespace = pod = ""
    for alert in alerts:
        labels = alert.get("labels", {}) or {}
        annotations = alert.get("annotations", {}) or {}
        namespace = namespace or labels.get("namespace", "")
        pod = pod or labels.get("pod", "")

        described.append("\n".join([
            f"status:      {alert.get('status', 'unknown')}",
            f"alertname:   {labels.get('alertname', '?')}",
            f"severity:    {labels.get('severity', '?')}",
            f"namespace:   {labels.get('namespace', '?')}",
            f"service:     {labels.get('service', '?')}",
            f"started:     {alert.get('startsAt', '?')}",
            f"summary:     {annotations.get('summary', '')}",
            f"description: {annotations.get('description', '')}",
            # The runbook annotation from metronome's PrometheusRule. It was
            # written as instructions to a human, which is exactly what makes
            # it useful here — both a person and a model need to know what to
            # look at first.
            f"runbook:     {annotations.get('runbook', '')}",
        ]))

    return ask(render(
        "alert.md",
        ALERT="\n\n".join(described),
        LOGS=clamp(fetch_logs(namespace, pod)),
    ))


def summarise_logs(text: str) -> str:
    return ask(render("logs.md", LOGS=clamp(text)))


# =============================================================================
# Output
# =============================================================================

def emit(note: str, heading: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    block = f"\n## {stamp} — {heading}\n\n{note}\n"

    print(block, flush=True)

    path = env("MAESTRO_LOG")
    if path:
        # Append, never rewrite. The value of these notes is comparative —
        # "this is the third time this week" is the sentence that leads to a
        # fix, and it only exists if the earlier ones are still there.
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(block)


# =============================================================================
# Webhook server
# =============================================================================

class Handler(BaseHTTPRequestHandler):
    server_version = "maestro/1.0"

    def _json(self, status: int, body: dict) -> None:
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _authorised(self) -> bool:
        token = env("MAESTRO_TOKEN")
        if not token:
            return False
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        # compare_digest rather than ==, so response timing doesn't reveal how
        # many leading characters were correct. Same reasoning as overture's
        # /private endpoint in score/main.go.
        return hmac.compare_digest(header[len("Bearer "):], token)

    def do_GET(self) -> None:  # noqa: N802  (name fixed by BaseHTTPRequestHandler)
        if self.path == "/healthz":
            self._json(200, {"status": "ok", "model": model()})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/alert":
            self._json(404, {"error": "not found"})
            return

        if not env("MAESTRO_TOKEN"):
            self._json(503, {"error": "MAESTRO_TOKEN is not set; refusing to accept alerts"})
            return

        if not self._authorised():
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Bearer realm="maestro"')
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "body is not valid JSON"})
            return

        # ------------------------------------------------------------------
        # RESPOND FIRST, THINK AFTERWARDS.
        #
        # Inference takes 20 seconds to two minutes on this hardware.
        # Alertmanager's webhook timeout is much shorter, and a webhook that
        # does not answer in time is retried — so a slow handler produces
        # duplicate deliveries, which on a machine that can run one inference
        # at a time means a queue that never drains.
        #
        # Worse, Alertmanager's notification pipeline blocks on the request, so
        # a slow maestro would delay every OTHER alert behind it. The tool
        # whose job is to help must not be able to make the outage harder to
        # see.
        #
        # 202 Accepted is the honest status code: received, not yet processed.
        # ------------------------------------------------------------------
        self._json(202, {"status": "accepted", "alerts": len(payload.get("alerts", []))})

        threading.Thread(
            target=self._process,
            args=(payload,),
            daemon=True,
        ).start()

    @staticmethod
    def _process(payload: dict) -> None:
        started = time.monotonic()
        note = summarise_alert(payload)
        elapsed = time.monotonic() - started
        first = (payload.get("alerts") or [{}])[0].get("labels", {}).get("alertname", "alert")
        emit(note, f"{first} ({elapsed:.0f}s, {model()})")

    def log_message(self, fmt: str, *args) -> None:
        # The default logs every request to stderr in Apache format, which
        # buries the notes. Keep it, but make it one quiet line.
        sys.stderr.write(f"maestro {self.address_string()} {fmt % args}\n")


def serve() -> int:
    addr = env("MAESTRO_ADDR", "127.0.0.1:9099")
    host, _, port = addr.rpartition(":")
    host = host or "127.0.0.1"

    if not env("MAESTRO_TOKEN"):
        print("warning: MAESTRO_TOKEN is not set — /alert will refuse everything", file=sys.stderr)

    httpd = ThreadingHTTPServer((host, int(port)), Handler)
    print(f"maestro listening on {host}:{port}, model {model()} via {ollama_url()}", file=sys.stderr)
    print("waiting for Alertmanager. Reach it from the cluster with:", file=sys.stderr)
    print(f"  ssh -R 0.0.0.0:{port}:localhost:{port} stagehand@<node>", file=sys.stderr)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nmaestro stopping", file=sys.stderr)
    return 0


# =============================================================================
# CLI
# =============================================================================

def analyse(source: str) -> int:
    text = sys.stdin.read() if source == "-" else Path(source).read_text(encoding="utf-8", errors="replace")
    if not text.strip():
        print("nothing to analyse (empty input)", file=sys.stderr)
        return 1
    emit(summarise_logs(text), f"log excerpt from {source} ({model()})")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="triage.py",
        description="Draft a plain-English likely-cause note for an alert or a log excerpt.",
    )
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="listen for Alertmanager webhooks on MAESTRO_ADDR")
    one = sub.add_parser("analyse", help="summarise a log excerpt and exit")
    one.add_argument("source", help="path to a log file, or - for stdin")

    args = parser.parse_args(argv)
    return serve() if args.command == "serve" else analyse(args.source)


if __name__ == "__main__":
    raise SystemExit(main())
