#!/usr/bin/env bash
#
# Install a user systemd timer that runs acuttis-point at the times in .env.
#
# Nothing here reschedules itself: systemd has to be told the times up front, so
# this has to be re-run after .env changes. It prints the next elapse so the
# result is visible rather than assumed.
#
#   ./scripts/schedule.sh entry --on 2026-08-14   one punch, one day
#   ./scripts/schedule.sh all                     every punch + the sweep
#   ./scripts/schedule.sh sweep                   only the end-of-day check
#   ./scripts/schedule.sh --status                what is scheduled now
#   ./scripts/schedule.sh --remove                stop and forget it
#
# `all` includes a sweep at SWEEP_TIME, after the last window has closed. It
# cannot register anything — by then every window is shut, so the only outcomes
# left are silence on a finished day and a loud refusal naming what is missing.
# That is the point: a run that failed at midday notifies once, and a
# notification missed is a punch forgotten. The sweep asks again at the end.
#
# Each punch fires between its configured time T and T+9 minutes, never before.
# That is what keeps the drift one-directional: set ENTRY_TIME and LUNCH_END
# nine minutes earlier than the times you actually want, and the punch lands at
# or before them, while LUNCH_START and EXIT land at or after theirs. Worked
# time can then only come out at or above the nominal day, never under it.

set -euo pipefail

readonly JITTER_SECONDS=540 # 9 minutes
# How far ahead of a punch the rehearsal runs. Enough to act on bad news — the
# punch itself can still be made by hand inside its window.
readonly PREFLIGHT_LEAD_MINUTES=15
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
  systemctl --user list-timers "$UNIT_NAME*" --all --no-pager || true
  echo
  echo "punches:"
  systemctl --user cat "$UNIT_NAME.timer" --no-pager 2>/dev/null |
    grep -E "OnCalendar|RandomizedDelaySec|Persistent" || echo "  not installed"
  echo "rehearsals:"
  systemctl --user cat "$UNIT_NAME-preflight.timer" --no-pager 2>/dev/null |
    grep -E "OnCalendar|RandomizedDelaySec|Persistent" || echo "  not installed"
}

remove() {
  systemctl --user disable --now "$UNIT_NAME.timer" 2>/dev/null || true
  systemctl --user disable --now "$UNIT_NAME-preflight.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$UNIT_NAME-preflight.timer" \
    "$UNIT_DIR/$UNIT_NAME-preflight.service"
  rm -f "$UNIT_DIR/$UNIT_NAME.timer" "$UNIT_DIR/$UNIT_NAME.service" \
    "$UNIT_DIR/$UNIT_NAME-failed.service"
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
  [sweep]=SWEEP_TIME
)

if [[ "$punches" == "all" ]]; then
  punches="entry,lunch-start,lunch-end,exit"
  # Only if configured: without a sweep time there is nothing to schedule.
  [[ -n "$(env_value SWEEP_TIME)" ]] && punches="$punches,sweep"
fi

calendar_lines=()
preflight_lines=()

minus_lead() {
  local total=$((10#${1%%:*} * 60 + 10#${1##*:} - PREFLIGHT_LEAD_MINUTES))
  # A rehearsal that would fall on the previous day is simply not scheduled.
  ((total < 0)) && return 1
  printf '%02d:%02d' $((total / 60)) $((total % 60))
}

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

  # The sweep only reports, so rehearsing it would be a rehearsal of a report.
  if [[ "$punch" != "sweep" ]] && lead="$(minus_lead "$time")"; then
    if [[ -n "$on_date" ]]; then
      preflight_lines+=("OnCalendar=$on_date $lead:00")
    else
      preflight_lines+=("OnCalendar=$days *-*-* $lead:00")
    fi
  fi
done

# The sweep may only report, and that holds only once every window has closed.
# Scheduled any earlier it would be free to register the very punch it exists to
# report as missing.
if [[ ",$punches," == *",sweep,"* ]]; then
  to_minutes() { echo $((10#${1%%:*} * 60 + 10#${1##*:})); }
  sweep_at="$(to_minutes "$(env_value SWEEP_TIME)")"
  exit_at="$(to_minutes "$(env_value EXIT_TIME)")"
  tolerance="$(env_value TIME_TOLERANCE_MINUTES)"
  last_window=$((exit_at + ${tolerance:-10} + JITTER_SECONDS / 60))
  ((sweep_at > last_window)) ||
    die "SWEEP_TIME is not past the last window (exit + tolerance + jitter); it could register the punch it is meant to report as missing"
fi

# --out-link, never --no-link: the symlink is a GC root, and without one the
# store path is garbage and gets collected. That happened on 2026-08-17 — the
# unit was left pointing at a path that no longer existed, systemd failed with
# 203/EXEC, and nothing notified, because the notification comes from inside the
# program that could not start. The unit points at the symlink rather than the
# store path, so a later rebuild does not leave the unit stale either.
echo "schedule: building the package"
mkdir -p "$REPO/state"
nix build "$REPO#default" --out-link "$REPO/state/current" >/dev/null
binary="$REPO/state/current/bin/acuttis-point"
[[ -x "$binary" ]] || die "the build produced no runnable binary"

mkdir -p "$UNIT_DIR"

# A failure notifier at the systemd layer, because the program cannot report a
# failure to start. Everything else notifies from inside the run; this covers the
# case where there is no run.
cat >"$UNIT_DIR/$UNIT_NAME-failed.service" <<UNIT
[Unit]
Description=Say out loud that the Acuttis punch run failed

[Service]
Type=oneshot
ExecStart=$(command -v bash) -c '\
  url=\$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?NOTIFY_URL[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -1); \
  [ -n "\$url" ] || exit 0; \
  $(command -v curl) --silent --show-error --max-time 15 \
    --header "Title: Punch run did not start" \
    --header "Priority: urgent" \
    --header "Tags: rotating_light" \
    --data "systemd could not run acuttis-point. Punch by hand and check: journalctl --user -u acuttis-point.service -n 20" \
    "\$url" >/dev/null'
UNIT

cat >"$UNIT_DIR/$UNIT_NAME.service" <<UNIT
[Unit]
Description=Register the timekeeping punch due now on Acuttis
After=network-online.target
Wants=network-online.target
OnFailure=$UNIT_NAME-failed.service

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
systemctl --user enable "$UNIT_NAME.timer" >/dev/null
# Restart, not just start: a timer that already fired its last OnCalendar sits in
# `elapsed`, and neither daemon-reload nor `enable --now` recomputes it there. It
# would silently keep the old schedule and never fire again.
systemctl --user restart "$UNIT_NAME.timer"

# The rehearsals: same program, PREFLIGHT=true, on their own timer. Separate
# because they must not be jittered — a rehearsal drifting nine minutes later
# would land inside the window it is supposed to run ahead of.
if ((${#preflight_lines[@]} > 0)); then
  cat >"$UNIT_DIR/$UNIT_NAME-preflight.service" <<UNIT
[Unit]
Description=Rehearse the next Acuttis punch without registering it
After=network-online.target
Wants=network-online.target
OnFailure=$UNIT_NAME-failed.service

[Service]
Type=oneshot
Environment=ENV_FILE=$ENV_FILE
Environment=PREFLIGHT=true
WorkingDirectory=$REPO
ExecStart=$binary
UNIT

  {
    echo "[Unit]"
    echo "Description=Rehearsals ahead of today's Acuttis punches"
    echo
    echo "[Timer]"
    printf '%s\n' "${preflight_lines[@]}"
    echo "Unit=$UNIT_NAME-preflight.service"
    echo "AccuracySec=1s"
    # No RandomizedDelaySec on purpose: see above.
    echo "Persistent=false"
    echo
    echo "[Install]"
    echo "WantedBy=timers.target"
  } >"$UNIT_DIR/$UNIT_NAME-preflight.timer"

  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME-preflight.timer" >/dev/null
  systemctl --user restart "$UNIT_NAME-preflight.timer"
fi

echo "schedule: installed"
printf '  %s\n' "${calendar_lines[@]}"
echo "  each fires between its time and +9 minutes"
if ((${#preflight_lines[@]} > 0)); then
  echo "  rehearsals ${PREFLIGHT_LEAD_MINUTES} minutes ahead, exact:"
  printf '    %s\n' "${preflight_lines[@]}"
fi
echo
systemctl --user list-timers "$UNIT_NAME.timer" --all --no-pager
