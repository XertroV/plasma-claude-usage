# Multi-Profile Panel Redesign — Design Spec

**Date:** 2026-07-14  
**Status:** Approved (brainstorming)  
**Scope:** KDE Plasma 6 usage widget — panel-first multi-profile dashboard, live timers, profile discovery, MiniMax provider, configurable quota visibility.

**Parity reference:** `~/src/quotas` (Rust CLI) — parsers, window labeling, auth discovery, and refresh intervals should stay aligned when quotas changes land.

---

## Goals

1. **Panel-first UX** — the compact panel strip is the primary interface; users glance up during long coding sessions.
2. **One row per profile** — each distinct auth profile (e.g. `Claude-w`, `Claude-p`, `Grok-2`, `Codex`) gets its own row in the panel.
3. **Information-dense, elegant rows** — two primary quota windows per row with pace-colored mini-bars, usage %, and live countdowns; optional extra windows inline or on a second micro-row.
4. **Live timers** — 1-second tick for countdowns and pace recalculation; tiered display format.
5. **Auto profile discovery** — scan `~/.<provider>/` and `~/.<provider>-{p,w,1,2}` (and provider-specific variants); deduplicate via inode; prefer real dirs/hardlinks over symlinks.
6. **Configurable visibility** — per-window toggles; custom display names per profile row; custom non-standard config paths.
7. **New provider: MiniMax** — OAuth via `~/.mmx/config.json`, API key fallbacks, `general` + `video` windows.
8. **Claude Fable parity** — surface `weekly_fable` and other scoped limits as first-class windows (like quotas `claude.rs`).
9. **Codex banked resets** — `↻N` badge on row by default.
10. **Respect API rate limits** — per-provider refresh floors; Claude 10 min floor, 15 min default.

---

## Non-Goals (v1)

- Fetching Codex banked-reset credit detail endpoint (display count only; detail deferred).
- CN MiniMax surface (`api.minimaxi.com` cookie auth).
- Multi-widget instance orchestration (one widget shows all profiles).
- Redeeming banked resets.
- Persisting discovery results across Plasma restarts without re-scan (re-scan on load is fine).

---

## Plasma UI Terminology

| User term | Plasma term | Access |
|-----------|-------------|--------|
| Panel strip | `compactRepresentation` | Always visible in panel |
| Expanded view (bars, "By Model (Weekly)") | `fullRepresentation` | Click panel widget |
| Config window | KCM (`configGeneral.qml`) | Right-click → Configure |

The expanded view is retained but redesigned to mirror panel row data at larger scale. The collapsible model/extra limits section stays.

---

## Panel Layout

### Row structure (hybrid B + D)

Each enabled profile renders one **ProviderRow**:

```
[label]  [win1: bar % countdown] | [win2: bar % countdown] | [extra chips…] [↻N]
```

- **Row label:** user-customizable display name; default derived from profile id (`claude-w` → `Claude-w`).
- **Primary windows (default on):** provider-specific session + weekly pair (see table below).
- **Extra windows (default off, configurable):** inline chips after primaries when enabled — `Fable 87%`, `spk 49%`, `video 12%`.
- **Adaptive layout:** 1 extra + wide panel → promote inline on primary row; 2+ extras → compact chips (D-style); tooltip on chip shows full countdown + pace.
- **Codex banked badge:** `↻3` at row end when `banked_resets > 0`; on by default; not a toggleable window.

### Primary window defaults per provider

| Provider | Primary windows (default on) | Extras (default off) |
|----------|------------------------------|----------------------|
| Claude | `5h`, `weekly` | `weekly_fable`, `weekly_oracle`, other `limits[]` scoped, legacy `seven_day_*` |
| Codex | primary session + weekly (duration-mapped) | `spk/*`, additional rate limits, credits $ |
| MiniMax | `5h/general`, `wk/general` | `5h/video`, `wk/video` |
| Grok | monthly $ allowance, weekly build credits | on-demand cap, prepaid balance |
| Z.ai | tokens 5h, monthly MCP | — |
| Kimi | session ~5h, weekly | `total_quota` |
| OpenCode | defers to sub-provider mapping | sub-provider extras |

### Pace coloring (D)

Reuse existing `capacity` / `efficiency` color modes per window. Color drives mini-bar fill and optional dot on chips. Configurable per window class in KCM (inherit global defaults initially).

### Panel sizing

- **Height:** `rowCount × rowHeight + padding` (taller panel, bounded width).
- **Width:** implicit from content; Plasma `Layout.minimumWidth` per row; truncate with ellipsis only as last resort on narrow panels.

---

## Live Timers

### Tick interval

Replace 60s `timePercentTimer` with **1s timer** when any visible window has `resetAt`.

### Tiered countdown format

Based on milliseconds remaining until `resetAt`:

| Remaining | Format | Example |
|-----------|--------|---------|
| ≥ 48 h (2 days) | `{d}d {h}h` | `6d 21h` |
| ≥ 1 h | `{h}h {m}m` | `2h 14m` |
| < 1 h | `{m}m {s}s` | `14m 32s` |
| ≤ 0 | `now` or trigger refresh | — |

On window boundary crossing, optionally trigger a single profile refresh.

### Derived values (updated each tick)

- `timePercent` — elapsed fraction of window period.
- `pace` — `usagePercent / max(1, timePercent)`.
- Bar widths and colors bound to these properties.

---

## Data Model

### ProfileInstance

```javascript
{
  id: "claude-w",              // stable: provider + canonical path hash or dirname
  provider: "claude",
  profileKey: "w",             // "" | "p" | "w" | "1" | "2" | ...
  configDir: "/home/.../.claude-w",  // canonical (non-symlink preferred)
  credPath: "/home/.../.claude-w/.credentials.json",
  credInode: "dev:ino",      // dedup key
  displayName: "Claude-w",     // user override from config
  enabled: true,               // show row in panel
  lastFetch: Date,
  error: "",
  bankedResets: 0,           // Codex only
  planName: "Max 5x",
  windows: [ UsageWindow, ... ]
}
```

### UsageWindow

```javascript
{
  id: "weekly_fable",          // stable within provider
  label: "Fable",              // short display
  usagePercent: 87.0,
  resetAt: Date | null,
  periodMs: number,
  role: "primary" | "extra" | "badge",
  providerDefaultVisible: true | false,
  visible: true,               // user toggle
}
```

### State ownership

- `ProfileRegistry` — discovered profiles, dedup, enable/disable, display names.
- `ProfileFetcher` — per-profile XHR, staggered refresh, 429 backoff.
- `UsageController` — bridges registry + fetchers → root properties for UI.

---

## Profile Discovery

### Executable: `contents/scripts/discover-profiles.sh`

Invoked via `Plasma5Support.DataSource` (`engine: executable`). Emits single JSON array to stdout.

### Provider registry (scan targets)

| Provider | Dir bases | Suffixes | Auth path (relative to dir) | Flat file |
|----------|-----------|----------|----------------------------|-----------|
| `claude` | `.claude` | `-p`, `-w`, `-1`, `-2` | `.credentials.json` | — |
| `codex` | `.codex` | `-p`, `-w`, `-1`, `-2` | `auth.json` | — |
| `grok` | `.grok` | `-p`, `-w`, `-1`, `-2` | `auth.json` | — |
| `minimax` | `.mmx` | `-p`, `-w`, `-1`, `-2` | `config.json` | `~/.minimax` (key file) |
| `zai` | `.zai` | `-p`, `-w`, `-1`, `-2` | (key file patterns) | `~/.api-zai` |
| `kimi` | `.kimi`, `.moonshot` | suffixes | per quotas | `~/.kimi-for-coding` |
| `opencode` | XDG paths | — | `auth.json`, `anthropic-accounts.json` | — |

### Additional sources

- `$CLAUDE_CONFIG_DIR/.credentials.json`
- `$GROK_HOME/auth.json`
- `$MINIMAX_API_KEY` (env-only pseudo-profile if no file)
- `$HOME/.local/share/opencode/auth.json` (+ XDG + `~/.config/opencode/`)
- User-configured **custom profile entries** in KCM: `{ provider, path, displayName? }`

### Dedup algorithm

1. Collect all candidate `(configDir, credPath)` pairs.
2. Resolve `credPath` to canonical absolute path (`readlink -f`).
3. Compute dedup key: `(st_dev, st_ino)` of cred file.
4. For duplicates sharing inode:
   - **Prefer** path whose containing directory is a real directory (not symlink).
   - If tie, prefer shorter canonical path.
   - Drop symlink-only aliases (e.g. `~/.claude` → same inode as `~/.claude-w` → keep `~/.claude-w`).
5. Assign `profileKey` from dirname suffix (`claude-w` → `w`; bare `claude` → ``).
6. Emit stable `id` = `{provider}-{profileKey || "default"}` with inode disambiguation if needed.

### Default visibility

**All distinct discovered profiles with valid creds are enabled by default** so users can compare quotas across profiles and decide when to switch.

---

## Authentication per Provider

### Claude

- `configDir/.credentials.json` → `claudeAiOauth.accessToken`
- Header: `anthropic-beta: oauth-2025-04-20`

### Codex

- `configDir/auth.json` → `tokens.access_token`, `tokens.account_id`
- OpenCode `openai` slot fallback when scanning opencode auth

### Grok

- `configDir/auth.json` → newest non-expired `key` (existing logic)
- Dual fetch: billing + `?format=credits`

### MiniMax (new)

**Auth resolution order per profile:**

1. `configDir/config.json` → `oauth.access_token`, `oauth.expires_at`, `resource_url` (default `https://api.minimax.io`)
2. Flat `~/.minimax` API key (separate flat-file profile)
3. `$MINIMAX_API_KEY`
4. OpenCode `minimax-coding-plan.key`

**Endpoint:** `{resource_url}/v1/api/openplatform/coding_plan/remains`  
**Parser:** Port quotas `minimax.rs` — `general` + `video`; count and percent branches; **invert** `current_interval_usage_count` / `current_weekly_usage_count` (they are remaining, not used).

### Z.ai, Kimi, OpenCode

Existing logic; keyed by `configDir` / opencode slot instead of single global path.

---

## Parsers — Quota Window Parity

### Claude

- `five_hour`, `seven_day` → primary windows.
- Top-level `seven_day_<model>` → extra windows (`weekly_fable`, etc.).
- `limits[]` where `kind === "weekly_scoped"` → extras with model display names.
- Do not double-count aggregate weekly into extras.

### Codex

- Existing duration-based slot mapping (Pro 7d-only fix retained).
- `additional_rate_limits` → extras.
- `rate_limit_reset_credits.available_count` → `bankedResets` on profile (not a window).

### MiniMax

- Labels: `5h/general`, `wk/general`, `5h/video`, `wk/video` (short names via quotas `short_model_name` rules).

---

## Refresh Policy

### Per-provider intervals

| Provider | Floor | Default | Config key |
|----------|-------|---------|------------|
| Claude | 10 min | **15 min** | `claudeRefreshMinutes` |
| Others | 1 min | 5 min | `refreshInterval` (existing) |

- User `refreshInterval` applies to non-Claude providers.
- Claude uses `claudeRefreshMinutes` (default 15, min 10).
- Attempting to set Claude below 10 min → clamp to 10 with KCM hint.

### Staggering

On timer fire, queue profile fetches with ~2s stagger to avoid burst.

### 429 / rate limit handling

- Set profile `error` to localized "Rate limited".
- Exponential backoff: 2× interval, cap 60 min.
- Local countdown timers keep running (no extra API calls).

---

## Configuration (KCM)

### New / changed settings (`main.xml` + `configGeneral.qml`)

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `enabledProfiles` | StringList | `[]` (empty = all discovered) | Explicit allowlist; empty means all |
| `profileDisplayNames` | Map/StringList | `{}` | Custom row labels by profile `id` |
| `customProfiles` | StringList (JSON) | `[]` | `{provider, path, displayName?}` |
| `visibleWindows` | StringList | `[]` | Global window id toggles; merged per profile |
| `claudeRefreshMinutes` | Int | `15` | Claude-specific refresh (min 10) |
| `discoverOnLoad` | Bool | `true` | Re-run discovery on widget load |
| `showBankedBadge` | Bool | `true` | Codex ↻N badge |

### Settings UI sections

1. **Profiles** — table of discovered profiles: enable checkbox, display name field, cred path (read-only), rediscover button.
2. **Visible quotas** — per-provider window checkboxes (populated after first fetch or from saved ids).
3. **Refresh** — global interval + Claude-specific spinbox with floor note.
4. **Custom paths** — add non-standard profile directories.
5. Existing: pace format, color modes, session/weekly ratio.

### Custom display names

- Stored as `profileDisplayNames["claude-w"] = "Work Claude"`.
- Row label uses custom name if set, else auto `Claude-w`.
- Tooltip shows both if custom: `Work Claude (claude-w)`.

---

## File Structure (post-refactor)

```
contents/
  scripts/
    discover-profiles.sh       # profile scan + dedup → JSON
  ui/
    main.qml                   # PlasmoidItem shell, timers
    UsageController.qml        # orchestration (QtObject or singleton)
    ProfileRegistry.qml        # discovery, dedup merge, config
    providers/
      ClaudeParser.js
      CodexParser.js
      GrokParser.js
      MinimaxParser.js
      ZaiParser.js
      KimiParser.js
      OpencodeParser.js
      common.js                # formatWindowDuration, window helpers
    components/
      ProviderRow.qml          # one panel row
      QuotaSlot.qml            # primary window: bar + % + countdown
      QuotaChip.qml            # extra window chip
      BankedBadge.qml          # ↻N
      ExpandedProfileView.qml  # fullRepresentation per profile
    configGeneral.qml          # extended KCM
  config/
    main.xml                   # new keys
fixture-examples/
  2026-07-13-minimax-coding-plan-remains.json  # copy from quotas live fixture
```

`main.qml` target: ≤400 lines (shell only); parsers in `.js` importable from QML.

---

## Expanded View (fullRepresentation)

- One section per enabled profile (mirrors panel rows at larger scale).
- Retain collapsible **By Model (Weekly)** / **Extra limits** per profile.
- Refresh button triggers staggered refresh all.
- Footer: last global update time.

---

## Tooltip

On panel hover: all visible windows for all rows with countdown + pace summary:

```
Claude-w: 5h 47% (2h 14m, on pace) | 7d 23% (6d 21h)
Codex: 5h 49% (4h 02m) | 7d 12% | ↻3 banked
```

---

## Testing

### Manual (primary — no automated QML test harness)

1. `./install.sh` + restart plasmashell.
2. Verify discovery finds `.claude-w`, `.claude-p`, `.grok-1`, `.grok-2` without dupes from symlinks.
3. Panel shows one row per profile; custom display name applies.
4. Countdown ticks every second; format switches at 48h and 1h boundaries.
5. Claude refresh ≥10 min; default 15 min; no 429 under normal use.
6. Codex row shows `↻N` when banked > 0.
7. MiniMax OAuth via `~/.mmx/config.json` parses general + video.
8. Fable window appears when API returns it; toggle off hides chip.
9. Expanded view model section still works.

### Fixture-based parser tests

Shell script `tests/parse-fixtures.sh` (new): feed fixture JSON through Node/qml test runner or documented manual JSON → expected windows table. At minimum document expected outputs in spec appendix for each fixture file.

### Discovery script test

```bash
contents/scripts/discover-profiles.sh | jq .
# Assert: .claude-w present, ~/.claude symlink not duplicated
```

---

## Implementation Phases (high level)

1. **Foundation** — `UsageWindow` model, `discover-profiles.sh`, `ProfileRegistry`, split parsers to `.js`.
2. **Multi-fetch** — per-profile fetch with stagger + per-provider refresh intervals.
3. **Panel UI** — `ProviderRow`, `QuotaSlot`, live 1s timer, pace colors.
4. **MiniMax + Claude Fable** — new provider + expanded Claude windows.
5. **KCM** — profiles table, custom names, window toggles, custom paths.
6. **Expanded view** — refactor `fullRepresentation` to multi-profile.
7. **Polish** — tooltips, banked badge, fixtures, CLAUDE.md update.

---

## Appendix: Fixture expected outputs (MiniMax live)

From `quotas/tests/fixtures/minimax/coding_plan_remains_live.json` (timestamps adjusted):

| Window id | used | limit | notes |
|-----------|------|-------|-------|
| `5h/general` | 1 | 100 | from remaining_percent 99 |
| `wk/general` | 2 | 100 | from remaining_percent 98 |
| `5h/video` | 0 | 3 | count-based |
| `wk/video` | 0 | 21 | count-based |

---

## Decisions Log

| Decision | Rationale |
|----------|-----------|
| All distinct profiles on by default | User compares across profiles to decide when to switch |
| Claude 15 min default, 10 min floor | Avoid 429s; user confirmed |
| Show banked as ↻N badge | Ergonomic, on by default, not a full window |
| Prefer real dirs over symlinks in dedup | User has `~/.claude` → `~/.claude-w` |
| Shell discovery script | QML cannot stat inodes / walk symlinks reliably |
| Custom row display names | User request |
| Keep expanded view | User uses "By Model (Weekly)" section |