# OpenCode Go Usage — macOS Menubar Widget

SwiftBar plugin that surfaces your **OpenCode Go** subscription usage in the macOS menubar.

## What it shows

- **Menubar** (single line): `S: <5h>%  W: <weekly>%  M: <monthly>%` with color coding (green <50%, yellow 50–80%, red ≥80%).
- **Dropdown**:
  - 5h rolling, weekly, monthly bars with `$X.XX / $cap`
  - Reset-time note (server-side only — see `https://opencode.ai/auth`)
  - Today's tokens (in/out/total) + cost (API-equivalent; Go is flat-fee)
  - "Last refresh" timestamp
  - Schema-drift WARNING if data sources desync

## Caps (per `https://opencode.ai/docs/go`)

- 5h rolling: **$12**
- Weekly: **$30**
- Monthly: **$60**

## Install

```bash
# 1. Install SwiftBar
brew install --cask swiftbar

# 2. Copy plugin
mkdir -p ~/SwiftBar
cp opencode.5m.sh ~/SwiftBar/
chmod +x ~/SwiftBar/opencode.5m.sh

# 3. Point SwiftBar at the plugin folder
defaults write com.ameba.SwiftBar PluginFolder -string "$HOME/SwiftBar"

# 4. Launch
open -a SwiftBar
```

The first refresh takes 10–30s (bunx download); subsequent refreshes are <1s. Refresh interval is 5 min (encoded in the filename `opencode.5m.sh`).

## How it works

1. **5h cost** — direct SQLite query on the local opencode DB (`~/.local/share/opencode/opencode.db`), filtered to `providerID = 'opencode-go'`. CLI cannot do hours-granularity (`--since 5h` is unsupported).
2. **Weekly / monthly cost** — `bunx opencode-usage --stats --json --since 7d/30d` (CLI is fine for day-granularity).
3. **Today's tokens** — same CLI, `--since 1d`, jq-extracted.
4. **TZ handling** — `TODAY_UTC` for the jq match, `TODAY` (local) for the human display; both shown in the dropdown.
5. **Schema-drift detection** — cross-checks SQL cost vs CLI total cost + recent row count. Fires a WARNING in the dropdown if the filter is silently dropping real rows.

## Requirements

- macOS (uses `set -euo pipefail`, GNU `numfmt` from Homebrew, BSD `sqlite3`)
- `bun`, `jq`, `numfmt`, `sqlite3` (all in Homebrew: `brew install bun jq`)
- OpenCode installed and run at least once (creates `~/.local/share/opencode/opencode.db`)

## Files

- `opencode.5m.sh` — the plugin (single bash file, ~220 lines)
- `PLAN_20260618-172137.md` — original design plan (3 iterations refined)
- `PLAN_20260618-172137-LONGTERM.md` — long-term correctness plan (23 failure modes, 36 tests)

## Customizing

Override defaults via env vars:

| Var | Default | Purpose |
|---|---|---|
| `BUN` | `~/.bun/bin/bun` | bun binary path |
| `JQ` | `/opt/homebrew/bin/jq` | jq path |
| `NUMFMT` | `/opt/homebrew/bin/numfmt` | numfmt path |
| `SQLITE` | `/usr/bin/sqlite3` | sqlite3 path |
| `OC_DB` | `~/.local/share/opencode/opencode.db` | opencode DB path |

Example: `OC_DB=/path/to/test.db BUN=/path/to/bun ~/SwiftBar/opencode.5m.sh`

## Known limitations

- **Reset times** are server-side only; the plugin shows "see opencode.ai" rather than scraping.
- **Plan caps** ($12/$30/$60) are hardcoded; will go stale if OpenCode changes them.
- **opencode-usage** is a third-party npm package; major version updates may break the JSON shape. Schema-drift detection catches this.
- **Long-term correctness** depends on production observation across day/week/month boundaries; see `PLAN_20260618-172137-LONGTERM.md` for the failure-mode catalog.
