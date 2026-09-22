#!/usr/bin/env bash
#
# Refresh the holidays that cannot be derived.
#
# The national ones are arithmetic — nine fixed dates and four that hang off
# Easter — and the program computes them for any year without asking anybody.
# The state and municipal ones are not: they are law, one município at a time,
# and the only honest way to know them is to read a published list.
#
#   ./scripts/calendar.sh              refresh, print what changed
#   ./scripts/calendar.sh --check      say whether it is current, write nothing
#
# It writes one `YYYY-MM-DD=Name` per line to state/local-holidays.txt, which
# the program reads at startup and merges into the calendar it derives.
#
# NOTHING IN THE PUNCH PATH TOUCHES THE NETWORK. This runs separately, on
# purpose: a holiday API that is slow or down at 07:51 must not be able to
# decide whether a punch happens. The file is the contract, and a file that is
# a year stale still skips every national holiday correctly — it just stops
# knowing about the municipal ones, which the run header says out loud.
#
# The write is atomic and refuses to leave less than it found: a fetch that
# half worked keeps the previous file rather than quietly dropping a holiday.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${CALENDAR_SOURCE:-https://raw.githubusercontent.com/joaopbini/feriados-brasil/master/dados/feriados}

# São Carlos/SP, where FAI is. Both overridable, so this is not a script only
# one person can run.
UF=${CALENDAR_UF:-SP}
IBGE=${CALENDAR_IBGE:-3548906}
OUT=${LOCAL_HOLIDAYS_FILE:-$REPO/state/local-holidays.txt}

check_only=false
[[ ${1:-} == --check ]] && check_only=true

command -v curl >/dev/null || { echo "calendar: curl is not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "calendar: jq is not on PATH" >&2; exit 1; }

this_year=$(date +%Y)
tmp=$(mktemp) && trap 'rm -f "$tmp" "$tmp.rows"' EXIT
: >"$tmp.rows"

fetched_any=false
reached=""

# This year and the two after it. The published data runs out somewhere ahead
# of the calendar, and where it runs out is the thing worth reporting: past
# that the program is on its derived national holidays alone.
for year in $(seq "$this_year" $((this_year + 2))); do
  year_rows=$(mktemp)
  ok=true

  for scope in estadual municipal; do
    url="$SOURCE/$scope/json/$year.json"
    body=$(curl -fsS -m 30 "$url" 2>/dev/null) || { ok=false; break; }

    case $scope in
      estadual) filter='[.[] | select(.uf == $uf and (.codigo_ibge // null) == null)]' ;;
      municipal) filter='[.[] | select((.codigo_ibge // 0) == ($ibge | tonumber))]' ;;
    esac

    jq -r --arg uf "$UF" --arg ibge "$IBGE" \
      "$filter"' | .[] | "\(.data[6:10])-\(.data[3:5])-\(.data[0:2])=\(.nome)"' \
      <<<"$body" >>"$year_rows" || { ok=false; break; }
  done

  if $ok; then
    fetched_any=true
    reached=$year
    cat "$year_rows" >>"$tmp.rows"
  else
    echo "calendar: $year is not published yet at the source; stopping there"
  fi
  rm -f "$year_rows"
done

$fetched_any || { echo "calendar: could not read the source; $OUT left as it was" >&2; exit 1; }

sort -u "$tmp.rows" -o "$tmp.rows"
found=$(wc -l <"$tmp.rows")
had=0
[[ -f $OUT ]] && had=$(grep -cve '^\s*#' -e '^\s*$' "$OUT" || true)

{
  echo "# The holidays this deployment cannot derive: state ($UF) and municipal"
  echo "# (IBGE $IBGE). Written by scripts/calendar.sh on $(date +%F), covering"
  echo "# $this_year through $reached."
  echo "#"
  echo "# The national holidays are deliberately NOT here — they are computed."
  echo "# Source: $SOURCE"
  echo
  cat "$tmp.rows"
} >"$tmp"

if $check_only; then
  if [[ -f $OUT ]] && diff -q "$tmp" "$OUT" >/dev/null; then
    echo "calendar: $OUT is current ($found holidays, through $reached)"
  else
    echo "calendar: $OUT is out of date; run without --check"
    exit 1
  fi
  exit 0
fi

# A source that suddenly knows less than the file does is a source that broke,
# not a year with fewer holidays. Keep what is on disk and say so.
if ((found < had)); then
  echo "calendar: the source lists $found where $OUT has $had; keeping the file" >&2
  echo "calendar: run with CALENDAR_SOURCE= pointed elsewhere, or delete $OUT to force" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
mv "$tmp" "$OUT"
chmod 0644 "$OUT"

echo "calendar: wrote $found holidays to $OUT, covering $this_year through $reached"
sed -e '/^#/d' -e '/^$/d' "$OUT" | sed 's/^/  /'
