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

# The ssh destination. A Host block in ~/.ssh/config, or user@address.
PROXY_SSH_HOST="${PROXY_SSH_HOST:-workstation}"
# Where to start looking for a free loopback port. Loopback only: a SOCKS proxy
# on a reachable address is an open relay.
PROXY_PORT="${PROXY_PORT:-11080}"
# The VPN unit the host may only be reachable through. Empty never touches it.
PROXY_VPN_UNIT="${PROXY_VPN_UNIT:-vpn-fai.service}"

# How many ports to consider before giving up.
readonly PORT_RANGE=40

# How long to wait for another run to finish. A run takes about forty seconds
# with the VPN to bring up, so this is room for a couple of them queued.
readonly LOCK_WAIT_SECONDS=180

# How many times to try the host before reaching for the VPN. The host is
# normally reachable without it; on 2026-08-24 a single transient ssh failure at
# 07:36 sent the run down the VPN path, pppd died with code 16, and the run spent
# eleven minutes failing. A retry costs seconds and would have cost none of that.
readonly SSH_ATTEMPTS=3

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
PROXY_FALLBACK="${PROXY_FALLBACK:-direct}"

readonly BINARY="${ACUTTIS_BINARY:-$REPO/state/current/bin/acuttis-point}"

die() {
  echo "with-fai-proxy: $*" >&2
  exit 1
}

say() {
  echo "with-fai-proxy: $*"
}

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
readonly SSH_OPTS=(
  -o BatchMode=yes
  -o ControlPath=none
  -o ConnectTimeout=10
)

ssh_quiet() {
  env -u SSH_AUTH_SOCK ssh "${SSH_OPTS[@]}" "$@"
}

vpn_started_here=false

# Only if the host cannot be reached as things stand. The tunnel host lives on a
# university address that this machine may only have a route to through the VPN,
# and turning that on is a change to the whole system — so it happens only when
# it is the difference between a punch and no punch, and it is undone after.
reachable() {
  ssh_quiet -o ConnectTimeout=7 -o ConnectionAttempts=1 "$PROXY_SSH_HOST" true \
    2>/dev/null
}

ensure_reachable() {
  # Retried before escalating: the host is normally reachable without the VPN,
  # and one bad moment should not turn into a VPN dialling sequence.
  for attempt in $(seq 1 "$SSH_ATTEMPTS"); do
    reachable && return 0
    ((attempt < SSH_ATTEMPTS)) && sleep 3
  done

  [[ -n "$PROXY_VPN_UNIT" ]] || return 1

  case "$(systemctl show "$PROXY_VPN_UNIT" -p ActiveState --value 2>/dev/null)" in
  active) return 1 ;; # already up, so the VPN is not what is missing
  esac

  say "$PROXY_SSH_HOST is unreachable, bringing up $PROXY_VPN_UNIT"
  systemctl reset-failed "$PROXY_VPN_UNIT" 2>/dev/null || true
  systemctl start "$PROXY_VPN_UNIT" 2>/dev/null ||
    die "could not start $PROXY_VPN_UNIT"
  vpn_started_here=true

  # The unit goes active before the tunnel exists, so what is waited on is the
  # interface, not the unit. Bounded by the clock rather than by a round count,
  # because what matters is how much of the punch window is left.
  local deadline=$((SECONDS + VPN_WAIT_SECONDS))
  while ((SECONDS < deadline)); do
    if [[ -n "$(ip -o link show type ppp 2>/dev/null)" ]] && reachable; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# Say something on the phone from out here, for the one case the program cannot
# report: it is about to run, or not, in a way the program does not know about.
warn_phone() {
  # The environment wins over the file, the same way it does for the program, so
  # a test run can be silenced with NOTIFY_URL= rather than by editing anything.
  local url="${NOTIFY_URL-}"
  if [[ -z "${NOTIFY_URL+set}" ]]; then
    url="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?NOTIFY_URL[[:space:]]*=[[:space:]]*//p" \
      "${ENV_FILE:-$REPO/.env}" 2>/dev/null | tail -1)"
  fi
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

PROXY_PORT="$(free_port)" ||
  die "no free loopback port in $PROXY_PORT..$((PROXY_PORT + PORT_RANGE - 1))"

proxied=true
if ! ensure_reachable; then
  case "$PROXY_FALLBACK" in
  direct)
    # Losing the address is a nuisance; losing the punch is a correction e-mail.
    say "no tunnel to $PROXY_SSH_HOST, going out from this machine instead"
    warn_phone "Sem túnel da FAI" \
      "Não consegui alcançar $PROXY_SSH_HOST, então o ponto vai sair pelo IP daqui. O ponto acontece; só o endereço fica diferente."
    proxied=false
    ;;
  *)
    die "cannot reach $PROXY_SSH_HOST, so there is no university address to punch from"
    ;;
  esac
fi

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
  "$PROXY_SSH_HOST" >/dev/null 2>"$ssh_errors" &
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

say "tunnelling through $PROXY_SSH_HOST via socks5://127.0.0.1:$PROXY_PORT"

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
