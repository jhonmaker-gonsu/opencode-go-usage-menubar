#!/usr/bin/env bash
# <xbar.title>Claude Code Usage</xbar.title>
# <xbar.version>2.1.0</xbar.version>
# <xbar.author>gon</xbar.author>
# <xbar.desc>Claude Code usage: 5h/weekly + server data (auth) + credits</xbar.desc>
# <xbar.dependencies>jq,numfmt</xbar.dependencies>

CACHE_DIR="${TMPDIR:-/tmp}"
CACHE="${CACHE_DIR}/claude-menubar-cache"
LOCK="${CACHE_DIR}/claude-menubar-cache.lockdir"
REFRESH="$HOME/SwiftBar/.claude-refresh.sh"

NOW=$(date +%s)
MAX_AGE=240

if [[ -s "$CACHE" ]] && [[ $(($NOW - $(stat -f %m "$CACHE" 2>/dev/null || echo 0))) -lt $MAX_AGE ]]; then
  cat "$CACHE"
  exit 0
fi

LOCK_OK=0
if ! mkdir "$LOCK" 2>/dev/null; then
  LOCK_AGE=$(( NOW - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if (( LOCK_AGE >= MAX_AGE )); then
    rmdir "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
      LOCK_OK=1
    fi
  fi
  if [[ "$LOCK_OK" != "1" ]]; then
    if [[ -s "$CACHE" ]]; then
      cat "$CACHE"
    else
      echo "CC ... | color=#888888"
      echo "---"
      echo "Loading (first run, 5s) | color=#888888"
      echo "Refresh | refresh=true"
    fi
    exit 0
  fi
else
  LOCK_OK=1
fi

nohup "$REFRESH" >/dev/null 2>&1 &
disown 2>/dev/null || true

if [[ -s "$CACHE" ]]; then
  cat "$CACHE"
else
  echo "CC ... | color=#888888"
  echo "---"
  echo "Loading (first run, 5s) | color=#888888"
  echo "Refresh | refresh=true"
fi
