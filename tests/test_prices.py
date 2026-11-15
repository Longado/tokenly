import json
import os
import re
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
sys.path.insert(0, ROOT)
import tokenmeter  # noqa: E402


class PriceTableTest(unittest.TestCase):
    def test_swift_and_python_defaults_match(self):
        src = open(os.path.join(ROOT, "macos", "main.swift")).read()
        block = src[src.index("let defaultPrices"):src.index("]\n", src.index("let defaultPrices"))]
        swift = {m: tuple(float(x) for x in nums.split(","))
                 for m, nums in re.findall(r'"([^"]+)":\s*\[([^\]]+)\]', block)}
        py = {k: tuple(float(x) for x in v) for k, v in tokenmeter.PRICES.items()}
        self.assertEqual(swift, py)

    def test_override_file_adds_and_replaces(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "prices.json")
            with open(path, "w") as f:
                json.dump({"_comment": "x", "new-model": [1, 2, 3, 4, 5], "gpt-6.1-sol": [9, 9, 9, 9, 9],
                           "bad": [1, 2]}, f)
            p = tokenmeter.load_prices(path)
        self.assertEqual(p["new-model"], (1, 2, 3, 4, 5))
        self.assertEqual(p["gpt-6.1-sol"], (9, 9, 9, 9, 9))
        self.assertNotIn("bad", p)
        self.assertNotIn("_comment", p)

    def test_missing_override_is_ignored(self):
        self.assertEqual(tokenmeter.load_prices("/nonexistent/prices.json"), tokenmeter.PRICES)


class NormalizeTest(unittest.TestCase):
    def test_variants_merge(self):
        k = tokenmeter.PRICES
        for raw in ("claude-opus-5-5", "Claude-Opus-5-5", "anthropic/claude-opus-5-5", "claude-opus-5-5[1m]",
                    "us.anthropic.claude-opus-5-5-v1:0", "claude-opus-5-5-20261101", "openrouter/anthropic/claude-opus-5-5"):
            self.assertEqual(tokenmeter.normalize_model(raw, k), "claude-opus-5-5", raw)
        self.assertEqual(tokenmeter.normalize_model("gpt-6.1-sol-high", k), "gpt-6.1-sol")
        # an unknown name keeps its suffix rather than being guessed
        self.assertEqual(tokenmeter.normalize_model("qwen3-max", k), "qwen3-max")

    def test_provider(self):
        self.assertEqual(tokenmeter.provider_of("claude-opus-5-5"), "Anthropic")
        self.assertEqual(tokenmeter.provider_of("gpt-6.1-sol"), "OpenAI")
        self.assertEqual(tokenmeter.provider_of("o4-mini"), "OpenAI")
        self.assertEqual(tokenmeter.provider_of("gemini-3-pro"), "Google")
        self.assertEqual(tokenmeter.provider_of("kimi-k2"), "Other")


if __name__ == "__main__":
    unittest.main()
