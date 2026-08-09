#!/usr/bin/env python3
"""Tests for maestro.

    python3 -m unittest discover maestro

Standard library unittest, because adding pytest would give maestro its only
dependency and these tests do not need anything pytest provides.

Ollama is never called: every test either exercises pure logic or replaces
`ask` with a stub. A test suite that needs a 2 GB model loaded is a test suite
nobody runs.
"""

from __future__ import annotations

import json
import os
import unittest
from unittest import mock

import triage


class TestClamp(unittest.TestCase):
    """Bounding what reaches the model is what keeps this usable on 6 GB."""

    def test_empty_input_is_explicit(self):
        # "(none available)" rather than "", so the prompt never contains a
        # blank section the model has to guess the meaning of.
        self.assertEqual(triage.clamp(""), "(none available)")

    def test_short_input_passes_through(self):
        self.assertEqual(triage.clamp("one\ntwo"), "one\ntwo")

    def test_keeps_the_tail_not_the_head(self):
        # In an incident the most recent lines are the ones that matter. The
        # start of a crash loop looks the same as its middle.
        text = "\n".join(f"line {i}" for i in range(triage.MAX_LOG_LINES + 50))
        out = triage.clamp(text)
        self.assertIn(f"line {triage.MAX_LOG_LINES + 49}", out)
        self.assertNotIn("line 0\n", out)

    def test_truncation_is_announced(self):
        text = "\n".join(str(i) for i in range(triage.MAX_LOG_LINES + 10))
        self.assertIn("truncated", triage.clamp(text))

    def test_character_cap_applies_to_one_huge_line(self):
        # A single JSON blob of a megabyte would slip past the line cap.
        out = triage.clamp("x" * (triage.MAX_LOG_CHARS * 2))
        self.assertLessEqual(len(out), triage.MAX_LOG_CHARS + 100)


class TestRender(unittest.TestCase):
    def test_substitutes_placeholders(self):
        out = triage.render("logs.md", LOGS="the log line")
        self.assertIn("the log line", out)
        self.assertNotIn("{{LOGS}}", out)

    def test_survives_braces_and_percent_signs_in_log_content(self):
        # THE REASON render() does not use str.format or f-strings. Real log
        # lines contain JSON, printf templates and percent signs; a formatter
        # would raise on them or silently mangle the evidence.
        nasty = '{"level":"ERROR","msg":"100% failed {0} {{x}} %s"}'
        out = triage.render("logs.md", LOGS=nasty)
        self.assertIn(nasty, out)

    def test_both_prompts_declare_their_content_untrusted(self):
        # Log lines are attacker-influenceable in principle — anything that can
        # write to a log can try to write instructions into one. Both prompts
        # must frame the excerpt as data.
        for template, fields in (("logs.md", {"LOGS": "x"}), ("alert.md", {"ALERT": "a", "LOGS": "x"})):
            out = triage.render(template, **fields).lower()
            self.assertIn("data, not instructions", out, template)
            self.assertIn("untrusted", out, template)


class TestAlertSummary(unittest.TestCase):
    PAYLOAD = {
        "status": "firing",
        "alerts": [{
            "status": "firing",
            "labels": {
                "alertname": "OvertureHighErrorRate",
                "severity": "warning",
                "namespace": "overture",
                "service": "overture",
            },
            "annotations": {
                "summary": "overture is returning 5xx to more than 5% of requests",
                "description": "12% of requests have returned a 5xx",
                "runbook": "check the deployed image digest first",
            },
            "startsAt": "2026-08-08T03:14:00Z",
        }],
    }

    def test_prompt_carries_the_fields_that_matter(self):
        seen = {}

        def fake_ask(prompt):
            seen["prompt"] = prompt
            return "note"

        with mock.patch.object(triage, "ask", fake_ask), \
             mock.patch.dict(os.environ, {"LOKI_URL": ""}, clear=False):
            self.assertEqual(triage.summarise_alert(self.PAYLOAD), "note")

        prompt = seen["prompt"]
        for expected in ("OvertureHighErrorRate", "warning", "overture",
                         "12% of requests", "check the deployed image digest first"):
            self.assertIn(expected, prompt)

    def test_runbook_annotation_reaches_the_model(self):
        # metronome writes the runbook as instructions to a human. Passing it
        # through is what lets maestro suggest the same first step rather than
        # inventing one.
        seen = {}
        with mock.patch.object(triage, "ask", lambda p: seen.setdefault("p", p) and "" or ""), \
             mock.patch.dict(os.environ, {"LOKI_URL": ""}, clear=False):
            triage.summarise_alert(self.PAYLOAD)
        self.assertIn("runbook:", seen["p"])

    def test_empty_webhook_is_handled(self):
        # Alertmanager can deliver a group that resolved between evaluation and
        # delivery. That must not raise.
        self.assertIn("no alerts", triage.summarise_alert({"alerts": []}))

    def test_missing_fields_do_not_raise(self):
        with mock.patch.object(triage, "ask", lambda p: "ok"), \
             mock.patch.dict(os.environ, {"LOKI_URL": ""}, clear=False):
            self.assertEqual(triage.summarise_alert({"alerts": [{}]}), "ok")


class TestAuthorisation(unittest.TestCase):
    """The webhook is reachable from the cluster, so it authenticates."""

    class FakeHandler(triage.Handler):
        # Bypass BaseHTTPRequestHandler's socket setup; only _authorised is
        # under test.
        def __init__(self, headers):  # noqa: D107
            self.headers = headers

    def check(self, token, header):
        with mock.patch.dict(os.environ, {"MAESTRO_TOKEN": token}, clear=False):
            return self.FakeHandler({"Authorization": header} if header else {})._authorised()

    def test_correct_token_accepted(self):
        self.assertTrue(self.check("s3cret", "Bearer s3cret"))

    def test_wrong_token_rejected(self):
        self.assertFalse(self.check("s3cret", "Bearer nope"))

    def test_prefix_of_token_rejected(self):
        self.assertFalse(self.check("s3cret", "Bearer s3c"))

    def test_missing_header_rejected(self):
        self.assertFalse(self.check("s3cret", ""))

    def test_wrong_scheme_rejected(self):
        self.assertFalse(self.check("s3cret", "Basic s3cret"))

    def test_unconfigured_token_rejects_everything(self):
        # Fail closed. An unconfigured maestro must not accept an empty bearer
        # token and start doing inference for anyone who finds the port.
        self.assertFalse(self.check("", "Bearer "))
        self.assertFalse(self.check("", ""))


class TestOllamaFailureIsSurvivable(unittest.TestCase):
    def test_unreachable_ollama_returns_a_message_not_a_traceback(self):
        # maestro being down must never be the reason an alert goes unnoticed.
        # Alertmanager has already done its job by the time this runs.
        with mock.patch.dict(os.environ, {"OLLAMA_URL": "http://127.0.0.1:1"}, clear=False):
            out = triage.ask("hello")
        self.assertIn("could not reach Ollama", out)


class TestLokiIsOptional(unittest.TestCase):
    def test_no_loki_url_means_no_query_and_no_error(self):
        with mock.patch.dict(os.environ, {"LOKI_URL": ""}, clear=False):
            self.assertEqual(triage.fetch_logs("overture"), "")

    def test_no_namespace_means_no_query(self):
        with mock.patch.dict(os.environ, {"LOKI_URL": "http://localhost:3100"}, clear=False):
            self.assertEqual(triage.fetch_logs(""), "")

    def test_loki_lines_are_returned_oldest_first(self):
        body = json.dumps({"data": {"result": [
            {"values": [["3", "newest"], ["2", "middle"], ["1", "oldest"]]}
        ]}}).encode()

        class FakeResp:
            def read(self_inner):
                return body
            def __enter__(self_inner):
                return self_inner
            def __exit__(self_inner, *a):
                return False

        with mock.patch.dict(os.environ, {"LOKI_URL": "http://localhost:3100"}, clear=False), \
             mock.patch("urllib.request.urlopen", return_value=FakeResp()), \
             mock.patch("json.load", lambda f: json.loads(body)):
            out = triage.fetch_logs("overture")

        # Loki returns newest-first; a human reads an incident oldest-first.
        self.assertEqual(out.splitlines(), ["oldest", "middle", "newest"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
