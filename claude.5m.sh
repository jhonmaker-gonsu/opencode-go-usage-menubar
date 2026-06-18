#!/usr/bin/env bash
# <xbar.title>Claude Code Usage</xbar.title>
# <xbar.version>1.0.1</xbar.version>
# <xbar.author>gon</xbar.author>
# <xbar.desc>Claude Code message quota (5h + 7d + 30d) from local JSONL</xbar.desc>
# <xbar.dependencies>jq,numfmt</xbar.dependencies>

set -euo pipefail

JQ="${JQ:-/opt/homebrew/bin/jq}"
NUMFMT="${NUMFMT:-/opt/homebrew/bin/numfmt}"
CLAUDE_PROJECTS="${CLAUDE_PROJECTS:-$HOME/.claude/projects}"
CLAUDE_PLAN="${CLAUDE_PLAN:-pro}"
CLAUDE_PROJECT="${CLAUDE_PROJECT:-}"
CLAUDE_MTIME_DAYS="${CLAUDE_MTIME_DAYS:-365}"

case "$CLAUDE_PLAN" in
  pro)    CAP_5H=45  ;;
  max5x)  CAP_5H=225 ;;
  max20x) CAP_5H=900 ;;
  *)      CAP_5H=45  ;;
esac

NOW_HMS=$(date +%H:%M:%S)
C5_CUTOFF=$(TZ=UTC date -u -v-5H  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '5 hours ago'  +%Y-%m-%dT%H:%M:%SZ)
C7_CUTOFF=$(TZ=UTC date -u -v-7d  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '7 days ago'  +%Y-%m-%dT%H:%M:%SZ)
C30_CUTOFF=$(TZ=UTC date -u -v-30d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)

pct_of() {
  awk -v c="$1" -v cap="$2" 'BEGIN{ if (cap+0==0) {print "n/a"} else if (c+0==0) {print "0"} else {printf "%d", (c/cap)*100} }'
}

color_for() {
  local pct="$1"
  if [[ "$pct" == "?" || "$pct" == "n/a" ]]; then echo "#ff8800"; return; fi
  if (( pct >= 80 )); then echo "#ff3333"
  elif (( pct >= 50 )); then echo "#ffaa00"
  else echo "#33dd33"
  fi
}

if [[ ! -d "$CLAUDE_PROJECTS" ]]; then
  echo "CC: no data"
  echo "---"
  echo "No Claude projects dir at $CLAUDE_PROJECTS | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

if [[ ! -x "$JQ" ]]; then
  echo "CC ?"
  echo "---"
  echo "jq not found at $JQ | color=#ff3333"
  echo "Install: brew install jq | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

if [[ ! -x "$NUMFMT" ]]; then
  echo "CC ?"
  echo "---"
  echo "numfmt not found at $NUMFMT | color=#ff3333"
  echo "Install: brew install coreutils | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

mapfile -d '' JSONL_FILES < <(
  find "$CLAUDE_PROJECTS" \
    -name "*.jsonl" \
    -not -path "*/subagents/*" \
    -mtime "-${CLAUDE_MTIME_DAYS}" \
    ${CLAUDE_PROJECT:+-path "*/$CLAUDE_PROJECT/*"} \
    -print0 2>/dev/null
)

if [[ ${#JSONL_FILES[@]} -ge 500 ]]; then
  echo "CC ?"
  echo "---"
  echo "Too many JSONL files (${#JSONL_FILES[@]} >= 500) | color=#ff3333"
  echo "Refusing to parse; set CLAUDE_PROJECT to narrow | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

if [[ ${#JSONL_FILES[@]} -eq 0 ]]; then
  echo "CC 0"
  echo "---"
  echo "No JSONL sessions found in last ${CLAUDE_MTIME_DAYS}d | color=#888888"
  echo "Set CLAUDE_PROJECT for per-project view | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

INNER='select(.type == "assistant") | {ts: (.timestamp // ""), in: (.message.usage.input_tokens // 0), out: (.message.usage.output_tokens // 0), cc: (.message.usage.cache_creation_input_tokens // 0), cr: (.message.usage.cache_read_input_tokens // 0)}'

OUTER='. as $o | ($o.ts // "") as $t | ($o.in // 0) as $i | ($o.out // 0) as $ot | ($o.cc // 0) as $cc | ($o.cr // 0) as $cr | (["T", $t, $i, $ot, $cc, $cr]), (if (($t | type) == "string") and ($t >= $c5)  then ["5",  $t, $i, $ot, $cc, $cr] else empty end), (if (($t | type) == "string") and ($t >= $c7)  then ["7",  $t, $i, $ot, $cc, $cr] else empty end), (if (($t | type) == "string") and ($t >= $c30) then ["30", $t, $i, $ot, $cc, $cr] else empty end) | @tsv'

TSV=$(
  for f in "${JSONL_FILES[@]}"; do
    grep '^{' "$f" 2>/dev/null | "$JQ" -c "$INNER" 2>/dev/null || true
  done \
    | "$JQ" -r --arg c5 "$C5_CUTOFF" --arg c7 "$C7_CUTOFF" --arg c30 "$C30_CUTOFF" "$OUTER"
) || TSV=""

if [[ -z "$TSV" ]]; then
  echo "CC ?"
  echo "---"
  echo "jq pipeline produced no rows | color=#ff3333"
  echo "Possible causes: schema drift, type-field rename (assistant -> assistant_v2), or all JSONL corrupt | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

SUMMARY=$(echo "$TSV" | awk -F'\t' '
  {
    tag = $1
    if (tag == "T") { n_records++; next }
    w = tag + 0
    counts[w]++
    is[w]  += $3 + 0
    os[w]  += $4 + 0
    ccs[w] += $5 + 0
    crs[w] += $6 + 0
    n_rows++
  }
  END {
    printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      n_records+0, n_rows+0, counts[5]+0, counts[7]+0, counts[30]+0, \
      is[5]+0, os[5]+0, ccs[5]+0, crs[5]+0, \
      is[7]+0, os[7]+0, ccs[7]+0, crs[7]+0, \
      is[30]+0, os[30]+0, ccs[30]+0, crs[30]+0
  }
')

if [[ -z "$SUMMARY" ]]; then
  echo "CC ?"
  echo "---"
  echo "awk summary produced no output | color=#ff3333"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

OLD_IFS=$IFS
IFS=$'\t' read -r N_RECORDS N_ROWS C5 C7 C30 T5_IN T5_OUT T5_CC T5_CR T7_IN T7_OUT T7_CC T7_CR T30_IN T30_OUT T30_CC T30_CR <<<"$SUMMARY"
IFS=$OLD_IFS

for v in "$N_RECORDS" "$N_ROWS" "$C5" "$C7" "$C30" \
         "$T5_IN" "$T5_OUT" "$T5_CC" "$T5_CR" \
         "$T7_IN" "$T7_OUT" "$T7_CC" "$T7_CR" \
         "$T30_IN" "$T30_OUT" "$T30_CC" "$T30_CR"; do
  if ! [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "CC ?"
    echo "---"
    echo "Malformed TSV row from jq pipeline | color=#ff3333"
    echo "Last refresh: $NOW_HMS | color=#888888"
    echo "Refresh | refresh=true"
    exit 0
  fi
done

if [[ ${#JSONL_FILES[@]} -gt 0 ]] && [[ "$N_RECORDS" -eq 0 ]]; then
  echo "CC ?"
  echo "---"
  echo "jq filter matched 0 records across ${#JSONL_FILES[@]} files | color=#ff3333"
  echo "Possible type-field rename (e.g. assistant -> assistant_v2) | color=#888888"
  echo "Last refresh: $NOW_HMS | color=#888888"
  echo "Refresh | refresh=true"
  exit 0
fi

PCT_5H=$(pct_of "$C5" "$CAP_5H")
C5_COLOR=$(color_for "$PCT_5H")

if [[ "$C5" -eq 0 ]]; then
  echo "CC 0 | color=#33dd33 tooltip=No Claude usage in last 5h"
else
  echo "CC ${C5}/${CAP_5H} ${PCT_5H}% | color=$C5_COLOR tooltip=Claude ${CLAUDE_PLAN}: ${C5} of ${CAP_5H} messages in last 5h"
fi
echo "---"
echo "Plan: ${CLAUDE_PLAN} (5h cap: ${CAP_5H}) | color=#888888"
echo "5h rolling:    ${C5} msg / ${CAP_5H} cap (${PCT_5H}%) | color=$C5_COLOR"
echo "    resets: server-side, no client signal | color=#888888"
echo "Weekly:        ${C7} msg (informational) | color=#33dd33"
echo "Monthly:       ${C30} msg (informational) | color=#33dd33"
echo "---"
T5_TOTAL=$(awk -v a="$T5_IN" -v b="$T5_OUT" -v c="$T5_CC" -v d="$T5_CR" 'BEGIN{print a+b+c+d}')
echo "Tokens 5h in:    $(echo "$T5_IN" | "$NUMFMT" --to=si --format="%.1f") | color=#888888"
echo "Tokens 5h out:   $(echo "$T5_OUT" | "$NUMFMT" --to=si --format="%.1f") | color=#888888"
echo "Tokens 5h cache: $(echo "$T5_CC" | "$NUMFMT" --to=si --format="%.1f") created + $(echo "$T5_CR" | "$NUMFMT" --to=si --format="%.1f") read | color=#888888"
echo "Tokens 5h total: $(echo "$T5_TOTAL" | "$NUMFMT" --to=si --format="%.1f") | color=#33dd33"
echo "---"
echo "Set CLAUDE_PROJECT to a project slug from ls ~/.claude/projects/ | color=#888888"
echo "(e.g. -Users-gon-Desktop-foo; leading dash is optional) | color=#888888"
echo "---"
echo "Last refresh: $NOW_HMS | color=#888888"
echo "Refresh | refresh=true"
