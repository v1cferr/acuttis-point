#!/usr/bin/env bash
#
# Listen for the tap. Long running: this is the half of the remote control that
# lives on this machine.
#
# The notification carries a button; tapping it publishes "punch <token>" to the
# command topic. This subscribes to that topic and hands the token to the
# program, which spends it and punches. Nothing inbound is opened here — the
# connection is outbound and stays open, so there is no port, no certificate and
# no endpoint of ours on the internet.
#
# It does not decide anything. Whether a token is valid, unexpired and unspent is
# the program's business, and so is whether the punch is due at all. This only
# carries the message.
#
# A replayed command is safe for the same reason: ntfy streams from the moment of
# connection rather than from history, and a token that did arrive twice would be
# refused the second time. The worst a restart can do is miss a tap, which the
# deadline run covers.

set -euo pipefail

readonly REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ENV_FILE="${ENV_FILE:-$REPO/.env}"

die() {
  echo "listen: $*" >&2
  exit 1
}

# Reads a key from .env without sourcing it: a .env is not a shell script, and a
# stray backtick in a password should not become a command.
env_value() {
  sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$1[[:space:]]*=[[:space:]]*//p" \
    "$ENV_FILE" 2>/dev/null |
    tail -1 |
    sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' |
    tr -d '\r'
}

command_url="${COMMAND_URL:-$(env_value COMMAND_URL)}"
[[ -n "$command_url" ]] ||
  die "no COMMAND_URL: without a topic to listen on there is nothing to listen for"

# The punch runner. The wrapper when one is configured, so a tapped punch leaves
# from the same address a scheduled one would.
runner="$REPO/state/current/bin/acuttis-point"
if [[ -n "$(env_value PROXY_SSH_HOST)" ]]; then
  runner="$REPO/scripts/with-fai-proxy.sh"
fi
[[ -x "$runner" ]] || die "$runner is not executable"

echo "listen: waiting for a tap on ${command_url##*/}"

# --no-buffer so a message is acted on when it arrives rather than when the
# buffer fills. The stream stays open; systemd restarts this if it drops.
curl --silent --no-buffer --show-error "$command_url/json" |
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    event="$(jq -r '.event // ""' <<<"$line" 2>/dev/null || echo "")"
    [[ "$event" == "message" ]] || continue

    message="$(jq -r '.message // ""' <<<"$line" 2>/dev/null || echo "")"

    # One shape only, and the token pattern is the one `pending` mints. Anything
    # else on this topic is noise, and noise must not reach a browser.
    if [[ ! "$message" =~ ^punch[[:space:]]+([a-z0-9]{6,64})$ ]]; then
      echo "listen: ignoring a message that is not a punch command"
      continue
    fi

    token="${BASH_REMATCH[1]}"

    # Which way to run it, not whether to. The program is still the only thing
    # that decides whether a token is valid, unexpired and unspent — this only
    # decides whether the trip through the tunnel is worth paying for.
    #
    # A token that matches nothing can only be declined, and declining reads a
    # local file and sends a notification: no Acuttis, no browser, no tunnel. So
    # it runs the binary directly. That keeps a stale tap instant, and keeps a
    # stranger who guessed the topic from making a VPN come up and down by
    # posting noise.
    #
    # It still runs, though. A tap that does nothing and says nothing is how
    # somebody ends up at the totem in the building making a second marking, so
    # every tap gets an answer.
    pending_file="$(env_value PENDING_FILE)"
    pending_file="$REPO/${pending_file:-state/pending.json}"
    if grep -qxF "token=$token" "$pending_file" 2>/dev/null; then
      echo "listen: a tap arrived, spending its token"
      how="$runner"
    else
      echo "listen: nothing is waiting for that token, answering without a tunnel"
      how="$REPO/state/current/bin/acuttis-point"
    fi

    # Never fatal: a punch that fails has already said so, on the phone and in
    # the journal, and this process has to survive to hear the next tap.
    CLAIM_TOKEN="$token" ACUTTIS_BINARY="$REPO/state/current/bin/acuttis-point" \
      "$how" || echo "listen: that punch did not go through"
  done

# Reached only when the stream closes, which is a restart rather than an end.
die "the connection to $command_url closed"
