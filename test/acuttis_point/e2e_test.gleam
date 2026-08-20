//// End to end, through the real Playwright adapter.
////
//// These launch Chromium and drive a local fixture shaped like the Acuttis
//// interface as it was read on 2026-08-12: a client-rendered page that rewrites
//// its path to /signin, a submit button that starts disabled, an anchor that
//// opens the punch modal, and a receipt inside that modal listing several days
//// newest first.
////
//// They deliberately use the real defaults from `selectors`, so a change to
//// one of those breaks a test here rather than a run in production.
////
//// What they do not verify is Acuttis itself: the punch path in particular is
//// still unconfirmed against the real site, because confirming it means
//// registering a real punch.

import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/decision
import acuttis_point/discovery
import acuttis_point/playwright
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/runner
import acuttis_point/selectors
import acuttis_point/state
import gleam/dict
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import support/files
import support/fixture

const workday = "2026-08-12"

/// Rows exactly as the receipt prints them.
const yesterday = [
  "11/08/2026 Ter - 17:37",
  "11/08/2026 Ter - 13:02",
]

fn env(base_url: String, overrides: List(#(String, String))) {
  [
    #("ACUTTIS_URL", base_url),
    #("ACUTTIS_USERNAME", fixture.username),
    #("ACUTTIS_PASSWORD", fixture.password),
    #("ENTRY_TIME", "08:00"),
    #("LUNCH_START", "12:00"),
    #("LUNCH_END", "14:00"),
    #("EXIT_TIME", "17:30"),
    #("TIME_TOLERANCE_MINUTES", "10"),
    // Every selector left at its default, so this exercises what production
  // would actually use.
  ]
  |> list.append(overrides)
  |> dict.from_list
}

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date(workday)
  clock.Instant(date: date, time: at(time))
}

fn today_at(time: String) -> String {
  "12/08/2026 Qua - " <> time
}

/// A `Report` has two shapes, so only `at` is reachable as a field.
fn decided(
  record: report.Report,
) -> #(state.DayState, decision.Decision, report.RunOutcome) {
  let assert report.Decided(state: day, decision: chosen, outcome:, ..) = record
  #(day, chosen, outcome)
}

/// Run against a freshly started fixture, and always stop it afterwards.
fn against(
  registered: List(String),
  lands_at: String,
  overrides: List(#(String, String)),
  now: String,
) -> Promise(report.Report) {
  use base_url <- promise.await(fixture.start(
    registered: list.append(yesterday, registered),
    lands_at: today_at(lands_at),
  ))

  let settings_env = env(base_url, overrides)
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  use finished <- promise.await(runner.run(
    settings: settings,
    secrets: secrets,
    now: moment(now),
    port: playwright.port(settings, selectors.from_env(settings_env)),
  ))

  use _ <- promise.await(fixture.stop())
  promise.resolve(finished.report)
}

pub fn a_due_punch_is_registered_through_a_real_browser_test() {
  use record <- promise.await(against([], "08:03", [], "08:03"))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      registered: [state.Registered(punch: punch.Entry, at: at("08:03"))],
      outcome: report.Confirmed(at: at("08:03")),
    )
  assert fixture.punches() == list.append(yesterday, [today_at("08:03")])
  promise.resolve(Nil)
}

// The receipt lists other days, and they must not become today's punches.
pub fn earlier_days_on_the_receipt_are_ignored_test() {
  use record <- promise.await(against([today_at("07:58")], "12:04", [], "12:04"))

  assert record
    == report.Decided(
      at: moment("12:04"),
      state: state.Waiting(punch.LunchStart),
      // Só a linha de hoje; as de ontem ficaram de fora.
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:00"),
      ),
      registered: [
        state.Registered(punch: punch.Entry, at: at("07:58")),
        state.Registered(punch: punch.LunchStart, at: at("12:04")),
      ],
      outcome: report.Confirmed(at: at("12:04")),
    )
  promise.resolve(Nil)
}

pub fn a_second_run_in_the_same_window_registers_nothing_test() {
  use record <- promise.await(against([today_at("08:03")], "08:07", [], "08:07"))

  let #(_, chosen, outcome) = decided(record)
  assert outcome == report.NothingToDo
  assert chosen
    == decision.Skip(decision.AlreadyRegistered(
      punch: punch.Entry,
      at: at("08:03"),
    ))
  assert fixture.punches() == list.append(yesterday, [today_at("08:03")])
  promise.resolve(Nil)
}

pub fn a_dry_run_signs_in_reads_and_leaves_no_punch_test() {
  use record <- promise.await(against(
    [],
    "08:03",
    [#("DRY_RUN", "true")],
    "08:03",
  ))

  let #(_, chosen, outcome) = decided(record)
  assert outcome == report.Withheld
  assert chosen
    == decision.Register(punch: punch.Entry, expected_at: at("08:00"))
  assert fixture.punches() == yesterday
  promise.resolve(Nil)
}

pub fn wrong_credentials_break_at_authentication_test() {
  use record <- promise.await(against(
    [],
    "08:03",
    [#("ACUTTIS_PASSWORD", "wrong")],
    "08:03",
  ))

  assert record
    == report.Broke(
      at: moment("08:03"),
      stage: report.Authenticating,
      detail: "acuttis rejected the sign in: still on the sign-in page after submitting",
    )
  assert report.exit_code(record) == 1
  promise.resolve(Nil)
}

pub fn nothing_listening_is_reported_as_unreachable_test() {
  use record <- promise.await(against(
    [],
    "08:03",
    [#("ACUTTIS_URL", fixture.unreachable())],
    "08:03",
  ))

  let assert report.Broke(stage:, detail:, ..) = record
  assert stage == report.Authenticating
  assert string.contains(detail, "acuttis could not be reached")
  promise.resolve(Nil)
}

// The safety property the multi-day receipt buys: a selector that stopped
// matching is caught outright, rather than passing for a day that never
// started and inviting a punch in the entry window.
pub fn a_selector_matching_nothing_is_caught_not_read_as_empty_test() {
  use record <- promise.await(against(
    [today_at("07:58")],
    "12:04",
    [#("PUNCH_LIST_SELECTOR", ".this-matches-nothing")],
    "12:04",
  ))

  assert record
    == report.Broke(
      at: moment("12:04"),
      stage: report.ReadingPunches,
      detail: "could not find any row on the punch receipt; the acuttis interface may have changed",
    )
  assert fixture.punches() == list.append(yesterday, [today_at("07:58")])
  promise.resolve(Nil)
}

// And a day that genuinely has not started is still refused once its window
// has closed, rather than punched late.
pub fn a_day_that_never_started_is_refused_after_its_window_test() {
  use record <- promise.await(against([], "12:04", [], "12:04"))

  let #(day, chosen, outcome) = decided(record)
  assert day == state.Waiting(punch.Entry)
  assert chosen
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 244,
    ))
  assert outcome == report.Refused
  assert fixture.punches() == yesterday
  promise.resolve(Nil)
}

// The receipt is capped at twenty rows, so a new punch pushes the oldest one
// out and the row count never grows. An earlier version waited for the count to
// grow and reported a punch that had in fact landed as a failure.
pub fn a_punch_is_confirmed_even_though_the_receipt_is_full_test() {
  // Nineteen rows on earlier days, so today's punch makes the twentieth and the
  // one after it evicts a row instead of adding one.
  let filler =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
    |> list.map(fn(day) {
      let padded = case day < 10 {
        True -> "0" <> int.to_string(day)
        False -> int.to_string(day)
      }
      padded <> "/07/2026 Qua - 08:00"
    })

  use base_url <- promise.await(fixture.start(
    registered: list.append(filler, [today_at("07:58")]),
    lands_at: today_at("12:04"),
  ))

  let settings_env = env(base_url, [])
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  use finished <- promise.await(runner.run(
    settings: settings,
    secrets: secrets,
    now: moment("12:04"),
    port: playwright.port(settings, selectors.from_env(settings_env)),
  ))
  use _ <- promise.await(fixture.stop())

  let #(_, chosen, outcome) = decided(finished.report)
  assert chosen
    == decision.Register(punch: punch.LunchStart, expected_at: at("12:00"))
  assert outcome == report.Confirmed(at: at("12:04"))
  promise.resolve(Nil)
}

// 2026-08-19: Acuttis added a second anchor sharing the punch trigger's class,
// the click went to the wrong one, and the modal never opened. What matters is
// which of two stories the run tells about that. "The interface changed" sends
// someone to look at it. "Today has no punches" would be a lie that reads as
// truth, and on a day with three punches already registered it would invite the
// automation to register a fourth.
// The proof. A punch nobody can show is a punch to argue about, so a confirmed
// run photographs the receipt it just read the new row from — the same page
// Gestão de Pessoas would look at, at the moment the row appeared.
pub fn a_registered_punch_leaves_a_photograph_of_the_receipt_test() {
  let shots = "build/e2e-shots"
  files.remove(shots)

  use base_url <- promise.await(fixture.start(
    registered: list.append(yesterday, [today_at("07:58")]),
    lands_at: today_at("12:04"),
  ))

  let settings_env = env(base_url, [#("SCREENSHOT_DIR", shots)])
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  use finished <- promise.await(runner.run(
    settings: settings,
    secrets: secrets,
    now: moment("12:04"),
    port: playwright.port(settings, selectors.from_env(settings_env)),
  ))
  use _ <- promise.await(fixture.stop())

  let #(_, _, outcome) = decided(finished.report)
  assert outcome == report.Confirmed(at: at("12:04"))

  // Named for what it proves, and not empty.
  let assert Ok(path) = finished.screenshot
  assert string.contains(path, "registered-lunch-start")
  assert files.has_content(path)
  promise.resolve(Nil)
}

pub fn a_trigger_that_opens_nothing_is_an_interface_problem_test() {
  use base_url <- promise.await(fixture.start(
    registered: list.append(yesterday, [today_at("07:58")]),
    lands_at: today_at("12:04"),
  ))

  let settings_env = env(base_url, [])
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  // The trigger stays visible and stops opening anything.
  fixture.break_punch_modal()

  use blocked <- promise.await(runner.run(
    settings: settings,
    secrets: secrets,
    now: moment("12:04"),
    port: playwright.port(settings, selectors.from_env(settings_env)),
  ))
  use _ <- promise.await(fixture.stop())

  let assert report.Broke(stage: stage, detail: detail, ..) = blocked.report
  assert stage == report.ReadingPunches
  assert string.contains(detail, "#mark_modal")

  // And nothing was registered while the interface was misbehaving.
  assert fixture.punches() == list.append(yesterday, [today_at("07:58")])
  promise.resolve(Nil)
}

pub fn discovery_finds_the_punch_list_selector_test() {
  use base_url <- promise.await(fixture.start(
    registered: list.append(yesterday, [today_at("07:58")]),
    lands_at: today_at("14:02"),
  ))

  let settings_env = env(base_url, [])
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  use found <- promise.await(discovery.discover(
    secrets: secrets,
    now: moment("14:00"),
    port: playwright.port(settings, selectors.from_env(settings_env)),
  ))
  use _ <- promise.await(fixture.stop())

  let text = discovery.to_text(found)
  assert string.contains(text, "nothing was clicked")
  // The tooltip, not the class: the fixture carries the second anchor Acuttis
  // added on 2026-08-19, so a selector matching both would be caught here.
  assert string.contains(
    text,
    "PUNCH_TRIGGER_SELECTOR \"a.size-item-navbar[data-tooltip=\"Marcar Ponto\"]\" matches 1",
  )

  // Discovery cannot reach the punch rows, and this pins that down rather than
  // pretending otherwise: Acuttis renders them only once the receipt is opened,
  // and opening it is a click. Discovery still confirms the way in — the
  // trigger and the modal — which is what it is for now that the list selector
  // has a default.
  assert !string.contains(text, "styles_containerMarkingAddress")

  assert fixture.punches() == list.append(yesterday, [today_at("07:58")])
  promise.resolve(Nil)
}
