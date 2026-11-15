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
tokenmeter                 # last 30 days, grouped by day / model / project
tokenmeter 7               # last 7 days
tokenmeter --by model      # one grouping: day | model | project | all
tokenmeter --json          # machine-readable output
```

```
By model (last 30d)
                               input      output    cache_read   cache_write         total    cost($)
claude:claude-opus-5-5         1,200     250,000    18,000,000     900,000    19,151,200      13.80
codex:gpt-6.1-sol          2,000,000     120,000    30,000,000           0    32,120,000       8.20
TOTAL                      2,001,200     370,000    48,000,000     900,000    51,271,200      22.00
```
*(sample numbers)*

## macOS app (desktop widget + menu bar)

`TokenMeter.app` is a native, dependency-free macOS app (13+) that shows a translucent
widget on the desktop and today's cost in the menu bar. It refreshes every 5 minutes and on wake.

- Range switch: Today / 7 Days / 30 Days, with change vs the previous period and money saved by cache reads.
- 30-day daily cost chart, stacked by tool; click a bar to see that day.
- Breakdown by tool (Claude Code, Codex) and by model.
- Drag the header to move the widget; the position is remembered.
- Menu bar / right-click menu: Refresh, Show Widget, Launch at Login, Quit.

Download `TokenMeter.zip` from Releases, unzip, move to `/Applications`. The app is ad-hoc
signed, so the first launch needs right-click → Open. Or build it yourself (Xcode command line tools only):

```bash
macos/build.sh            # -> macos/build/TokenMeter.app
cp -R macos/build/TokenMeter.app /Applications/
```

`TokenMeter --snapshot out.png [today|week|month|dayN]` renders the widget to a PNG (for development).

Prices are in `macos/main.swift` (`prices`) and `tokenmeter.py` (`PRICES`); keep them in sync.

## Data sources

| Tool | Path | Notes |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (or `$CLAUDE_CONFIG_DIR`) | `message.usage`, deduped by message id + request id |
| Codex CLI | `~/.codex/sessions/**/*.jsonl` (or `$CODEX_HOME`) | `token_count` events, `last_token_usage`; cached input split out |

## Pricing

Costs are **API list-price equivalents**, not what a subscription actually charges.
Prices live in the `PRICES` dict at the top of `tokenmeter.py` (USD per 1M tokens:
input, output, cache read, cache write 5m, cache write 1h). Models without a price
are counted as $0 and listed at the end of the output — PRs welcome.

## Development

```bash
python3 -m unittest discover -s tests
```

## License

MIT
