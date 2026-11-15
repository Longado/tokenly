#!/usr/bin/env python3
"""tokenmeter: local token usage, API-equivalent cost and plan limits for Claude Code and Codex CLI.

Reads local files only. No network, no upload, no dependencies.
"""
import argparse
import glob
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

__version__ = "0.3.0"

# USD per 1M tokens: input, output, cache_read, cache_write_5m, cache_write_1h.
# Defaults; keep in sync with defaultPrices in macos/main.swift (tests/test_prices.py checks this).
# Override or add models in ~/.config/tokenmeter/prices.json, shared with the macOS app.
PRICES = {
    "claude-fable-5-2": (8, 40, 0.20, 10, 16),
    "claude-opus-5-5": (4, 20, 0.20, 5, 8),
    "claude-sonnet-5-5": (2, 10, 0.10, 2.5, 4),
    "claude-haiku-5-5": (0.10, 0.50, 0.01, 0.125, 0.20),
    "gpt-6.1-sol": (2, 10, 0.10, 2.5, 2.5),
}
FIELDS = ("input", "output", "cache_read", "cache_write", "cost_usd")
OVERRIDE = os.path.expanduser("~/.config/tokenmeter/prices.json")


def load_prices(path=None):
    prices = dict(PRICES)
    try:
        with open(path or OVERRIDE) as f:
            for k, v in json.load(f).items():
                if not k.startswith("_") and isinstance(v, list) and len(v) == 5:
                    prices[k.lower()] = tuple(v)
    except (OSError, ValueError, AttributeError):
        pass
    return prices


def normalize_model(raw, known):
    """One name per underlying model: drop router prefixes, context tags, date snapshots and,
    when that yields a priced model, reasoning-effort suffixes. Mirrors normalizeModel in the app."""
    m = raw.lower().split("[", 1)[0].rsplit("/", 1)[-1]
    for p in ("global.anthropic.", "us.anthropic.", "eu.anthropic.", "apac.anthropic.", "anthropic."):
        if m.startswith(p):
            m = m[len(p):]
            break
    m = re.sub(r"-v\d+(:\d+)?$", "", m)
    m = re.sub(r"[-@]\d{8}$", "", m)
    if m not in known:
        s = re.sub(r"-(minimal|low|medium|high|xhigh|max)$", "", m)
        if s in known:
            m = s
    return m


def provider_of(model):
    m = model.lower()
    if m.startswith("claude"):
        return "Anthropic"
    if m.startswith(("gpt", "codex")) or re.match(r"o\d", m):
        return "OpenAI"
    if m.startswith("gemini"):
        return "Google"
    return "Other"


def claude_glob():
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(home, "projects", "**", "*.jsonl")


def codex_glob():
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    return os.path.join(home, "sessions", "**", "*.jsonl")


def read_jsonl(path):
    with open(path, errors="ignore") as fh:
        for ln in fh:
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            if isinstance(d, dict):
                yield d


class Tally:
    def __init__(self, since):
        self.since = since
        self.groups = {g: defaultdict(lambda: [0] * 5) for g in ("day", "provider", "model", "project")}
        self.missing = set()
        self.prices = load_prices()

    def add(self, ts, model, project, i, o, cr, cw, cw1h=0):
        """`model` is "tool:raw-model"; the model part is normalized before pricing."""
        if not ts or ts < self.since:
            return
        tool, _, raw = model.rpartition(":")
        name = normalize_model(raw, self.prices)
        model = f"{tool}:{name}" if tool else name
        p = self.prices.get(name)
        if p is None:
            self.missing.add(model)
            p = (0,) * 5
        cost = (i * p[0] + o * p[1] + cr * p[2] + (cw - cw1h) * p[3] + cw1h * p[4]) / 1e6
        for g, k in (("day", ts[:10]), ("provider", provider_of(name)), ("model", model),
                     ("project", project or "?")):
            r = self.groups[g][k]
            r[0] += i; r[1] += o; r[2] += cr; r[3] += cw; r[4] += cost


def scan_claude(t):
    # Assistant messages carry usage; the same message can be logged several times.
    seen = set()
    for f in glob.glob(claude_glob(), recursive=True):
        for d in read_jsonl(f):
            m = d.get("message")
            u = m.get("usage") if isinstance(m, dict) else None
            if not u:
                continue
            key = (m.get("id"), d.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            t.add(d.get("timestamp"), "claude:" + str(m.get("model")),
                  os.path.basename(d.get("cwd") or ""),
                  u.get("input_tokens", 0), u.get("output_tokens", 0),
                  u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0),
                  (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0))


def scan_codex(t):
    # token_count events; last_token_usage is per call and its input includes cached tokens.
    for f in glob.glob(codex_glob(), recursive=True):
        model, project = "codex:?", ""
        for d in read_jsonl(f):
            p = d.get("payload") or {}
            if d.get("type") == "turn_context":
                model = "codex:" + p["model"] if p.get("model") else model
                project = os.path.basename(p.get("cwd") or "") or project
            elif p.get("type") == "token_count" and (p.get("info") or {}).get("last_token_usage"):
                u = p["info"]["last_token_usage"]
                c = u.get("cached_input_tokens", 0)
                t.add(d.get("timestamp"), model, project, u.get("input_tokens", 0) - c,
                      u.get("output_tokens", 0), c, u.get("cache_write_input_tokens", 0))


def _future(ts):
    return ts is not None and ts > datetime.now(timezone.utc)


def _iso(v):
    try:
        return datetime.fromisoformat(re.sub(r"\.\d+", "", v).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def quotas():
    """Plan limits as the tools last recorded them locally: [(product, plan, [(window, pct, resets_at)])]."""
    out = []
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~")
    try:
        with open(os.path.join(home, ".claude.json")) as f:
            util = (json.load(f).get("cachedUsageUtilization") or {}).get("utilization") or {}
        meters = []
        for key, label in (("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_opus", "7d Opus"),
                           ("seven_day_sonnet", "7d Sonnet")):
            w = util.get(key)
            if isinstance(w, dict) and isinstance(w.get("utilization"), (int, float)):
                reset = _iso(w.get("resets_at"))
                if reset is None or _future(reset):
                    meters.append((label, float(w["utilization"]), reset))
        if meters:
            out.append(("Claude", None, meters))
    except (OSError, ValueError, AttributeError):
        pass
    newest = None
    for f in glob.glob(codex_glob(), recursive=True):
        for d in read_jsonl(f):
            p = d.get("payload") or {}
            if p.get("type") == "token_count" and p.get("rate_limits") and (newest is None or d.get("timestamp", "") >= newest[0]):
                newest = (d.get("timestamp", ""), p["rate_limits"])
    if newest:
        rl, meters = newest[1], []
        for k in ("primary", "secondary"):
            w = rl.get(k)
            if not isinstance(w, dict):
                continue
            reset = datetime.fromtimestamp(w["resets_at"], timezone.utc) if w.get("resets_at") else None
            if reset is None or _future(reset):
                mins = w.get("window_minutes") or 0
                label = "7d" if mins == 10080 else f"{mins // 1440}d" if mins and mins % 1440 == 0 else f"{round(mins / 60)}h"
                meters.append((label, float(w.get("used_percent") or 0), reset))
        if meters:
            out.append(("Codex", (rl.get("plan_type") or "").capitalize() or None, meters))
    return out


def print_quotas(qs):
    if not qs:
        print("No plan limit data found (Claude: ~/.claude.json, Codex: session logs).")
        return
    print("\nPlan limits (as last recorded locally)")
    for product, plan, meters in qs:
        for label, pct, reset in meters:
            when = reset.astimezone().strftime("%b %d %H:%M") if reset else "?"
            name = f"{product} ({plan})" if plan else product
            print(f"  {name:16}{label:10}{pct:>6.0f}%   resets {when}")


def collect(days):
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    t = Tally(since)
    scan_claude(t)
    scan_codex(t)
    return t


def row(name, r):
    nums = r[:4] + [sum(r[:4])]
    return (f"{name[:24]:24}" + "".join(f"{v:>{w},}" for v, w in zip(nums, (12, 12, 14, 14, 14)))
            + f"{r[4]:>11.2f}")


def table(title, data):
    print(f"\n{title}\n{'':24}{'input':>12}{'output':>12}{'cache_read':>14}"
          f"{'cache_write':>14}{'total':>14}{'cost($)':>11}")
    tot = [0] * 5
    for k in sorted(data):
        tot = [a + b for a, b in zip(tot, data[k])]
        print(row(k, data[k]))
    print(row("TOTAL", tot))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="tokenmeter", description=__doc__.strip().splitlines()[0])
    ap.add_argument("days", nargs="?", type=int, default=30, help="look back N days (default 30)")
    ap.add_argument("--by", choices=("day", "provider", "model", "project", "all"), default="all",
                    help="grouping to show (default all)")
    ap.add_argument("--json", action="store_true", help="print JSON instead of tables")
    ap.add_argument("--quota", action="store_true", help="show plan limits (Claude, Codex) instead of usage")
    ap.add_argument("-V", "--version", action="version", version=__version__)
    a = ap.parse_args(argv)

    if a.quota:
        qs = quotas()
        if a.json:
            json.dump([{"product": p, "plan": pl, "windows": [
                {"window": l, "used_percent": v, "resets_at": r.isoformat() if r else None} for l, v, r in ms]}
                for p, pl, ms in qs], sys.stdout, indent=2)
            print()
        else:
            print_quotas(qs)
        return 0
    t = collect(a.days)
    groups = list(t.groups) if a.by == "all" else [a.by]
    if a.json:
        out = {g: {k: dict(zip(FIELDS, v)) for k, v in sorted(t.groups[g].items())} for g in groups}
        out["unpriced_models"] = sorted(t.missing)
        json.dump(out, sys.stdout, indent=2)
        print()
        return 0
    if not t.groups["model"]:
        print(f"No usage found in the last {a.days} days.")
        return 0
    for g in groups:
        table(f"By {g} (last {a.days}d)", t.groups[g])
    if t.missing:
        print(f"\nNo price for (counted as $0, add to {OVERRIDE}):", ", ".join(sorted(t.missing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
