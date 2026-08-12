# acuttis-point

Personal automation that registers timekeeping punches on
[Acuttis](https://app.acuttis.com.br/dashboard) through a headless browser,
so the same manual flow does not have to be repeated every working day.

Tracked in [V1C-73](https://v1cferr.atlassian.net/browse/V1C-73).

> **Status:** early scaffolding. Nothing is wired to the real Acuttis UI yet.

## Design

The domain logic lives in Gleam and stays pure: configuration, current time and
the punches already registered are folded into an explicit state, and a single
decision function says what — if anything — should happen.

```
Configuration
    ↓
Current time
    ↓
Existing punches
    ↓
Current state
    ↓
Decision rule
    ↓
Required action
    ↓
External effect via browser
```

Playwright has no official Gleam SDK, so Gleam compiles to JavaScript and talks
to the official `playwright` npm package through a deliberately thin FFI layer.

```
Gleam                     JavaScript FFI        Chromium
├── configuration              │                headless
├── rules                      │                    │
├── states          ──────────▶│──────────────▶ Playwright ──▶ Acuttis
├── decisions
└── error handling
```

If that interop turns out to hurt reliability, `Python + Playwright` is the
fallback — it has an official binding and is already a known RPA stack here.

## Safety rules

The automation is built to do nothing rather than something wrong:

- weekdays only, and only at configured times;
- never backdates a punch or invents a work period;
- aborts and asks for manual intervention whenever the observed state does not
  match the expected one;
- re-running never produces a second punch for the same event.

## Development

The repository ships a Nix dev shell with Gleam, Node and a pinned Playwright
plus its browsers:

```sh
nix develop
gleam test
```

## Layout

```
src/     Gleam domain logic and the Playwright adapter
test/    unit tests for the pure core
nix/     systemd service and timer for declarative deployment
config/  example configuration
```

## Configuration

Times, working days and tolerances are read from the environment — see
[`.env.example`](.env.example). Credentials never live in this repository; they
come from the host secret store (sops / NixOS secrets / Bitwarden) and are
never written to logs.
