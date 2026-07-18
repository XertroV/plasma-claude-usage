# Claude Usage Widget

A KDE Plasma 6 widget that displays AI coding usage quotas in the taskbar (Claude, Codex, Grok, Z.ai, OpenCode).

![Popup](screenshots/popup.png)

## Features

- **Multi-provider**: Claude, Codex (OpenAI), Grok (xAI), Z.ai, and OpenCode sub-providers (configure in widget settings)
- **Compact Panel Display**: Shows session and weekly usage percentages right in your taskbar
  ![Panel](screenshots/panel.png)
- **Color-coded Indicators**: Green / yellow / red by capacity or efficiency pace
- **Detailed Popup**: Click to see full statistics
  - Dynamic window labels (e.g. Codex `5h` / `7d`, Grok weekly + monthly $)
  - Reset times and time-elapsed bars
  - Per-model / extra limits (Claude weekly_scoped, Codex Spark, banked resets)
  - Subscription plan badge
- **Auto-refresh**: Configurable interval
- **Quota reset celebration**: Desktop notification + matching account-card bounce when a session/weekly window rolls over
- **Reset event log**: Structured logs under `~/.cache/plasma-claude-usage/resets/` (natural vs early/late/surprise)
- **Error Handling**: Clear messages when not logged in or token expired
- **No Dependencies**: Pure QML, no Python or external tools required

## Requirements

- KDE Plasma 6.0 or later
- Credentials for the provider you select (e.g. `claude` / `codex login` / `grok login`)

## Installation

### From KDE Store

1. Right-click on your panel
2. Select "Add Widgets..."
3. Click "Get New Widgets..." > "Download New Plasma Widgets..."
4. Search for "Claude Usage"
5. Click Install

### Manual Installation

```bash
kpackagetool6 -t Plasma/Applet -i claude-usage-widget.plasmoid
```

### From Source

```bash
git clone https://github.com/anthropics/claude-usage-widget.git
cd claude-usage-widget
kpackagetool6 -t Plasma/Applet -i .
```

## Usage

1. Make sure you're logged in to Claude Code (run `claude` in terminal)
2. Add the widget to your panel
3. Click the widget to see detailed usage statistics

## How It Works

The widget reads OAuth credentials from local files (e.g. `~/.claude/.credentials.json`) and calls each provider's usage API directly. Tokens are never written to the response/reset cache. Optional local caches under `~/.cache/plasma-claude-usage/` store API response envelopes and quota-reset events for debugging.

### API Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer <oauth-token>
  anthropic-beta: oauth-2025-04-20
```

## Troubleshooting

### "Not logged in" error

Make sure you're logged in to Claude Code:
```bash
claude
```

### "Token expired" error

Your OAuth token has expired. Run Claude Code again to refresh it:
```bash
claude
```

### Widget shows 0%

- Click the refresh button in the popup
- Check logs: `journalctl --user -f | grep -i claude`

### Inspect live API responses

Every provider response is cached (by default) under:

```
~/.cache/plasma-claude-usage/latest/          # most recent per profile+endpoint
~/.cache/plasma-claude-usage/responses/YYYY/MM/DD/   # historical
```

Disable or change the path in widget settings (Response cache / Cache path).

### Inspect quota reset events

When a window resets between polls, the widget can notify and log:

```
~/.cache/plasma-claude-usage/resets/events.jsonl
~/.cache/plasma-claude-usage/resets/latest/
~/.cache/plasma-claude-usage/resets/YYYY/MM/DD/
```

```bash
tail -n 5 ~/.cache/plasma-claude-usage/resets/events.jsonl | jq .
```

Each event records observed time, window id, previous/new usage %, expected `resetAt`, and `kind` (`natural` / `early` / `late` / `surprise`). Toggle notify/log in widget settings.

## File Structure

```
claude-usage-widget/
├── metadata.json           # Widget metadata
├── contents/
│   ├── ui/
│   │   └── main.qml        # Widget implementation
│   └── icons/
│       └── claude.svg      # Claude logo (orange)
└── screenshots/            # Preview images
```

## License

GPL-3.0-or-later

## Author

izll

## Version History

### 1.0.0 (2025)
- Initial release
- Session and weekly usage display
- Per-model breakdown (Sonnet/Opus)
- Auto-refresh every minute
- Error handling for login issues
