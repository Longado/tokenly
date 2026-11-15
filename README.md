# tokenmeter

Local token usage and API-equivalent cost for **Claude Code** and **Codex CLI**.
One Python file, zero dependencies, no network, nothing uploaded.

统计本机 Claude Code / Codex CLI 的 token 用量，并按 API 标价折算等值费用。单文件、无依赖、纯本地。

## Install

```bash
pipx install git+https://github.com/Longado/tokenmeter
# or just run it:
python3 tokenmeter.py
```

## Usage

```bash
tokenmeter                 # last 30 days, grouped by day / provider / model / project
tokenmeter 7               # last 7 days
tokenmeter --by provider   # one grouping: day | provider | model | project | all
tokenmeter --quota         # plan limits (Claude, Codex) as last recorded locally
tokenmeter --json          # machine-readable output (also with --quota)
```

```
By model (last 30d)
                               input      output    cache_read   cache_write         total    cost($)
claude:claude-opus-5-5         1,200     250,000    18,000,000     900,000    19,151,200      13.80
codex:gpt-6.1-sol          2,000,000     120,000    30,000,000           0    32,120,000       8.20
TOTAL                      2,001,200     370,000    48,000,000     900,000    51,271,200      22.00
```
*(sample numbers)*

## macOS app (menu bar)

`TokenMeter.app` is a native, dependency-free macOS menu bar app (13+). The panel has three pages:
**Overview** (cost, trend, plan limits, today / 7 / 30-day totals), **Breakdown** (filters, token mix, by
provider / model / project / device / day) and **History** (13-week calendar, every month on record). Range and
device pickers sit under the header and apply to every page. The menu bar shows
today's cost; click it for the usage panel, right-click for the menu. It refreshes every 5 minutes and on wake.

- Plan limits: Claude and Codex subscription windows (5h / 7d) as the tools last recorded them locally,
  with reset times; the menu bar flags any limit above 80%.
- Projects: breakdown by project (working directory) and a project filter.
- Other devices (optional, off by default): if the Vibe Usage app is linked on this Mac, Settings → Other devices
  downloads your account's usage from vibecafe.ai (read-only, with the key Vibe Usage stored) back to your first
  synced day. Adds a Devices switch (All / This Mac / one device), a Device breakdown and the All range with monthly
  bars. This Mac's numbers still come from its own logs; other devices report daily totals.
- Ranges: period pills Today / 24H / 7D / 30D / 90D / All / Custom (From–To dates), or click any day. Today, 24H and single days chart by hour.
- Trend strip under the headline number: hover a bar for its cost and tokens, click a day bar to focus it.
- Active time: 5-minute slots with at least one model call.
- Settings window (menu → Settings…): menu bar format (cost / tokens / both / fullest plan limit),
  plan limit alert threshold, text size (Default / Large / Larger), launch at login, desktop widget, and Edit Prices….
- Hero: cost for the range, change vs the previous period, a one-line takeaway
  ("$0.79 a day. Anthropic took 94% of it."), and the token mix (input / output / cached / cache writes).
- Filters: provider (All / Anthropic / OpenAI / Google, derived from the model name) and a model dropdown grouped by provider.
- Activity: 13-week dot calendar (dot size = cost that day; click a dot to focus that day), plus 7-day / 30-day / daily-average totals.
- Breakdown by provider (with per-model split), by model, or a daily table.
- Optional desktop widget (menu → Show on Desktop); drag its header to move it.
- Menu: Refresh, Show on Desktop, Launch at Login, Quit.

Download `TokenMeter.zip` from Releases, unzip, move to `/Applications`. The app is ad-hoc
signed, so the first launch needs right-click → Open. Or build it yourself (Xcode command line tools only):

```bash
macos/build.sh            # -> macos/build/TokenMeter.app
cp -R macos/build/TokenMeter.app /Applications/
```

`TokenMeter --snapshot out.png [today|24h|week|month|90d|all|custom from=YYYY-MM-DD to=YYYY-MM-DD|dayN] [--popover|--settings] [hover=N] [device=name] [page=overview|breakdown|history] [provider=OpenAI] [model=gpt-6.1-sol] [project=name] [mode=provider|model|project|day]` renders the panel to a PNG (for development).

Prices are in `macos/main.swift` (`prices`) and `tokenmeter.py` (`PRICES`); keep them in sync.

## Keeping history

Claude Code deletes session logs after 30 days by default. To keep TokenMeter's history, set
`"cleanupPeriodDays": 3650` in `~/.claude/settings.json` on every Mac you use.

## Data sources

| Tool | Path | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (or `$CLAUDE_CONFIG_DIR`) | `message.usage`, deduped by message id + request id |
| Codex CLI | `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME`) | `token_count` events, `last_token_usage`; cached input split out |

## Pricing

Costs are **API list-price equivalents**, not what a subscription actually charges.
Defaults live in `PRICES` (`tokenmeter.py`) and `defaultPrices` (`macos/main.swift`); a test keeps them identical.
Override prices or add models in `~/.config/tokenmeter/prices.json`, read by both the app and the CLI
(USD per 1M tokens: input, output, cache read, cache write 5m, cache write 1h):

```json
{ "my-model": [1.0, 5.0, 0.1, 1.25, 2.0] }
```

Model names are normalized first (router prefixes, `[1m]` context tags, date snapshots and, when that matches a
priced model, effort suffixes are dropped), so variants of one model share a price and a row.

## Development

```bash
python3 -m unittest discover -s tests
```

See [ROADMAP.md](ROADMAP.md) for positioning and what comes next.

## License

MIT
