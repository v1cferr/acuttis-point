#!/usr/bin/env bash
#
# Install a user systemd timer that runs acuttis-point at the times in .env.
#
# Nothing here reschedules itself: systemd has to be told the times up front, so
# this has to be re-run after .env changes. It prints the next elapse so the
# result is visible rather than assumed.
#
#   ./scripts/schedule.sh entry --on 2026-08-14   one punch, one day
#   ./scripts/schedule.sh all                     every punch, every work day
#   ./scripts/schedule.sh --status                what is scheduled now
#   ./scripts/schedule.sh --remove                stop and forget it
#
# Each punch fires between its configured time T and T+9 minutes, never before.
# That is what keeps the drift one-directional: set ENTRY_TIME and LUNCH_END
# nine minutes earlier than the times you actually want, and the punch lands at
# or before them, while LUNCH_START and EXIT land at or after theirs. Worked
# time can then only come out at or above the nominal day, never under it.

set -euo pipefail

readonly JITTER_SECONDS=540 # 9 minutes
readonly UNIT_NAME=acuttis-point
readonly REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
readonly ENV_FILE="$REPO/.env"

die() {
  echo "schedule: $*" >&2
  exit 1
}

# Reads a key from .env without sourcing it: a .env is not a shell script, and
# a stray backtick in a password should not become a command.
env_value() {
  local key="$1"
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=[[:space:]]*//p" \
    "$ENV_FILE" |
    tail -1 |
    sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' |
    tr -d '\r'
}

show_status() {
  systemctl --user list-timers "$UNIT_NAME.timer" --all --no-pager || true
  echo
  systemctl --user cat "$UNIT_NAME.timer" --no-pager 2>/dev/null |
    grep -E "OnCalendar|RandomizedDelaySec|Persistent" || echo "not installed"
}

remove() {
  systemctl --user disable --now "$UNIT_NAME.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.service"
  systemctl --user daemon-reload
  echo "schedule: removed"
}

case "${1:-}" in
--status)
  show_status
  exit 0
  ;;
--remove)
  remove
  exit 0
  ;;
"") die "say which punches to schedule: entry, lunch-start, lunch-end, exit, or all" ;;
esac

punches="$1"
shift

on_date=""
while [[ $# -gt 0 ]]; do
  case "$1" in
  --on)
    on_date="${2:-}"
    [[ -n "$on_date" ]] || die "--on needs a date, as YYYY-MM-DD"
    shift 2
    ;;
  *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$ENV_FILE" ]] || die "no .env in $REPO"

work_days="$(env_value WORK_DAYS)"
work_days="${work_days:-MON,TUE,WED,THU,FRI}"

# The application reads .env itself; the unit only needs to be pointed at it.
declare -A TIME_KEY=(
  [entry]=ENTRY_TIME
  [lunch-start]=LUNCH_START
  [lunch-end]=LUNCH_END
  [exit]=EXIT_TIME
)

[[ "$punches" == "all" ]] && punches="entry,lunch-start,lunch-end,exit"

calendar_lines=()
for punch in ${punches//,/ }; do
  key="${TIME_KEY[$punch]:-}"
  [[ -n "$key" ]] || die "unknown punch: $punch"

  time="$(env_value "$key")"
  [[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
    die "$key in .env is '$time', which is not HH:MM"

  if [[ -n "$on_date" ]]; then
    [[ "$on_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] ||
      die "--on wants YYYY-MM-DD, got '$on_date'"
    calendar_lines+=("OnCalendar=$on_date $time:00")
  else
    # WORK_DAYS uses the codes the application reads; systemd capitalises them
    # its own way.
    days="$(echo "$work_days" | tr 'A-Z' 'a-z' |
      sed -E 's/mon/Mon/g; s/tue/Tue/g; s/wed/Wed/g; s/thu/Thu/g; s/fri/Fri/g; s/sat/Sat/g; s/sun/Sun/g')"
    calendar_lines+=("OnCalendar=$days *-*-* $time:00")
  fi
done

echo "schedule: building the package"
binary="$(nix build "$REPO#default" --no-link --print-out-paths)/bin/acuttis-point"
[[ -x "$binary" ]] || die "the build produced no runnable binary"

mkdir -p "$UNIT_DIR"

cat >"$UNIT_DIR/$UNIT_NAME.service" <<UNIT
[Unit]
Description=Register the timekeeping punch due now on Acuttis
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=ENV_FILE=$ENV_FILE
Environment=LOG_FILE=$REPO/logs/runs.log
WorkingDirectory=$REPO
ExecStart=$binary
UNIT

{
  echo "[Unit]"
  echo "Description=Timekeeping punches due today on Acuttis"
  echo
  echo "[Timer]"
  printf '%s\n' "${calendar_lines[@]}"
  echo "Unit=$UNIT_NAME.service"
  echo "AccuracySec=1s"
  # Every punch lands between its configured time and nine minutes later, and
  # never before it. Direction is the whole point: see the note at the top.
  echo "RandomizedDelaySec=$JITTER_SECONDS"
  # A machine asleep at the minute runs on waking instead of losing the punch.
  # Safe only because a run that wakes past its tolerance refuses to register.
  echo "Persistent=true"
  echo
  echo "[Install]"
  echo "WantedBy=timers.target"
} >"$UNIT_DIR/$UNIT_NAME.timer"

systemctl --user daemon-reload
systemctl --user enable --now "$UNIT_NAME.timer" >/dev/null

echo "schedule: installed"
printf '  %s\n' "${calendar_lines[@]}"
echo "  each fires between its time and +9 minutes"
echo
systemctl --user list-timers "$UNIT_NAME.timer" --all --no-pager
