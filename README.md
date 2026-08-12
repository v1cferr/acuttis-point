# acuttis-point

Personal automation that registers timekeeping punches on
[Acuttis](https://app.acuttis.com.br/dashboard) through a headless browser,
so the same manual flow does not have to be repeated every working day.

Tracked in [V1C-73](https://v1cferr.atlassian.net/browse/V1C-73).

## Status

The whole pipeline is in place and runs end to end: configuration, the
decision rules, the Playwright adapter, the run record, and a NixOS service
and timer. One thing is still missing before it can register a punch —
`PUNCH_LIST_SELECTOR`, see [Finding the punch selectors](#finding-the-punch-selectors).

What has actually been exercised against the live site: reaching
`/dashboard` and being redirected to `/signin`, filling and submitting the
sign-in form, and recognising a rejected sign-in. Everything behind the
login is written but unverified, as is the systemd side.

## Design

The domain logic lives in Gleam and stays pure: configuration, the current
time and the punches already registered are folded into an explicit state,
and a single decision function says what — if anything — should happen.

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

Playwright has no official Gleam SDK, so Gleam compiles to JavaScript and
talks to `playwright-core` through a deliberately thin FFI layer.

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

The automation is built to do nothing rather than something wrong.

- **Weekdays only, at configured times.** A punch is registered only inside
  the tolerance window that follows its scheduled time.
- **No backdating.** Once the window has closed the run aborts rather than
  register a time that no longer reflects reality.
- **No duplicates.** Idempotency is not a special case: once a punch is on
  record the day waits for the next one, which is not due yet, so a second
  run in the same window can only skip.
- **Abort on anything odd.** A day that is not a valid prefix of
  entry → lunch start → lunch end → exit, with non-decreasing times, is
  refused and left for a human.
- **Confirmed, not assumed.** After registering, the punches are read again
  and the new one has to be there. A click that appeared to work but did not
  land is a failure, not a success.
- **Secrets stay out.** Credentials live in an opaque type whose rendering is
  a masked username and `<redacted>`; the clear password is only reachable
  through `reveal_password`, which the sign-in form is the only caller of.

A refusal exits 2 and a failure exits 1, so both show the systemd unit red —
those are exactly the runs that want attention.

## Development

The Nix dev shell brings Gleam, Node, and `playwright-core` with its matching
browsers:

```sh
nix develop
gleam test
gleam run
```

## Configuration

Everything is read from the environment — see [`.env.example`](.env.example)
for the full list with defaults. Nothing about the schedule is hardcoded, and
a schedule that does not run forward through the day is rejected at startup.

`TIME_TOLERANCE_MINUTES` is the one worth understanding: it is how long after
a scheduled time a punch may still be registered. It is also what makes a
catch-up run safe after the machine was asleep — a run that wakes up too late
refuses to punch instead of inventing a time.

Credentials never live in this repository. Locally they come from a `.env`
that git ignores; in production systemd reads them from a secret store
(sops-nix, agenix, Bitwarden) as an `EnvironmentFile`.

### Finding the punch selectors

Acuttis renders its interface in the browser, so the automation has to be told
where to click. The sign-in selectors were read from the live sign-in page and
carry working defaults.

`PUNCH_LIST_SELECTOR` has no default and is required. It has to match one
element per punch already registered today, in the order Acuttis lists them.
Reading the wrong elements is how a punch ends up registered against the wrong
event, so the automation refuses to start without it rather than guess.

To find it, run once with the browser visible and nothing at stake:

```sh
HEADLESS=false DRY_RUN=true gleam run
```

then inspect the punch interface while it is open. The remaining punch
selectors default to what the public punch modal on the sign-in page uses;
whether the signed-in interface is the same component is not yet verified, so
override them if a run reports it could not find one.

## Observability

Each run writes a one-line record to stdout — the journal, under systemd — and,
when `LOG_FILE` is set, the block form from the ticket:

```
2026-08-12 07:55
Action: ENTRY
Expected: ENTRY
Current state: WAITING(ENTRY)
Result: SUCCESS
Acuttis confirmation: 07:55
```

Every reason other than an outright failure is taken from the decision itself,
so the log cannot disagree with the rule that produced it.

## Deploying on NixOS

The flake exposes a package and a module. The schedule is declared once: the
service reads it as environment variables and the timer turns the same times
into `OnCalendar` entries, so the two cannot drift apart.

```nix
{
  imports = [ inputs.acuttis-point.nixosModules.default ];

  services.acuttis-point = {
    enable = true;
    schedule = {
      entry = "08:00";
      lunchStart = "12:00";
      lunchEnd = "14:00";
      exit = "17:30";
    };
    punchListSelector = ".punch-row";
    environmentFile = config.sops.secrets.acuttis-point.path;
  };
}
```

The `environmentFile` holds `ACUTTIS_USERNAME` and `ACUTTIS_PASSWORD`. An
assertion refuses a path inside the Nix store, since everything there is
world readable.

## Layout

```
src/     Gleam domain logic and the Playwright adapter
test/    unit tests for the pure core and the run orchestration
nix/     package derivation, systemd service and timer
```

The modules, roughly outermost first:

| Module | What it holds |
|---|---|
| `acuttis_point` | wiring: environment in, run record out |
| `runner` | the order of a run, and what each failure means |
| `decision` | the one rule that decides whether to punch |
| `state` | the day derived from the punches Acuttis shows |
| `config`, `credentials`, `selectors` | configuration, with credentials kept apart |
| `clock`, `punch` | validated time, and the four punches of a day |
| `report` | what a run leaves behind |
| `browser` | the port every effect goes through |
| `playwright`, `acuttis`, `system` | the adapters, and the only impure code |
