# TokenMeter roadmap

## Positioning

TokenMeter answers two questions about AI coding, entirely on your machine:

1. **What would this cost at list price, and where does it go?** (cost & insight)
2. **How close am I to my plan limits?** (subscription quota)

It reads the logs the tools already write. No account, no upload, no runtime to install, ~1 MB app.

### How it differs from similar tools

| | TokenMeter | Vibe Usage (vibe-cafe) | vibeusage (victorGPT) |
|---|---|---|---|
| Core question | Cost & insight, plus quota | Quota & multi-device sync | Leaderboard & public profile |
| Where data lives | Local only | Uploaded to vibecafe.ai | Uploaded to vibeusage.cc |
| Account | None | Required | Required |
| Runtime | Native Swift, ~1 MB | Swift + bundled Node, ~240 MB | Node CLI |
| Hooks into tool configs | None (read-only) | CLI sync | Installs hooks/plugins |
| Insight | Takeaway sentence, period delta, cache savings, token mix | Stat cards, donuts | Stat cards, heatmap, rank |

**Keep:** local-first, read-only, tiny, explains numbers.
**Don't copy:** cloud sync, accounts, leaderboards, bundled runtimes, dense donut grids (our panel is 360 pt wide).

## Shipped

### v0.14.0 — text size
Text size: Default / Large (new default) / Larger, changed in the panel footer (A− / A+, ⌘− / ⌘+), the right-click menu (Text Size) or Settings. Fonts, table columns and the panel width (360 → 414 → 468 pt) scale together.

### v0.13.0 — three pages
The single page had grown to about 1,100 pt, taller than the screen. It is now split into three pages:
- **Overview** answers "am I OK right now?": headline cost and trend, plan limits, and today / 7-day / 30-day totals. About 550 pt tall.
- **Breakdown** holds the analysis: provider, model and project filters, token mix with cache savings, and the provider / model / project / device / day breakdown.
- **History** shows the 13-week calendar and every month on record, with a monthly table.

Range (Today … All time) and device pickers moved to one row under the header and apply to every page. Duplicated totals were removed.

### v0.12.0 — other devices and all-time history
- **Optional other-devices import (off by default).**
  - Uses the key the Vibe Usage app stored in `~/.vibe-usage/config.json` and reads `/api/usage` from vibecafe.ai. Read-only.
  - History older than 8 days is fetched once in 30-day `from/to` chunks and cached in `~/Library/Caches/TokenMeter/vibe-history.json`. The cache is keyed by a hash of the account key.
  - The last 8 days come from `days=8`, refreshed at most every 15 minutes. The `from/to` rollups lag on the newest day; the `days=` query is current.
  - This Mac's own buckets are dropped, because its local logs are authoritative.
  - Other devices are priced with our table when the model is known, otherwise with the server's estimate.
- **Devices.** Devices row (All / This Mac / one device), a Device tab in the breakdown, and a status line when the import fails.
- **All range.** Monthly bars and no previous-period delta.
  - Day table lists only days with usage for ranges over 90 days.
  - Hourly views note that other devices report daily totals.
  - Calls and active time are labeled "on this Mac".
- **Formatting.** Thousands separators in dollar amounts, and a horizontally scrolling provider row.
- **Retention.** README documents `cleanupPeriodDays: 3650` so Claude Code stops deleting logs after 30 days.

### v0.11.0 — analysis depth and settings (P1 complete, P2 mostly complete)
- **Ranges.** Today / 24H (rolling, distinct from Today) / 7D / 30D / 90D. Data is now kept per local hour, and the scan window grew to 182 days so 90D has a previous period to compare against.
- **Trend strip.** Bars under the headline number:
  - 24 hourly bars for Today, 24H and a picked day; daily bars for 7D / 30D / 90D.
  - Hover shows that slot's cost and tokens, using one hover region per chart.
  - Clicking a daily bar focuses that day. Activity dots keep their tooltips.
- **Active time.** Distinct 5-minute slots with at least one model call, unioned across sessions so parallel sessions don't double count.
- **Menu bar format.** Today's cost / today's tokens / cost + tokens / fullest plan limit.
  - Configurable plan-limit alert (off / 70 / 80 / 90%): the fullest limit is appended in orange, or red from 90%.
  - Available from the right-click menu and from Settings.
- **Settings window.** Menu bar format, alert threshold, launch at login, desktop widget, Edit Prices….
- **Shared price table.**
  - `~/.config/tokenmeter/prices.json` overrides or adds models for both the app and the CLI.
  - The app rescans when prices change, since costs are computed while parsing.
  - `tests/test_prices.py` keeps the Swift and Python defaults identical.
- **Model names.** Router prefixes, `[1m]`-style tags, Bedrock/Vertex prefixes and version suffixes, and date snapshots are dropped. Effort suffixes are dropped only when the result is a priced model. Long names truncate in the middle with a tooltip.
- **CLI parity (v0.3.0).**
  - `--by provider`, `--quota` (also with `--json`), price override, and model normalization.
  - The test suite grew from 4 to 11 tests.

### v0.10.0 — plan limits, projects, incremental scanning
- **Plan limits card**
  - Claude: `cachedUsageUtilization` in `~/.claude.json` (5h / 7d / 7d Opus / 7d Sonnet, reset times).
  - Codex: newest `rate_limits` event in session logs (windows, plan type).
  - Windows whose reset time has passed are hidden. "as of …" appears when the snapshot is over an hour old.
  - Bars turn orange at 70% and red at 90%. The menu bar adds `Claude 88%` (orange/red) once any limit passes 80%.
- **Projects**
  - Project = basename of the session's working directory.
  - New Project tab in the breakdown. Clicking a row filters the whole panel, and a removable project chip appears in the filter row.
- **Incremental scanner**
  - Per-file state (size, mtime, byte offset, partial aggregates, Codex model/project state) is kept between refreshes, so only appended lines are parsed.
  - Files are read in 1 MiB chunks, so memory doesn't grow with log size.
  - Files that age out of the 98-day window are dropped from the cache.
- **Layout**
  - The panel scrolls once it would exceed the screen height.
  - Breakdown lists show the top 8 plus "+N more".
  - Single-day takeaway shows cost per call. Large jumps show as `▲ 121×`.

### v0.9.0 — redesign (branch `v0.9-stable`)
Hero with takeaway and token mix, 13-week activity dots, breakdown by provider / model / day, single accent color.

### v0.1–v0.8
CLI, pricing, macOS app, menu bar popover, provider + model filters.

## Next

### Blocked
- **More sources: OpenCode, Gemini CLI.** Neither is installed on the development Mac, so their log formats can't be verified. Add them once real data is available.
- **Auto-update (Sparkle).** Needs a Developer ID signature first. The app is ad-hoc signed today.

### Ideas (not planned yet)
- Budget alerts: a daily or monthly spending limit with a system notification.
- Per-project budgets and a "this week vs last week" digest notification.
- Export a range to CSV from the Day tab.
- CLI: `--devices` using the same Vibe Usage import.
- Intel test run. The universal binary builds, but it has only been run on Apple silicon.

### Engineering notes
- Claude messages are deduplicated by `message.id + requestId` across all files, kept in memory for the app's lifetime.
- Codex `last_token_usage.input_tokens` includes cached tokens, so the cached amount is subtracted from input.
- Quota data is whatever the tool last cached locally. TokenMeter never calls provider APIs or reads credentials.
- UI self-check:
  ```
  TokenMeter --snapshot out.png [today|24h|week|month|90d|dayN] [--popover|--settings] [provider=…] [model=…] [project=…] [mode=…] [hover=N]
  ```
