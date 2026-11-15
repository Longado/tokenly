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

### P1 — analysis depth
1. **Hourly view for Today.** 24 hourly slots, starting at local midnight. Hover shows tokens and cost for that hour.
2. **Hover values** on activity dots and bars, with one hover region per chart rather than one per element.
3. **Active time.** Sum of gaps between consecutive calls that are shorter than 5 minutes, shown per range.
4. **Menu bar format setting.** Choose cost, tokens, or fullest quota %, with the alert threshold configurable.
5. **More ranges.** 24H (rolling, deliberately distinct from Today) and 90D. The scan window grows to cover 90D plus its delta.

### P2 — product polish
6. **Settings window.** Menu bar format, launch at login, show desktop widget, alert threshold, price overrides.
7. **Single price table.** `prices.json` (bundled default plus a user override at `~/.config/tokenmeter/prices.json`), shared by the app and `tokenmeter.py`.
8. **Model names.** Merge variants of the same model (effort suffixes, router prefixes, context sizes) and truncate long names in the middle with a tooltip.
9. **More sources.** OpenCode (`~/.local/share/opencode`) and Gemini CLI, once their usage formats are confirmed.
10. **CLI parity.** `tokenmeter --quota` and `--by provider`.
11. **Auto-update (Sparkle).** Only after the app has a Developer ID signature.

### Engineering notes
- Claude messages are deduplicated by `message.id + requestId` across all files, kept in memory for the app's lifetime.
- Codex `last_token_usage.input_tokens` includes cached tokens, so the cached amount is subtracted from input.
- Quota data is whatever the tool last cached locally. TokenMeter never calls provider APIs or reads credentials.
- UI self-check:
  ```
  TokenMeter --snapshot out.png [today|week|month|dayN] [--popover] [provider=…] [model=…] [project=…] [mode=…]
  ```
