# Tokenly roadmap

## Positioning

Tokenly answers two questions about AI coding, entirely on your machine:

1. **What would this cost at list price, and where does it go?** (cost & insight)
2. **How close am I to my plan limits?** (subscription quota)

It reads the logs the tools already write. No account, no upload, no runtime to install, ~1 MB app.

### How it differs from similar tools

| | Tokenly | Vibe Usage (vibe-cafe) | vibeusage (victorGPT) |
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

### v1.0.0 — first stable release
- **Plan prices.**
  - Each plan shows what you pay next to what your last 30 days were worth at API prices: "$200/mo plan · last 30 days worth $8,452 · 42.3×".
  - Prices are guessed from the plan badge (Claude Max / Codex Pro $200, Claude Pro / ChatGPT Plus $20, Business $30) and can be set in Settings → Plan prices.
- **Docs and site.** README rewritten around the finished product (features, install, privacy table, CLI, pricing, data sources, development), and website screenshots refreshed.
- Versions aligned: app 1.0.0 (build 31), CLI 1.0.0.

### v0.27.0 — live Claude limit
- **How it works.**
  - Same request the Agent SDK makes: start `claude` with `--print --safe-mode --no-session-persistence --strict-mcp-config --tools "" --output-format/--input-format stream-json`, then send `initialize` and `get_usage` (`skip_behaviors: true`) over stdio.
  - No prompt is sent and no tokens are used; Claude Code reads its own login.
  - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is stripped and unset via `--settings`, otherwise `rate_limits` comes back null.
- **Light on resources.** At most once every 5 minutes, with a 10 s hard deadline (the process is terminated). It answers in about 0.4 s on the dev Mac and leaves no stray processes.
- **What it shows.** Plan badge (MAX), 5h / 7d / 7d Opus / 7d Sonnet windows; readings also feed the plan-weeks history.
- **Fallback and setting.** An API-key login means no plan limits, so the card is hidden. On failure, Tokenly falls back to `~/.claude.json` and the footer says why. On by default: Settings → Plan limits → "Read Claude limits live".
- Binary lookup order: `~/.local/bin`, `~/.claude/local`, Homebrew, then `PATH`.

### v0.26.0 — plan usage by week
- **Reading history.**
  - Every plan-limit reading Tokenly sees is kept in `~/Library/Application Support/Tokenly/plan-readings.json`: Codex logs (backfilled, one entry per change), live Codex reads, Vibe Usage's saved reading, and Claude's cache.
  - Up to 50k readings, so weeks stay measurable after the tools' logs are gone.
- **Reset detection.** On the main 7-day limit, a reset is a drop of more than 3 points within the same window, or a window that restarts before the previous one ended.
- **Plan weeks** (History, Codex / Claude tabs). Eight weekly windows, anchored on the plan's reset time:
  - cost;
  - full limits used: cost ÷ what 100% was worth that week, from the stretch since the last reset; "≈" when the week has no readings and the latest known value is used;
  - resets detected (↻N).
- **Estimate after a reset.** The current-window estimate starts counting after the last detected reset.
- `--tall` snapshot flag renders the unfolded panel without the screen-height cap.

### v0.25.0 — live Codex limit
- **How it works.**
  - Same request the Codex app makes: `GET {base}/wham/usage`, with the ChatGPT login Codex keeps in `~/.codex/auth.json`.
  - `base` follows `chatgpt_base_url` in `~/.codex/config.toml`.
  - The token is read per request, sent only to OpenAI, never stored or logged.
- **Light on resources.** One request at most every 2 minutes, 10 s timeout, no retries; between requests the last answer is reused. The app measured 86 MB of memory and 0% CPU when idle.
- **What it shows.** Live %, plan, reset time and reset credits ("↻ 2 resets left"). The card labels the source "live".
- **Fallback.** When the read fails (expired login, offline), Tokenly falls back to Vibe Usage's saved reading or Codex's logs, and the footer says why.
- **Setting.** On by default: Settings → Plan limits → "Read Codex limits live". The README and website privacy text now mention this request.

### v0.24.0 — Codex limit matches the live number
Tokenly showed Codex at ≈63% while Vibe Usage showed the live 55%. Root causes:
1. **Stale source.** Codex writes `rate_limits` into its logs only when it runs on this Mac. The newest local reading was 53%, 11 hours old.
2. **Estimate overshoot.** The bridge estimate adds other devices' usage since the reading. Those devices report daily totals, spread evenly over the day, so morning work before the reading counted as after it.
3. **Variable cost per %.** Model mix (priority models, Fable) changes how fast dollars use up the limit.

Fix:
- Tokenly reads the live Codex reading the Vibe Usage app saves in `~/.vibe-usage/codex-rate-limits.json` (%, reset time, plan, reset credits; no credentials) and uses it whenever it's newer than the logs. The estimate now only bridges the short gap since that reading.
- The card names its source ("live via Vibe Usage" / "Codex logs on this Mac") and shows reset credits left.

Still open:
- Vibe Usage refreshes that file only when its own panel opens. A fully live reading would need Tokenly to call Codex's usage endpoint with the login in `~/.codex/auth.json` (opt-in, same approach as Vibe Usage).
- Track readings over time to detect resets and measure "100% ≈ $" per week.

### v0.23.0 — plan limits estimated for now
- **The problem.** Codex and Claude Code record plan usage only when they run on this Mac. While you work on other devices, the recorded % falls behind: Tokenly showed 42% while Codex showed 52%.
- **The fix.** Tokenly now estimates the current %: the last recorded % plus usage since then on all devices, at the window's cost per %. The estimate is marked "≈", with "N% recorded X ago + usage since". Real data: ≈53% vs 52% actual.
- **Honest full-limit value.** "100% ≈ $…" now uses only usage up to the recorded reading, so later usage no longer inflates it.
- **Demo data.** `TOKENLY_DEMO=1` makes the app show made-up data, used for the website screenshots.
- **Website.** `docs/index.html` is the GitHub Pages landing page, with demo screenshots in `docs/assets`.

### v0.22.0 — tokens beside cost, and what a full plan limit is worth
- **Headline.** Cost and tokens sit side by side, each with its change vs the previous period.
- **Full-limit value.**
  - Each plan limit shows the API-price cost used in the current window and the estimated value of the whole limit ("100% ≈ $1,918"): cost since the window start divided by % used.
  - The window start is reset time minus window length.
  - It counts all devices, because limits are per account. Other devices only report whole days, so their first day counts fully.
  - Shown once the limit is at least 5% used.
- Idea: with the plan price (e.g. Max $200/month) this becomes "your plan is worth N× its price". This needs a plan-price setting.

### v0.21.0 — new mark: Prompt T_
- **New logo.** Picked from three candidate rounds (`docs/logo-candidates*.png`), in the monochrome pixel-type spirit of Vibe Usage's mark: a black terminal block with a green `>` prompt, a pixel **T** and a green `_` cursor, on an 11×10 grid.
- **Where it's used.**
  - App icon: the mark on a light rounded tile.
  - Menu bar: a template image, a solid block with the glyphs cut out.
  - Panel header: a light block with a dark T.
- **Sharp at small sizes.** Cells snap to half points, so every logo pixel is a whole screen pixel on Retina.

### v0.20.0 — provider-split charts and a logo
- **Provider split.** Trend bars stack by provider in the provider colors, in cost or token mode, with a legend. While hovering, the legend shows each provider's value for that bar. Time mode stays one color, because active time can't be split. Settings → Overview shows → "Split chart by provider".
- **Logo.** A 16×16 pixel-art token (violet coin with a pixel "T").
  - The app draws it itself: the app icon (`Tokenly --make-iconset`, turned into `Tokenly.icns` by build.sh), a black-and-white menu bar icon (ring and T only), and the panel header.
  - `docs/logo.png` is used in the README.

### v0.18.0 — fold / unfold instead of pages
The Overview / Breakdown / History tabs are replaced by one fold control. Folded (the default) shows only the overview. "Show all" at the bottom, or the chevron in the header, unfolds Breakdown and History below it on one scrolling page, with section labels. The state is remembered.

### v0.17.0 — Tokenly, and a quieter Overview
- **Renamed from TokenMeter to Tokenly.**
  - App, bundle id (`io.github.longado.tokenly`), CLI (`tokenly`), repo and price file (`~/.config/tokenly/prices.json`).
  - On first launch the app migrates settings, price overrides and the other-devices cache. The CLI still reads the old price file if the new one is missing.
- **Less on one page.**
  - The period is shown once, on the pills. The headline label appears only when a filter is active.
  - Hidden by default: the tokens / calls / active line, the chart's peak label, plan-limit pace details, and the period stats card. Each one can be turned on in **Settings → Overview shows**.
  - Plan limits show percentage and time to reset. "May run out before reset" appears only when the pace says so.
  - The footer keeps only the refresh time and its buttons.
- **Plain menu bar.** No orange or red text unless Settings → "Color the menu bar at the alert level" is on.

### v0.16.1 — bottom card follows the period
The Overview bottom card showed fixed Today / 7-day / 30-day totals, which ignored the selected period. It now shows numbers for the selected period: active days (or active hours for single-day views), busiest day (or hour) with its date, and cache savings.

### v0.16.0 — more lessons from Vibe Usage
- **Plan-limit pace.** A thin second bar under each limit shows how much of the window has passed. A pace line projects usage at reset ("on pace for 124% — may run out", orange from 100%, red from 120%). Window lengths: Claude 5h / 7d; Codex `window_minutes`.
- **Chart metric switch.** `$ / Tok / Time` on the trend strip; the activity calendar follows it. Time is active time, this Mac only. Hover shows cost, tokens and active time.
- **Two-line menu bar.** New menu bar format "Cost over tokens (two lines)", drawn by SwiftUI inside the status item, with clicks passed through. The cost line turns orange or red at the plan-limit alert.
- **Refresh spinner.** The footer shows a spinner while a scan runs.

### v0.15.0 — choose any period
- **Period pills.** Today / 24H / 7D / 30D / 90D / All / Custom, as one row of pills, the way Vibe Usage presents its date filter. They replace the period dropdown.
- **Custom.** Shows From / To date fields. Ranges of one day chart by hour, up to 120 days by day, and longer ranges by month. The comparison uses the previous period of the same length.
- **Device picker** moved to its own line, shared with the "picked day ✕" pill.
- **No zero line.** Calls and active time are hidden when the period has no data from this Mac.

### v0.14.2 — readable over light windows
The see-through glass panel washed out over white windows. The panel (and desktop widget) now has a solid dark background by default; Settings → Appearance → "Solid background" turns the glass back on.

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
  - History older than 8 days is fetched once in 30-day `from/to` chunks and cached in `~/Library/Caches/Tokenly/vibe-history.json`. The cache is keyed by a hash of the account key.
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
  - `~/.config/tokenly/prices.json` overrides or adds models for both the app and the CLI.
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
- Quota data is whatever the tool last cached locally. Tokenly never calls provider APIs or reads credentials.
- UI self-check:
  ```
  Tokenly --snapshot out.png [today|24h|week|month|90d|dayN] [--popover|--settings] [provider=…] [model=…] [project=…] [mode=…] [hover=N]
  ```
