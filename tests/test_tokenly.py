import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import tokenly  # noqa: E402

NOW = datetime.now(timezone.utc).isoformat()


def write(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
        f.write("not json\n")


class TokenmeterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        os.environ["CLAUDE_CONFIG_DIR"] = os.path.join(root, "claude")
        os.environ["CODEX_HOME"] = os.path.join(root, "codex")
        tokenly.OVERRIDE = os.path.join(root, "no-prices.json")  # ignore the real user override
        msg = {"timestamp": NOW, "requestId": "r1", "cwd": "/x/proj-a",
               "message": {"id": "m1", "model": "claude-opus-5-5", "usage": {
                   "input_tokens": 1_000_000, "output_tokens": 1_000_000,
                   "cache_read_input_tokens": 1_000_000, "cache_creation_input_tokens": 2_000_000,
                   "cache_creation": {"ephemeral_1h_input_tokens": 1_000_000}}}}
        # duplicated line must be counted once
        write(os.path.join(root, "claude", "projects", "p", "s.jsonl"), [msg, msg])
        write(os.path.join(root, "codex", "sessions", "2026", "s.jsonl"), [
            {"timestamp": NOW, "type": "turn_context", "payload": {"model": "gpt-6.1-sol", "cwd": "/y/proj-b"}},
            {"timestamp": NOW, "type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"input_tokens": 3_000_000, "cached_input_tokens": 2_000_000,
                                     "output_tokens": 1_000_000}},
                "rate_limits": {"plan_type": "pro", "primary": {"used_percent": 42.0, "window_minutes": 10080,
                                "resets_at": 4102444800}, "secondary": {"used_percent": 99.0, "window_minutes": 300,
                                "resets_at": 946684800}}}},
            {"timestamp": "2000-01-01T00:00:00Z", "type": "event_msg", "payload": {"type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 9, "output_tokens": 9}}}},
        ])

    def tearDown(self):
        self.tmp.cleanup()

    def test_totals_and_cost(self):
        m = tokenly.collect(30).groups["model"]
        # opus: 4 + 20 + 0.2 + 5 (5m write) + 8 (1h write)
        self.assertEqual(m["claude:claude-opus-5-5"][:4], [1_000_000, 1_000_000, 1_000_000, 2_000_000])
        self.assertAlmostEqual(m["claude:claude-opus-5-5"][4], 37.2)
        # codex: 1M uncached input * 2 + 1M output * 10 + 2M cached * 0.1; old event ignored
        self.assertEqual(m["codex:gpt-6.1-sol"][:4], [1_000_000, 1_000_000, 2_000_000, 0])
        self.assertAlmostEqual(m["codex:gpt-6.1-sol"][4], 12.2)

    def test_providers(self):
        p = tokenly.collect(30).groups["provider"]
        self.assertEqual(sorted(p), ["Anthropic", "OpenAI"])
        self.assertAlmostEqual(p["Anthropic"][4], 37.2)

    def test_quota(self):
        with open(os.path.join(self.tmp.name, "claude", ".claude.json"), "w") as f:
            json.dump({"cachedUsageUtilization": {"utilization": {
                "five_hour": None,
                "seven_day": {"utilization": 88, "resets_at": "2100-01-01T00:00:00.123456+00:00"},
                "seven_day_opus": {"utilization": 50, "resets_at": "2000-01-01T00:00:00+00:00"}}}}, f)
        qs = {p: (plan, ms) for p, plan, ms in tokenly.quotas()}
        self.assertEqual([(l, v) for l, v, _ in qs["Claude"][1]], [("7d", 88.0)])  # expired window dropped
        self.assertEqual(qs["Codex"][0], "Pro")
        self.assertEqual([(l, v) for l, v, _ in qs["Codex"][1]], [("7d", 42.0)])

    def test_projects(self):
        p = tokenly.collect(30).groups["project"]
        self.assertEqual(sorted(p), ["proj-a", "proj-b"])

    def test_json_output(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            tokenly.main(["--json", "--by", "model"])
        out = json.loads(buf.getvalue())
        self.assertIn("claude:claude-opus-5-5", out["model"])
        self.assertEqual(out["unpriced_models"], [])

    def test_unpriced_model(self):
        t = tokenly.Tally("")
        t.add(NOW, "claude:mystery", "", 10, 10, 0, 0)
        self.assertEqual(t.missing, {"claude:mystery"})
        self.assertEqual(t.groups["model"]["claude:mystery"][4], 0)

    def test_codex_context_rates_and_cache_write_split(self):
        fixture = []
        for project, input_tokens in (("short", 272_000), ("long", 272_001)):
            fixture.extend([
                {"timestamp": NOW, "type": "turn_context",
                 "payload": {"model": "gpt-6.2-sol", "cwd": project}},
                {"timestamp": NOW, "type": "event_msg", "payload": {"type": "token_count", "info": {
                    "last_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": 50_000,
                                         "cache_write_input_tokens": 2_000, "output_tokens": 10_000}}}},
            ])
        write(os.path.join(self.tmp.name, "codex", "sessions", "2026", "context.jsonl"), fixture)
        tally = tokenly.collect(30)
        short, long = (tally.groups["project"][project] for project in ("short", "long"))
        self.assertEqual(short[:4], [220_000, 10_000, 50_000, 2_000])
        self.assertEqual(long[:4], [220_001, 10_000, 50_000, 2_000])
        self.assertAlmostEqual(short[4], 0.55)
        self.assertAlmostEqual(long[4], 1.050004)
        self.assertEqual(tally.missing, set())

    def test_pricing_override_and_synthetic_usage(self):
        tally = tokenly.Tally("")
        tally.prices["gpt-6.2-astra"] = (1, 2, 0, 0, 0)
        tally.add(NOW, "codex:gpt-6.2-astra", "", 300_000, 50_000, 0, 0)
        tally.add(NOW, "claude:<synthetic>", "", 0, 0, 0, 0)
        self.assertAlmostEqual(tally.groups["model"]["codex:gpt-6.2-astra"][4], 0.4)
        self.assertEqual(tally.missing, set())


if __name__ == "__main__":
    unittest.main()
