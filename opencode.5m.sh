#!/usr/bin/env bash
# <xbar.title>OpenCode Go Usage</xbar.title>
# <xbar.version>1.5.0</xbar.version>
# <xbar.author>gon</xbar.author>
# <xbar.desc>OpenCode Go quota % (5h + weekly) with schema-drift detection</xbar.desc>
# <xbar.dependencies>bun,jq,numfmt,sqlite3</xbar.dependencies>

set -euo pipefail

BUN="${BUN:-/Users/gon/.bun/bin/bun}"
JQ="${JQ:-/opt/homebrew/bin/jq}"
NUMFMT="${NUMFMT:-/opt/homebrew/bin/numfmt}"
SQLITE="${SQLITE:-/usr/bin/sqlite3}"
OC_DB="${OC_DB:-$HOME/.local/share/opencode/opencode.db}"

PROVIDER_FILTER="opencode-go"

sql_cost_since() {
  local seconds="$1"
  "$SQLITE" "$OC_DB" "SELECT printf('%.6f', COALESCE(SUM(json_extract(data, '\$.cost')), 0)) FROM message WHERE time_created > (CAST(strftime('%s', 'now') AS INTEGER) - $seconds) * 1000 AND json_extract(data, '\$.providerID') = '$PROVIDER_FILTER';" 2>/dev/null
}

sql_recent_rows() {
  local seconds="$1"
  "$SQLITE" "$OC_DB" "SELECT COUNT(*) FROM message WHERE time_created > (CAST(strftime('%s', 'now') AS INTEGER) - $seconds) * 1000;" 2>/dev/null
}

pct_of() {
  awk -v c="$1" -v cap="$2" 'BEGIN{ if (c+0==0) {print "0"} else {printf "%d", (c/cap)*100} }'
}

fmt_money() {
  printf '$%.2f' "$1" 2>/dev/null
}

color_for() {
  local pct="$1"
  if [[ "$pct" == "?" ]]; then echo "#ff8800"; return; fi
  if (( pct >= 80 )); then echo "#ff3333"
  elif (( pct >= 50 )); then echo "#ffaa00"
  else echo "#33dd33"
  fi
}

emit_drift_warning() {
  echo "WARNING: SQL/CLI mismatch (schema drift?) | color=#ff3333"
}

NOW_HMS=$(date +%H:%M:%S)

IN=""
OUT=""
COST_RAW=""

if [[ ! -f "$OC_DB" ]]; then
  echo "OC: no data"
  echo "---"
  echo "Last refresh: $NOW_HMS"
  echo "Refresh | refresh=true"
  exit 0
fi

RC=0
JSON=$("$BUN" x --bun opencode-usage --stats --json --since 1d 2>/dev/null) || RC=$?
if [[ $RC -ne 0 ]]; then
  echo "OC ?"
  echo "---"
  echo "opencode-usage CLI failed (exit $RC)"
  echo "Try: bunx --bun opencode-usage --stats --json --since 1d"
  echo "Last refresh: $NOW_HMS"
  echo "Refresh | refresh=true"
  exit 0
fi

COST_5H=$(sql_cost_since 18000) || COST_5H=""
COST_7D=$(sql_cost_since 604800) || COST_7D=""
COST_30D=$(sql_cost_since 2592000) || COST_30D=""
RECENT_5H=$(sql_recent_rows 18000) || RECENT_5H="0"

if [[ -n "$COST_5H" ]]; then PCT_5H=$(pct_of "$COST_5H" 12); else PCT_5H="?"; fi
if [[ -n "$COST_7D" ]]; then PCT_7D=$(pct_of "$COST_7D" 30); else PCT_7D="?"; fi
if [[ -n "$COST_30D" ]]; then PCT_30D=$(pct_of "$COST_30D" 60); else PCT_30D="?"; fi
if [[ -n "$COST_5H" ]]; then MONEY_5H="$(fmt_money "$COST_5H") / \$12"; else MONEY_5H="(error)"; fi
if [[ -n "$COST_7D" ]]; then MONEY_7D="$(fmt_money "$COST_7D") / \$30"; else MONEY_7D="(error)"; fi
if [[ -n "$COST_30D" ]]; then MONEY_30D="$(fmt_money "$COST_30D") / \$60"; else MONEY_30D="(error)"; fi

C5=$(color_for "$PCT_5H")
CW=$(color_for "$PCT_7D")
CM=$(color_for "$PCT_30D")

TODAY=$(date +%Y-%m-%d)
TODAY_UTC=$(TZ=UTC date +%Y-%m-%d)
JQ_RC=0
if ! ROW=$(echo "$JSON" | "$JQ" -re --arg t "$TODAY_UTC" '.periods[]? | select(.date == $t) | [.totals.input // 0, .totals.output // 0, .totals.cost // 0] | @tsv' 2>/dev/null); then
  JQ_RC=$?
  ROW=""
fi

PERIOD_COUNT=$(echo "$JSON" | "$JQ" '.periods | length' 2>/dev/null || echo 0)

if [[ $JQ_RC -ne 0 ]]; then
  echo "S: ?% W: ?% | color=#ff8800"
  echo "---"
  echo "jq parse failed (exit $JQ_RC) - schema may have changed"
  echo "Last refresh: $NOW_HMS"
  echo "Refresh | refresh=true"
  exit 0
fi

SCHEMA_DRIFT=0
if [[ -z "$ROW" && "$PERIOD_COUNT" -gt 0 ]]; then
  SCHEMA_DRIFT=1
fi
if [[ -z "$ROW" && -n "$JSON" ]]; then
  CLI_TOTAL_COST=$(echo "$JSON" | "$JQ" -r '.totals.cost // empty' 2>/dev/null)
  if [[ -n "$CLI_TOTAL_COST" ]] && awk -v a="$CLI_TOTAL_COST" 'BEGIN{exit !(a+0>0)}'; then
    SCHEMA_DRIFT=1
  fi
fi
COST_RAW=""
if [[ -n "$ROW" ]]; then
  OLD_IFS=$IFS
  IFS=$'\t' read -r IN OUT COST_RAW <<<"$ROW"
  IFS=$OLD_IFS
  if [[ -z "$IN" || -z "$OUT" || -z "$COST_RAW" ]]; then
    SCHEMA_DRIFT=1
  fi
  if ! [[ "$IN" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$OUT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    SCHEMA_DRIFT=1
  fi
fi

if [[ -n "$COST_RAW" ]] && [[ "${COST_5H:-0}" == "0.000000" || -z "$COST_5H" ]] && [[ "${RECENT_5H:-0}" -gt 0 ]]; then
  if awk -v a="$COST_RAW" 'BEGIN{exit !(a+0>0)}'; then
    SCHEMA_DRIFT=1
  fi
fi

if [[ -z "$ROW" || $SCHEMA_DRIFT -eq 1 ]]; then
  if [[ $SCHEMA_DRIFT -eq 1 ]]; then
    echo "S: ?% W: ?% M: ?% | color=#ff8800"
  else
    MAX_PCT=$PCT_5H
    if [[ "$PCT_7D" != "?" && ( "$MAX_PCT" == "?" || PCT_7D -gt MAX_PCT ) ]]; then
      MAX_PCT=$PCT_7D
    fi
    if [[ "$PCT_30D" != "?" && ( "$MAX_PCT" == "?" || PCT_30D -gt MAX_PCT ) ]]; then
      MAX_PCT=$PCT_30D
    fi
    BAR_COLOR=$(color_for "$MAX_PCT")
    echo "S: ${PCT_5H}% W: ${PCT_7D}% M: ${PCT_30D}% | color=$BAR_COLOR"
  fi
  echo "---"
  echo "Date (local): $TODAY"
  echo "Date (CLI/UTC): $TODAY_UTC"
  echo "5h rolling:    ${PCT_5H}% (${MONEY_5H}) | color=$C5"
  echo "    resets: see opencode.ai | color=#888888"
  echo "Weekly:        ${PCT_7D}% (${MONEY_7D}) | color=$CW"
  echo "    resets: see opencode.ai | color=#888888"
  echo "Monthly:       ${PCT_30D}% (${MONEY_30D}) | color=$CM"
  echo "    resets: see opencode.ai | color=#888888"
  if [[ $SCHEMA_DRIFT -eq 1 ]]; then
    emit_drift_warning
  fi
  echo "---"
  if [[ -n "$IN" && -n "$OUT" ]]; then
    TOTAL_TOKENS=$(awk -v a="$IN" -v b="$OUT" 'BEGIN{print a+b}')
    TOKENS_SI=$(echo "$TOTAL_TOKENS" | "$NUMFMT" --to=si --format="%.1f")
    echo "Tokens in: $(echo "$IN" | "$NUMFMT" --to=si --format="%.1f")"
    echo "Tokens out: $(echo "$OUT" | "$NUMFMT" --to=si --format="%.1f")"
    echo "Total: ${TOKENS_SI}"
    if [[ -n "$COST_RAW" ]]; then
      COST_FMT=$(printf '$%.4f' "$COST_RAW" 2>/dev/null | sed 's/0\+$//; s/\.$//')
      echo "Cost today (API-eq): ${COST_FMT}"
    fi
  else
    echo "Tokens in: 0"
    echo "Tokens out: 0"
    echo "Total: 0"
  fi
  echo "(Go subscription is flat-fee) | color=#888888"
  echo "---"
  echo "Last refresh: $NOW_HMS"
  echo "Refresh | refresh=true"
  exit 0
fi

TOTAL_TOKENS=$(awk -v a="$IN" -v b="$OUT" 'BEGIN{print a+b}')
TOKENS_SI=$(echo "$TOTAL_TOKENS" | "$NUMFMT" --to=si --format="%.1f")
MAX_PCT=$PCT_5H
if [[ "$PCT_7D" != "?" && ( "$MAX_PCT" == "?" || PCT_7D -gt MAX_PCT ) ]]; then
  MAX_PCT=$PCT_7D
fi
if [[ "$PCT_30D" != "?" && ( "$MAX_PCT" == "?" || PCT_30D -gt MAX_PCT ) ]]; then
  MAX_PCT=$PCT_30D
fi
BAR_COLOR=$(color_for "$MAX_PCT")
echo "S: ${PCT_5H}% W: ${PCT_7D}% M: ${PCT_30D}% | color=$BAR_COLOR"
echo "---"
echo "Date (local): $TODAY"
echo "Date (CLI/UTC): $TODAY_UTC"
echo "5h rolling:    ${PCT_5H}% (${MONEY_5H}) | color=$C5"
echo "    resets: see opencode.ai | color=#888888"
echo "Weekly:        ${PCT_7D}% (${MONEY_7D}) | color=$CW"
echo "    resets: see opencode.ai | color=#888888"
echo "Monthly:       ${PCT_30D}% (${MONEY_30D}) | color=$CM"
echo "    resets: see opencode.ai | color=#888888"
echo "---"
echo "Tokens in: $(echo "$IN" | "$NUMFMT" --to=si --format="%.1f")"
echo "Tokens out: $(echo "$OUT" | "$NUMFMT" --to=si --format="%.1f")"
echo "Total: ${TOKENS_SI}"
COST_FMT=$(printf '$%.4f' "$COST_RAW" 2>/dev/null | sed 's/0\+$//; s/\.$//')
echo "Cost today (API-eq): ${COST_FMT}"
echo "(Go subscription is flat-fee) | color=#888888"
echo "---"
echo "Last refresh: $NOW_HMS"
echo "Refresh | refresh=true"
