#!/usr/bin/env bash
set -euo pipefail

CACHE_DIR="${TMPDIR:-/tmp}"
CACHE="${CACHE_DIR}/claude-menubar-cache"
LOCK="${CACHE_DIR}/claude-menubar-cache.lockdir"
SCRIPT="$HOME/SwiftBar/claude.5m.sh.bak"
PLAN="${CLAUDE_PLAN:-max5x}"
PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"

if [[ "${CLAUDE_USE_AUTH:-1}" == "1" ]]; then
  "$HOME/SwiftBar/.claude-cdp-scraper.sh" >/dev/null 2>&1 || true
fi

CLAUDE_PLAN="$PLAN" CLAUDE_PROJECTS="$PROJECTS" \
  CLAUDE_USE_AUTH="${CLAUDE_USE_AUTH:-1}" \
  CLAUDE_AUTH_CACHE="${CLAUDE_AUTH_CACHE:-${CACHE_DIR}/claude-usage-auth.json}" \
  CLAUDE_AUTH_MAX_AGE="${CLAUDE_AUTH_MAX_AGE:-240}" \
  CLAUDE_FAMILIES_DEFAULT="${CLAUDE_FAMILIES_DEFAULT:-opus,sonnet,haiku,other}" \
  CLAUDE_MODEL="${CLAUDE_MODEL:-}" \
  CLAUDE_PROJECT="${CLAUDE_PROJECT:-}" \
  CLAUDE_MTIME_DAYS="${CLAUDE_MTIME_DAYS:-365}" \
  JQ="${JQ:-/opt/homebrew/bin/jq}" \
  NUMFMT="${NUMFMT:-/opt/homebrew/bin/numfmt}" \
  "$SCRIPT" > "${CACHE}.new" 2>/dev/null

if [[ -s "${CACHE}.new" ]]; then
  mv "${CACHE}.new" "$CACHE"
else
  rm -f "${CACHE}.new"
fi

rmdir "$LOCK" 2>/dev/null || true
