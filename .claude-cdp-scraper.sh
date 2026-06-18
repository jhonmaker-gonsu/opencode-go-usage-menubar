#!/usr/bin/env bash
# <xbar.title>Claude CDP scraper (internal)</xbar.title>
set -uo pipefail

PORT="${CLAUDE_CHROME_DEBUG_PORT:-9222}"
CACHE_DIR="${TMPDIR:-/tmp}"
AUTH_CACHE="${CACHE_DIR}/claude-usage-auth.json"
LOCK="${CACHE_DIR}/claude-usage-auth.lockdir"
EXTRACT="${CLAUDE_CDP_EXTRACT:-/Users/gon/SwiftBar/.claude-cdp-extract.py}"
CHROME_APP="/Applications/Google Chrome.app"
CHROME_PROFILE="${HOME}/.claude-swiftbar-chrome"
CHROME_LAUNCHER="${CLAUDE_CHROME_LAUNCHER:-/Users/gon/SwiftBar/.claude-swiftbar-chrome-launcher.sh}"
NOW=$(date +%s)
MAX_AGE="${CLAUDE_AUTH_MAX_AGE:-240}"
TIMEOUT_EXTRACT="${CLAUDE_AUTH_EXTRACT_TIMEOUT:-18}"

write_error() {
  local err="$1"
  local tmp="${AUTH_CACHE}.new"
  {
    printf '{"ok":false,"error":"%s","fetched_at":"%s"}' "$err" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp" 2>/dev/null
  mv "$tmp" "$AUTH_CACHE" 2>/dev/null
  chmod 600 "$AUTH_CACHE" 2>/dev/null
}

if [[ "${CLAUDE_USE_AUTH:-1}" != "1" ]]; then
  exit 0
fi

if [[ -f "$AUTH_CACHE" ]]; then
  AGE=$(( NOW - $(stat -f %m "$AUTH_CACHE" 2>/dev/null || echo 0) ))
  if (( AGE < MAX_AGE )); then
    exit 0
  fi
fi

if [[ -d "$LOCK" ]]; then
  LOCK_AGE=$(( NOW - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if (( LOCK_AGE < 120 )); then
    exit 0
  fi
  rm -rf "$LOCK" 2>/dev/null
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi

trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  if [[ ! -x "$CHROME_LAUNCHER" ]]; then
    cat > "$CHROME_LAUNCHER" <<'LAUNCHER'
#!/usr/bin/env python3
import os
import sys
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE = os.path.expanduser("~/.claude-swiftbar-chrome")
LOG = "/tmp/claude-swiftbar-chrome.log"
if os.fork() != 0:
    sys.exit(0)
os.setsid()
if os.fork() != 0:
    sys.exit(0)
os.chdir("/")
si = open("/dev/null", "r")
so = open(LOG, "ab", 0)
os.dup2(si.fileno(), 0)
os.dup2(so.fileno(), 1)
os.dup2(so.fileno(), 2)
os.execv(CHROME, [
    CHROME,
    "--remote-debugging-port=9222",
    "--user-data-dir=" + PROFILE,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--remote-allow-origins=*",
])
LAUNCHER
    chmod +x "$CHROME_LAUNCHER"
  fi
  "$CHROME_LAUNCHER" >/dev/null 2>&1 </dev/null &
  LAUNCHED=1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 0.5
    if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
      break
    fi
  done
  if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    write_error "chrome_launch_failed"
    exit 0
  fi
fi

if ! command -v jq >/dev/null 2>&1 && [[ ! -x /opt/homebrew/bin/jq ]]; then
  write_error "no_jq"
  exit 0
fi
JQ_BIN="${JQ:-/opt/homebrew/bin/jq}"
TAB_WS=$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/json" 2>/dev/null \
  | "$JQ_BIN" -r --arg u "https://claude.ai/settings/usage" \
      '.[] | select(.type=="page" and ((.url // "") | test($u))) | .webSocketDebuggerUrl' \
  2>/dev/null | head -1)
if [[ -z "$TAB_WS" || "$TAB_WS" == "null" ]]; then
  NEW_TAB_JSON=$(curl -fsS --max-time 5 -X PUT "http://127.0.0.1:${PORT}/json/new?https://claude.ai/settings/usage" 2>/dev/null)
  TAB_WS=$(printf '%s' "$NEW_TAB_JSON" | "$JQ_BIN" -r '.webSocketDebuggerUrl // empty' 2>/dev/null)
fi
if [[ -z "$TAB_WS" || "$TAB_WS" == "null" ]]; then
  write_error "no_tab_found"
  exit 0
fi

OUT_TMP="${AUTH_CACHE}.new"
RC=0
python3 "$EXTRACT" \
  --ws-url "$TAB_WS" \
  --target-url "https://claude.ai/settings/usage" \
  --timeout "$TIMEOUT_EXTRACT" \
  --port "$PORT" \
  > "$OUT_TMP" 2>/dev/null || RC=$?

if (( RC != 0 )) || [[ ! -s "$OUT_TMP" ]]; then
  write_error "extract_failed"
  exit 0
fi

if ! head -c 1 "$OUT_TMP" | grep -q '{'; then
  write_error "extract_invalid_json"
  exit 0
fi

mv "$OUT_TMP" "$AUTH_CACHE" 2>/dev/null
chmod 600 "$AUTH_CACHE" 2>/dev/null
