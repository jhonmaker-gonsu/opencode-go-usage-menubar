#!/usr/bin/env bash
# <xbar.title>Claude Code Usage</xbar.title>
# <xbar.version>1.1.0</xbar.version>
# <xbar.author>gon</xbar.author>
# <xbar.desc>Claude Code message quota (5h + 7d + 30d) from local JSONL</xbar.desc>
# <xbar.dependencies>jq,numfmt</xbar.dependencies>

CACHE_DIR="${TMPDIR:-/tmp}"
CACHE="${CACHE_DIR}/claude-menubar-cache"
LOCK="${CACHE_DIR}/claude-menubar-cache.lockdir"
SCRIPT=/Users/gon/SwiftBar/claude.5m.sh.bak
PLAN="${CLAUDE_PLAN:-max5x}"
PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

NOW=$(date +%s)
MAX_AGE=240

if [[ -f "$CACHE" ]] && [[ $(($NOW - $(stat -f %m "$CACHE" 2>/dev/null || echo 0))) -lt $MAX_AGE ]]; then
  cat "$CACHE"
  exit 0
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  if [[ -f "$CACHE" ]]; then
    cat "$CACHE"
  else
    echo "CC ... | color=#888888"
    echo "---"
    echo "Loading (first run, 5s) | color=#888888"
    echo "Refresh | refresh=true"
  fi
  exit 0
fi

( CLAUDE_PLAN="$PLAN" CLAUDE_PROJECTS="$PROJECTS" "$SCRIPT" > "${CACHE}.new" 2>/dev/null
  mv "${CACHE}.new" "$CACHE"
  rmdir "$LOCK" 2>/dev/null
) &

if [[ -f "$CACHE" ]]; then
  cat "$CACHE"
else
  echo "CC ... | color=#888888"
  echo "---"
  echo "Loading (first run, 5s) | color=#888888"
  echo "Refresh | refresh=true"
fi
