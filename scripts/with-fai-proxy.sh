#!/usr/bin/env bash
#
# Run acuttis-point with the browser going out through a machine on the
# university network, so the punch reaches Acuttis from a university address.
#
#   ./scripts/with-fai-proxy.sh                    one run, proxied
#   ./scripts/with-fai-proxy.sh --check            prove the path, run nothing
#   PREFLIGHT=true ./scripts/with-fai-proxy.sh     a rehearsal, proxied
#
# A punch is a record of having been at work, and the address it arrives from is
# part of that record. The university VPN alone does not produce one: it is a
# split tunnel, carrying only FAI's own subnets, so traffic to Acuttis leaves by
# the home connection regardless of whether the tunnel is up. Routing everything
# through it would not help either, since the gateway does not forward arbitrary
# destinations — a ping out of ppp0 to 1.1.1.1 gets no answer at all.
#
# So the traffic is not routed there, it originates there: an ssh tunnel to a
# host inside FAI, offered to Chromium as a SOCKS proxy. What makes the exit
# address right is not a claim in a config file but where the connection is
# made from — ssh reaching that host is itself the proof, so nothing here has to
# ask an outside service what our address looks like.
#
# The tunnel lives exactly as long as one run. Nothing else on this machine is
# pointed at it, no route changes, no system-wide VPN left on.

set -euo pipefail

readonly REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Reads a key from .env without sourcing it: a .env is not a shell script, and a
# stray backtick in a password should not become a command. The same reader
# `listen.sh` and `schedule.sh` use, so all three agree on what the file says.
env_value() {
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" \
    "${ENV_FILE:-$REPO/.env}" 2>/dev/null |
    tail -1 |
    sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' |
    tr -d '\r'
}

# One setting, from the environment if it is there and from .env if it is not.
#
# The environment wins the same way it does for the program, and an empty one is
# an answer rather than an absence: `NOTIFY_URL=` silences the phone for a test
# run and `PROXY_VPN_UNIT=` leaves the VPN alone, neither of which should fall
# through to a default. Only a name unset in both gets one.
#
# Until this existed the wrapper read nothing from .env, so `PROXY_SSH_HOST` in
# that file was only a flag telling the generators to use the wrapper at all —
# the host itself always came from the default below, and editing .env moved
# nothing. A `--check` by hand was testing a different host than production.
setting() {
  local name="$1" value
  if [[ -n "${!name+set}" ]]; then
    printf '%s' "${!name}"
    return 0
  fi
  value="$(env_value "$name")"
  printf '%s' "${value:-${2-}}"
}

# The ssh destinations, in order of preference: a Host block in ~/.ssh/config,
# or user@address, several of them separated by commas the way WORK_DAYS and
# SKIP_DATES are. The first that answers is the one the punch leaves from.
PROXY_SSH_HOST="$(setting PROXY_SSH_HOST fai-vm,workstation)"
# Where to start looking for a free loopback port. Loopback only: a SOCKS proxy
# on a reachable address is an open relay.
PROXY_PORT="$(setting PROXY_PORT 11080)"
# The VPN unit the host may only be reachable through. Empty never touches it.
PROXY_VPN_UNIT="$(setting PROXY_VPN_UNIT vpn-fai.service)"

# How many ports to consider before giving up.
readonly PORT_RANGE=40

# How long to wait for another run to finish. A run takes about forty seconds
# with the VPN to bring up, so this is room for a couple of them queued.
readonly LOCK_WAIT_SECONDS=180

# Only for the runs that can actually register something. An ask, a reminder, a
# rehearsal and an audit all read and none of them punch, so which address they
# read from is nobody's business — and while FAI's portal is down, warning about
# each of them would be a dozen alarms a day for a thing that did not happen.
can_punch() {
  [[ -n "${CLAIM_TOKEN:-}" || "${CLAIM_DEADLINE:-}" == "true" ]]
}

# The whole attempt at finding a host, bounded by what is left of the punch
# window rather than by patience.
#
# A deadline run fires eight to ten minutes into a ten minute window, so what it
# has is at most two minutes and sometimes seconds. Measured on 2026-10-16: it
# started at 08:29:21, spent sixty-six seconds deciding that one dead host was
# dead, and punched at 08:30:37 — twenty-three seconds to spare, and only
# because the timer's jitter happened to draw low. So the run that can least
# afford to wait is given the shortest rope.
readonly REACH_BUDGET_SECONDS=90
# Room for a VPN that has to come up, and not much more: the deadline run is the
# last chance to punch, so it may spend VPN_WAIT_SECONDS plus a probe and no
# third thing.
readonly REACH_DEADLINE_BUDGET_SECONDS=65

# Between rounds, when there is a tunnel up and a host is merely being unhappy.
readonly PROBE_ROUND_GAP=3

# The whole VPN attempt, bounded. It used to be thirty rounds of a five second
# ssh, which is minutes rather than seconds — and a punch window is ten minutes
# long. Better to give up early and punch from here than to spend the window
# waiting.
readonly VPN_WAIT_SECONDS=45

# What to do when there is no tunnel: punch from this machine anyway, or refuse.
#
# `direct` by default, and that is a change of mind with a morning behind it. The
# original reasoning was that a punch from the wrong address is worse than no
# punch. It is not: a missing punch means an e-mail to Gestão de Pessoas and a
# time reconstructed from memory, while a punch from home has never been
# questioned — and the markings already arrive from a phone, a browser and the
# kiosk in the building, so one more origin is not an anomaly. Today the
# fail-closed rule cost a punch and it had to be made by hand.
#
# It is never silent: falling back says so on the phone, before the punch.
PROXY_FALLBACK="$(setting PROXY_FALLBACK direct)"

readonly BINARY="${ACUTTIS_BINARY:-$REPO/state/current/bin/acuttis-point}"

die() {
  echo "with-fai-proxy: $*" >&2
  exit 1
}

say() {
  echo "with-fai-proxy: $*"
}

proxy_hosts=()
# The one that answered, filled in by `probe_hosts`. Empty until then.
proxy_host=""
probe_pids=()
probe_state=()
checking=false

parse_hosts() {
  local host
  local IFS=,
  for host in $1; do
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    [[ -n "$host" ]] && proxy_hosts+=("$host")
  done
  ((${#proxy_hosts[@]} > 0)) ||
    die "PROXY_SSH_HOST names no host to tunnel through"
}
parse_hosts "$PROXY_SSH_HOST"

# /dev/tcp rather than nc: this machine's `nc -z` exits silently whatever it
# finds, which has already been mistaken for a working tunnel once.
listening_on() {
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null
}

port_open() {
  listening_on "$PROXY_PORT"
}

# A port of this run's own.
#
# Runs overlap by design: a tap arriving five minutes into the window and the
# reminder scheduled at six are both legitimate, and each needs its own tunnel.
# With one fixed port the second one died with "already taken", which OnFailure
# turned into an urgent "Punch run did not start" — sent, on 2026-08-21, four
# seconds before the punch it was warning about landed. A false alarm about the
# one thing the notifications exist to be trusted about.
#
# The starting point is jittered so two runs beginning together are unlikely to
# choose the same candidate; if they do anyway, ExitOnForwardFailure makes ssh
# say so rather than proxying nothing.
free_port() {
  local candidate offset
  offset=$((RANDOM % PORT_RANGE))
  for ((i = 0; i < PORT_RANGE; i++)); do
    candidate=$((PROXY_PORT + (offset + i) % PORT_RANGE))
    listening_on "$candidate" || {
      echo "$candidate"
      return 0
    }
  done
  return 1
}

# BatchMode so a missing key fails instead of waiting for a passphrase nobody
# will type in a systemd unit. ControlPath=none keeps the tunnel independent of
# the shared master ~/.ssh/config sets up, whose ten minute persistence would
# otherwise decide whether this works.
#
# An array rather than a wrapper function, because the tunnel is backgrounded and
# `&` on a function forks a subshell: $! is then the subshell's pid, the kill on
# the way out hits that, and ssh is left orphaned holding the port. Which is
# exactly what happened the first time this ran.
#
# Twenty seconds, not seven. Seven was a guess and it was wrong in the direction
# that matters: with the tunnel up, its address assigned and ICMP flowing, ssh
# still reported "Connection timed out" at seven and connected fine at fifteen.
# The first SYN through the SonicWall takes longer than a local link would, and
# a retransmit lands somewhere past the old limit. The result was the fallback
# firing on a tunnel that worked, which is the opposite of the stated priority.
readonly SSH_CONNECT_TIMEOUT=20

readonly SSH_OPTS=(
  -o BatchMode=yes
  -o ControlPath=none
  -o "ConnectTimeout=$SSH_CONNECT_TIMEOUT"
)

vpn_started_here=false

# Every host at once, and the answer taken in configured order.
#
# At once because the window is not long enough to ask them one after another:
# two dead hosts in series is two ConnectTimeouts, and twenty seconds is already
# the smallest honest one. Asked together, the cost of a dead host is paid once
# no matter how many there are.
#
# In configured order because which machine a punch leaves from is a setting,
# not a race. A host wins by being first in the list among those that answered,
# never by being quickest to reply.
#
# The ssh is backgrounded directly rather than through a function: `&` on a
# function forks a subshell, $! is then the subshell's pid, and the kill on the
# way out hits that while ssh is left orphaned — the bug already recorded above
# SSH_OPTS. And 9>&- because fd 9 is the run lock: a probe that outlived this
# script still holding it would make the next run queue behind a process nobody
# is waiting for.
probe_hosts() {
  local want_all="${checking:-false}" host i

  probe_pids=()
  probe_state=()
  for host in "${proxy_hosts[@]}"; do
    env -u SSH_AUTH_SOCK ssh "${SSH_OPTS[@]}" -o ConnectionAttempts=1 \
      "$host" true >/dev/null 2>&1 9>&- &
    probe_pids+=("$!")
    probe_state+=("unknown")
  done

  proxy_host=""
  for i in "${!probe_pids[@]}"; do
    if wait "${probe_pids[$i]}"; then
      probe_state[i]=ok
      [[ -z "$proxy_host" ]] && proxy_host="${proxy_hosts[$i]}"
    else
      probe_state[i]=unreachable
    fi
    if [[ -n "$proxy_host" && "$want_all" != true ]]; then
      break
    fi
  done

  reap_probes
  [[ -n "$proxy_host" ]]
}

# Also called from cleanup, for the probes a `break` above left running.
reap_probes() {
  local pid
  ((${#probe_pids[@]} > 0)) || return 0
  for pid in "${probe_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  probe_pids=()
}

report_probe() {
  local i
  for i in "${!proxy_hosts[@]}"; do
    say "  ${proxy_hosts[$i]}: ${probe_state[$i]:-not tried}"
  done
}

tunnel_exists() {
  [[ -n "$(ip -o link show type ppp 2>/dev/null)" ]]
}

# The VPN is a property of the attempt rather than of a host: every destination
# lives on the same university network, so one route serves all of them. It is
# brought up at most once, only when nothing answered without it, and undone
# after — turning it on is a change to the whole system, so it happens only when
# it is the difference between a punch and no punch.
ensure_reachable() {
  local budget=$REACH_BUDGET_SECONDS
  if [[ "${CLAIM_DEADLINE:-}" == "true" ]]; then
    budget=$REACH_DEADLINE_BUDGET_SECONDS
  fi
  local give_up=$((SECONDS + budget))

  # With an interface up, a failure can be a bad moment, so it is retried in the
  # loop below. With no interface there is nothing to retry through: measured on
  # 2026-08-24, these hosts are not reachable without the VPN at all, and asking
  # anyway spends a timeout proving what the absence of the interface said.
  if tunnel_exists || [[ -z "$PROXY_VPN_UNIT" ]]; then
    probe_hosts && return 0
  fi

  [[ -n "$PROXY_VPN_UNIT" ]] || return 1

  if [[ "$(systemctl show "$PROXY_VPN_UNIT" -p ActiveState --value 2>/dev/null)" \
    != active ]]; then
    # Not started at all on a run that cannot wait for it. nxBender needs most
    # of VPN_WAIT_SECONDS to negotiate, and a run that gives up sooner stops it
    # again on the way out — an explicit stop, which defeats the unit's own
    # Restart=always and leaves the VPN down for every run after it too.
    #
    # Measured the hard way on 2026-10-16: a --check with a short budget found
    # the VPN down, started it, timed out, and tidied it away. What that cost
    # was not the check, which was only a check, but the next hour.
    if ((give_up - SECONDS < VPN_WAIT_SECONDS)); then
      say "no host answered and there is no time left to bring $PROXY_VPN_UNIT up"
      return 1
    fi

    say "no host answered (${proxy_hosts[*]}), bringing up $PROXY_VPN_UNIT"
    systemctl reset-failed "$PROXY_VPN_UNIT" 2>/dev/null || true
    systemctl start "$PROXY_VPN_UNIT" 2>/dev/null ||
      die "could not start $PROXY_VPN_UNIT"
    vpn_started_here=true
    # The unit goes active before the tunnel exists, so what is waited on is the
    # interface, not the unit — and never past the budget.
    if ((give_up > SECONDS + VPN_WAIT_SECONDS)); then
      give_up=$((SECONDS + VPN_WAIT_SECONDS))
    fi
  fi
  # An already active unit used to end the attempt right here, on the grounds
  # that the VPN was not what was missing. True, and not the same as nothing
  # being missing: on 2026-08-21 the unit was up with no tunnel behind it yet
  # and this gave up in zero seconds. With a list it is worse — it would walk
  # away from a host that was answering.

  # A round is only begun when there is room to finish one, so the ceiling is
  # the budget rather than the budget plus a timeout.
  while ((SECONDS + SSH_CONNECT_TIMEOUT <= give_up)); do
    if tunnel_exists && probe_hosts; then
      return 0
    fi
    sleep "$PROBE_ROUND_GAP"
  done
  return 1
}

# Say something on the phone from out here, for the one case the program cannot
# report: it is about to run, or not, in a way the program does not know about.
warn_phone() {
  local url
  url="$(setting NOTIFY_URL)"
  [[ -n "$url" ]] || return 0
  curl --silent --show-error --max-time 15 \
    --header "Title: $1" \
    --header "Priority: 4" \
    --header "Tags: warning" \
    --data-binary "$2" \
    "$url" >/dev/null || true
}

ssh_pid=""
ssh_errors=""

cleanup() {
  reap_probes
  if [[ -n "$ssh_pid" ]]; then
    kill "$ssh_pid" 2>/dev/null || true
    # Checked, not assumed. A tunnel that outlives the run holds the port, and
    # the next run reads that as "someone else is using it" and refuses to start.
    for _ in 1 2 3 4 5 6; do
      kill -0 "$ssh_pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$ssh_pid" 2>/dev/null && kill -KILL "$ssh_pid" 2>/dev/null || true
  fi
  [[ -n "$ssh_errors" ]] && rm -f "$ssh_errors"
  if [[ "$vpn_started_here" == true ]]; then
    say "stopping $PROXY_VPN_UNIT, which was off before this run"
    systemctl stop "$PROXY_VPN_UNIT" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

# One run at a time.
#
# Runs overlap by design — a tap five minutes into the window, the reminder at
# six — and two of them at once fight over more than a port. On 2026-08-21 the
# first brought the VPN up and stopped it again on the way out, while the second
# saw the unit "active" with no tunnel yet, concluded the VPN was not what was
# missing, and gave up. Both failures were reported as urgent, both were noise,
# and one of them arrived four seconds before the punch it was worried about.
#
# So the second run queues instead. If it cannot get in it stands down quietly
# and exits zero: another run is doing the work, which is not a failure and must
# not be announced as one.
mkdir -p "$REPO/state"
exec 9>"$REPO/state/run.lock"
if ! flock --wait "$LOCK_WAIT_SECONDS" 9; then
  say "another run is still going after ${LOCK_WAIT_SECONDS}s, standing down"
  exit 0
fi

# Through a second name, because the message wants the base and the assignment
# would have overwritten it: `x="$(f)" || die "$x"` reports the empty string it
# just assigned, so the range read `in ..39` on the one day it mattered.
chosen_port="$(free_port)" ||
  die "no free loopback port in $PROXY_PORT..$((PROXY_PORT + PORT_RANGE - 1))"
PROXY_PORT="$chosen_port"

[[ "${1:-}" == "--check" ]] && checking=true

proxied=true
if ! ensure_reachable; then
  if [[ "$checking" == true ]]; then
    say "no host answered:"
    report_probe
    case "$PROXY_FALLBACK" in
    direct) say "a run right now would go out from this machine" ;;
    *) say "a run right now would refuse to punch" ;;
    esac
    exit 1
  fi

  case "$PROXY_FALLBACK" in
  direct)
    # Losing the address is a nuisance; losing the punch is a correction e-mail.
    say "no host answered (${proxy_hosts[*]}), going out from this machine"
    if can_punch; then
      warn_phone "Sem túnel da FAI" \
        "Nenhum host respondeu (${proxy_hosts[*]}), então este ponto vai sair pelo IP daqui. O ponto acontece; só o endereço fica diferente."
    fi
    proxied=false
    ;;
  *)
    die "no host answered (${proxy_hosts[*]}), so there is no university address to punch from"
    ;;
  esac
fi

# Without a tunnel there is nothing left to set up, so the run happens here.
# `--check` never reaches this: it has already reported and exited above.
if [[ "$proxied" == false ]]; then
  [[ -x "$BINARY" ]] ||
    die "no runnable binary at $BINARY; run nix build --out-link state/current"
  "$BINARY" "$@"
  exit $?
fi

# ExitOnForwardFailure so ssh gives up rather than sitting there with nothing
# listening, which would leave a proxy that accepts no connections.
#
# Its output goes to a file rather than to this script's: a background process
# holding the inherited stdout keeps the pipe open after the script is gone, so
# anything reading from it — a `| tail`, a caller collecting output — waits on a
# tunnel nobody is using any more.
ssh_errors="$(mktemp)"
env -u SSH_AUTH_SOCK ssh "${SSH_OPTS[@]}" -N -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -D "127.0.0.1:$PROXY_PORT" \
  "$proxy_host" >/dev/null 2>"$ssh_errors" &
ssh_pid=$!

# Whatever ssh had to say about why, since the reason is usually the whole
# answer: a rejected key and a portal that stopped answering look identical from
# out here.
report_ssh() {
  [[ -s "$ssh_errors" ]] && sed "s/^/with-fai-proxy: ssh: /" "$ssh_errors" >&2
  return 0
}

for _ in $(seq 1 40); do
  port_open && break
  if ! kill -0 "$ssh_pid" 2>/dev/null; then
    report_ssh
    die "the ssh tunnel died before it listened"
  fi
  sleep 0.5
done

if ! port_open; then
  report_ssh
  die "the ssh tunnel never started listening on 127.0.0.1:$PROXY_PORT"
fi

say "tunnelling through $proxy_host via socks5://127.0.0.1:$PROXY_PORT"

if [[ "${1:-}" == "--check" ]]; then
  # Only for a human at a terminal, and the one place an outside service is
  # asked what the address looks like — a run never needs to.
  say "the address a request leaves from:"
  curl --silent --show-error --max-time 20 \
    --socks5-hostname "127.0.0.1:$PROXY_PORT" https://ifconfig.me || true
  echo
  exit 0
fi

[[ -x "$BINARY" ]] ||
  die "no runnable binary at $BINARY; run nix build --out-link state/current"

# No `exec`: the trap has to survive the run to take the tunnel back down.
PROXY_SERVER="socks5://127.0.0.1:$PROXY_PORT" "$BINARY" "$@"
