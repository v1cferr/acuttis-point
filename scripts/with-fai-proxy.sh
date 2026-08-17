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
# Loopback only: a SOCKS proxy on a reachable address is an open relay.
PROXY_PORT="${PROXY_PORT:-11080}"
# The VPN unit the host may only be reachable through. Empty never touches it.
PROXY_VPN_UNIT="${PROXY_VPN_UNIT:-vpn-fai.service}"

readonly BINARY="${ACUTTIS_BINARY:-$REPO/state/current/bin/acuttis-point}"

die() {
  echo "with-fai-proxy: $*" >&2
  exit 1
}

say() {
  echo "with-fai-proxy: $*"
}

port_open() {
  # /dev/tcp rather than nc: this machine's `nc -z` exits silently whatever it
  # finds, which has already been mistaken for a working tunnel once.
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PROXY_PORT" 2>/dev/null
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
ensure_reachable() {
  ssh_quiet -o ConnectTimeout=7 "$PROXY_SSH_HOST" true 2>/dev/null && return 0
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
  # interface, not the unit.
  for _ in $(seq 1 30); do
    if [[ -n "$(ip -o link show type ppp 2>/dev/null)" ]] &&
      ssh_quiet -o ConnectTimeout=5 "$PROXY_SSH_HOST" true 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
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

! port_open ||
  die "127.0.0.1:$PROXY_PORT is already taken; set PROXY_PORT to something else"

ensure_reachable ||
  die "cannot reach $PROXY_SSH_HOST, so there is no university address to punch from"

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
