# Claude Usage Widget - Development Guide

## Project Overview

KDE Plasma 6 widget for AI coding usage quotas. Supports multiple providers via config:

| Provider | Credentials | Endpoint(s) |
|----------|-------------|-------------|
| Claude | `~/.claude/.credentials.json` | `api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` | `chatgpt.com/backend-api/wham/usage` |
| Grok | `~/.grok/auth.json` | `cli-chat-proxy.grok.com/v1/billing` (+ `?format=credits`) |
| Z.ai | OpenCode `auth.json` | `api.z.ai/.../quota/limit` |
| OpenCode | multi-account / auth.json | depends on sub-provider |

Parity reference: `~/src/quotas` (Rust CLI) — keep window labeling and auth discovery in sync when quotas changes land.

## Architecture

Pure QML, no external deps:

1. **Credentials**: `Plasma5Support.DataSource` executable engine (`cat $HOME/...`)
2. **API**: QML `XMLHttpRequest`
3. **UI**: Plasma / Kirigami
4. **Response cache**: every API response written via `contents/scripts/cache-response.sh`

## Response cache

Default root: `~/.cache/plasma-claude-usage` (override with `responseCachePath`; disable with `cacheResponses=false`).

```
{root}/responses/{YYYY}/{MM}/{DD}/{HHMMSS}-{ms3}-{provider}-{profileSlug}-{endpoint}.json
{root}/latest/{provider}-{profileSlug}-{endpoint}.json
```

Envelope JSON: `savedAt`, `savedAtMs`, `provider`, `profileId`, `endpoint`, `url`, `httpStatus`, `body` (parsed) / `raw` (on parse failure). Never stores tokens.

Inspect:

```bash
ls ~/.cache/plasma-claude-usage/latest/
ls ~/.cache/plasma-claude-usage/responses/$(date +%Y/%m/%d)/
jq . ~/.cache/plasma-claude-usage/latest/*-wham-usage.json | head
```

## Quota reset celebration + log (I006)

When successive polls show a window rolled to a new period (`resetAtMs` jumped and/or usage collapsed):

1. Desktop notification (toggle `notifyOnQuotaReset`, default on) — batched per profile.
2. Matching account card plays a short bounce/glow/emoji celebration (`celebrateGeneration` pulse; always on, local-only).
3. Structured log under the same cache root (toggle `logQuotaResets`, default on):

```
{root}/resets/{YYYY}/{MM}/{DD}/{HHMMSS}-{ms3}-{provider}-{profileSlug}-{windowId}.json
{root}/resets/latest/{provider}-{profileSlug}-{windowId}.json
{root}/resets/events.jsonl
```

Fields include `kind` (`natural` | `early` | `late` | `surprise`), `unexpected`, expected vs observed times, previous/new usage %. First successful poll never counts as a reset. Pure detection: `contents/ui/js/QuotaResetEvents.js`.

```bash
tail -n 5 ~/.cache/plasma-claude-usage/resets/events.jsonl | jq .
ls ~/.cache/plasma-claude-usage/resets/latest/
```

## Key Files

- `contents/ui/ProfileController.qml` — multi-profile fetch + response cache + reset celebrate/log
- `contents/ui/main.qml` — widget shell / UI
- `contents/ui/configGeneral.qml` — provider picker + paths
- `contents/ui/js/QuotaResetEvents.js` — pure reset detect / notify / log payload
- `contents/scripts/cache-response.sh` — atomic hist + latest write
- `contents/scripts/log-reset.sh` — atomic reset event + jsonl append
- `contents/icons/claude.svg` — icon
- `metadata.json` — Plasma metadata
- `fixture-examples/` — sample API payloads for offline reasoning
- `install.sh` — install helper

## Claude

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer <oauth-token>
  Content-Type: application/json
  anthropic-beta: oauth-2025-04-20   # required
```

Credentials: `~/.claude/.credentials.json` → `claudeAiOauth.accessToken`.

Plan tiers: `default_claude_pro` → Pro, `default_claude_max_5x` → Max 5x, `default_claude_max_20x` → Max 20x.

## Codex (OpenAI)

```
GET https://chatgpt.com/backend-api/wham/usage
Headers:
  Authorization: Bearer <access_token>
  ChatGPT-Account-Id: <account_id>   # when available
```

Credentials: `~/.codex/auth.json` → `tokens.access_token` / `tokens.account_id` (also OpenCode `openai` slot).

### Window mapping (important)

Payload uses `rate_limit.primary_window` / `secondary_window` with `limit_window_seconds`, `used_percent`, `reset_at` (unix seconds).

- **Classic Plus**: primary ~18000s (5h) + secondary ~604800s (7d) → session + weekly slots
- **Pro (2026-07+)**: primary-only 604800s, `secondary_window: null` → **weekly slot only** (do not show fake 0% session)
- Labels via `formatWindowDuration`: prefer whole days (`604800` → `7d`, never `168h`)

Additional limits (e.g. GPT-5.3-Codex-Spark) → `additionalLimits` as `spk/7d`. Banked resets: `rate_limit_reset_credits.available_count`.

Live fixture: `fixture-examples/2026-07-13-codex-wham-usage.json`.

## Grok (xAI / Grok Build)

Auth discovery: newest non-expired `key` in `~/.grok/auth.json` map (same as quotas `parse_grok_auth`).

```
GET https://cli-chat-proxy.grok.com/v1/billing
GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
Headers:
  Authorization: Bearer <session>
  x-grok-client-version: 0.2.93
  x-grok-client-surface: grok-build
```

- Default billing → monthly $ allowance (`monthlyLimit`/`used` in USD cents) → weekly UI slot as %
- `?format=credits` → weekly product usage % (`productUsage` / `creditUsagePercent`) → session UI slot
- Dual-fetch; default body required, credits best-effort

Fixtures: `fixture-examples/2026-07-13-grok-billing-*.json`.

## Testing

1. Install: `./install.sh`
2. Restart Plasma: `kquitapp6 plasmashell && kstart plasmashell`
3. Logs: `journalctl --user -f | grep -i claude`

## Common Issues

- **StandardPaths not working**: use `$HOME` env, not Qt StandardPaths
- **Claude 401**: missing `anthropic-beta` header
- **Codex Pro shows 0% weekly**: old parser put sole primary on session; use duration-based slot mapping
- **Codex "168h" label**: use day-preferring `formatWindowDuration`
- **Grok not logged in**: run `grok login`; credentials at `~/.grok/auth.json`

## Publishing

```bash
zip -r claude-usage-widget.plasmoid metadata.json contents/
```

Upload to https://store.kde.org/
