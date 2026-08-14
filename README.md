# acuttis-point

Personal automation that registers timekeeping punches on
[Acuttis](https://app.acuttis.com.br/dashboard) through a headless browser,
so the same manual flow does not have to be repeated every working day.

Tracked in [V1C-73](https://v1cferr.atlassian.net/browse/V1C-73).

## Status

The whole pipeline is in place and runs end to end: configuration, the
decision rules, the Playwright adapter, the run record, and a NixOS service
and timer.

Verified against the live site: reaching `/dashboard` and being redirected to
`/signin`, filling and submitting the sign-in form, and recognising a rejected
sign-in.

Verified against the live site, signed in: opening the punch modal, switching
to the receipt, reading the day's punches and deciding on them. The one step
still unconfirmed against Acuttis is the punch itself, because confirming it
means registering a real punch.

Verified against a local fixture shaped like that interface: registering a
punch, reading it back, and every failure path in between. The systemd side
remains unrun.

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

`gleam test` runs everything, including the end-to-end tests that launch
Chromium against a local fixture — around 35 seconds in total. Those live in
`test/acuttis_point/e2e_test.gleam` and the fixture in `test/support/`.

## Configuration

Everything is read from the environment, with a `.env` file underneath it.
Real environment variables always win over the file, so a `.env` forgotten in
a working directory cannot override what systemd injected, and each run says
which file it picked up. `ENV_FILE` overrides the path.

See [`.env.example`](.env.example) for the full list with defaults. Nothing
about the schedule is hardcoded, and a schedule that does not run forward
through the day is rejected at startup.

`TIME_TOLERANCE_MINUTES` is the one worth understanding: it is how long after
a scheduled time a punch may still be registered. It is also what makes a
catch-up run safe after the machine was asleep — a run that wakes up too late
refuses to punch instead of inventing a time.

### Spreading the punches, in one direction

A timer can spread each punch over a jitter window so the day is not registered
to the same minute twice. systemd can only ever delay a run, never bring it
forward, and that is what decides how the schedule has to be written:

```
ENTRY_TIME and LUNCH_END   =  the time you want, minus the jitter
LUNCH_START and EXIT_TIME  =  the time you want
```

Entry and the return from lunch then land at or before their wanted times,
while lunch start and exit land at or after theirs. Every one of those
directions lengthens the worked day, so it comes out at or above nominal and
never under it — with nine minutes of jitter, somewhere between nominal and
nominal plus 36 minutes.

The jitter has to stay within `TIME_TOLERANCE_MINUTES`, or a delayed run would
arrive after its own window had closed and refuse to register anything. The
NixOS module asserts this; `scripts/schedule.sh` uses nine minutes against a
default tolerance of ten.

### Scheduling without NixOS

`scripts/schedule.sh` installs a user systemd timer from the current `.env`,
which is enough to try the automation out before committing it to the system
configuration:

```sh
./scripts/schedule.sh entry --on 2026-08-14   # one punch, one day
./scripts/schedule.sh all                     # every punch, every work day
./scripts/schedule.sh --status                # what is scheduled now
./scripts/schedule.sh --remove                # stop and forget it
```

Nothing reschedules itself: systemd is told the times up front, so the script
has to be re-run after `.env` changes. It prints the next elapse, so the result
is visible rather than assumed.

Credentials never live in this repository. Locally they come from a `.env`
that git ignores; in production systemd reads them from a secret store
(sops-nix, agenix, Bitwarden) as an `EnvironmentFile`.

### Finding the punch selectors

Acuttis renders its interface in the browser, so the automation has to be told
where to click. Every selector has a default read from the live application, so
none of them normally needs setting. Reaching the punches takes two steps: an anchor opens
the punch modal, and a button inside it switches to the receipt, which is the
only place they are listed.

The receipt shows several days at once, newest first, one row per punch:

```
13/08/2026 Qui - 17:36
13/08/2026 Qui - 14:06
...
12/08/2026 Qua - 18:08
```

Today's rows are picked out by date and the times sorted, so the order the page
happens to use is not a contract. That the receipt spans days also buys a real
safety property: a selector that has silently stopped matching produces no rows
at all, while a day that has simply not started still produces the previous
days' rows. The two are distinguishable, and only the second is a day worth
acting on — which matters most in the entry window, the one moment where an
empty day and a broken selector would otherwise both say *punch*.

`PUNCH_LIST_SELECTOR` is the fragile one: its class is generated by CSS
modules and will not survive an Acuttis frontend rebuild. To find the
replacement:

```sh
DISCOVER=true gleam run
```

Discovery signs in, lists every candidate selector holding an `HH:MM` time with
how many elements each matches, and **clicks nothing at all**. It cannot
register a punch, so it is safe to run against a real account at any time of
day. A test asserts the port only ever sees `open`, `sign_in`, `describe`,
`close`. Add `HEADLESS=false` to watch it.

Its one limit is worth knowing: Acuttis renders the punch rows only once the
receipt is open, and opening it is a click. So discovery confirms the way in —
the trigger and the modal — but the row selector itself was read by hand, once.

To check a real run without registering anything:

```sh
DRY_RUN=true gleam run
```

That signs in, opens the receipt, reads the day and decides — then stops.

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

### Push notifications

Setting `NOTIFY_URL` makes each run POST a notification. It is shaped for
[ntfy](https://ntfy.sh) — title, priority and tags as headers, the record as the
body — so any endpoint taking a POST works.

| Result | Priority | Message |
|---|---|---|
| Registered | default | `ENTRY at 07:57` |
| Refused, failed | high | the reason, same text as the log |
| Nothing to do | low, silent | the reason |

`NOTIFY_ON` decides which runs are worth a buzz: `always`, `action` (the
default — silent when there was nothing to do) or `problem`.

A configuration error notifies too, and that is deliberate: it means no punch
happened at all, which is exactly when a message earns its keep. Failing to
notify never changes a run's outcome — the punch has already happened or not,
and a message that did not arrive does not change which.

On ntfy the topic name is the only thing protecting a topic, so use a random
one. The message names the punch and its time, so it does reach ntfy's servers
in the clear; self-host if that matters.

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
| `discovery` | signs in, describes the page, clicks nothing |
| `browser` | the port every effect goes through |
| `playwright`, `acuttis`, `system` | the adapters, and the only impure code |
