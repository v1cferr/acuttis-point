//// End to end, through the real Playwright adapter.
////
//// These launch Chromium and drive a local fixture that imitates Acuttis. They
//// verify what the fake port cannot: that the selectors work, that the adapter
//// waits for a submit button that starts disabled, that the punch modal has to
//// be opened before its button can be clicked, and that a registered punch is
//// read back.
////
//// What they do not verify is Acuttis itself. They check the adapter against
//// this project's model of Acuttis, which is exactly as good as that model —
//// so when the real punch interface is known, the fixture should be brought
//// closer to it.

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
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string
import support/fixture

const workday = "2026-08-12"

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
    #("PUNCH_LIST_SELECTOR", "#punch_history .punch-row"),
    #("PUNCH_TRIGGER_SELECTOR", "button.modal-trigger"),
    #("PUNCH_MODAL_SELECTOR", "#mark_modal"),
    // Left at its default on purpose: `#mark_modal button:has-text("Ponto")`
  // is what a real deployment would use, so the test should prove it works.
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

/// A `Report` has two shapes, so only `at` is reachable as a field. Tests that
/// care about the decision pull the three parts out at once.
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
    registered: registered,
    lands_at: lands_at,
  ))

  let assert Ok(settings) = config.from_env(env(base_url, overrides))
  let assert Ok(secrets) = credentials.from_env(env(base_url, overrides))
  let assert Ok(page_selectors) = selectors.from_env(env(base_url, overrides))

  use record <- promise.await(runner.run(
    settings: settings,
    secrets: secrets,
    now: moment(now),
    port: playwright.port(settings, page_selectors),
  ))

  use _ <- promise.await(fixture.stop())
  promise.resolve(record)
}

pub fn a_due_punch_is_registered_through_a_real_browser_test() {
  use record <- promise.await(against([], "08:03", [], "08:03"))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Confirmed(at: at("08:03")),
    )
  promise.resolve(Nil)
}

pub fn an_existing_punch_is_read_back_and_the_day_advances_test() {
  use record <- promise.await(against(["07:58"], "12:04", [], "12:04"))

  assert record
    == report.Decided(
      at: moment("12:04"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:00"),
      ),
      outcome: report.Confirmed(at: at("12:04")),
    )
  promise.resolve(Nil)
}

pub fn a_second_run_in_the_same_window_registers_nothing_test() {
  use record <- promise.await(against(["08:03"], "08:07", [], "08:07"))

  let #(_, chosen, outcome) = decided(record)
  assert outcome == report.NothingToDo
  assert chosen
    == decision.Skip(decision.AlreadyRegistered(
      punch: punch.Entry,
      at: at("08:03"),
    ))
  // Nothing was appended: the fixture still holds only the first punch.
  assert fixture.punches() == ["08:03"]
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
  assert fixture.punches() == []
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

// The protection claimed for a selector that silently stops matching: the day
// reads as empty, and the rules then refuse a punch whose window has closed.
pub fn a_broken_punch_list_selector_cannot_cause_a_wrong_punch_test() {
  use record <- promise.await(against(
    ["07:58"],
    "12:04",
    [#("PUNCH_LIST_SELECTOR", ".this-matches-nothing")],
    "12:04",
  ))

  let #(day, chosen, outcome) = decided(record)
  assert day == state.Waiting(punch.Entry)
  assert chosen
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 244,
    ))
  assert outcome == report.Refused
  assert fixture.punches() == ["07:58"]
  promise.resolve(Nil)
}

pub fn punches_can_be_read_without_clicking_anything_test() {
  // No trigger: the history is already on the dashboard, so the adapter has no
  // reason to touch a control at all.
  use record <- promise.await(against(
    ["07:58"],
    "12:04",
    [#("PUNCH_TRIGGER_SELECTOR", ""), #("DRY_RUN", "true")],
    "12:04",
  ))

  let #(day, _, outcome) = decided(record)
  assert day == state.Waiting(punch.LunchStart)
  assert outcome == report.Withheld
  assert fixture.punches() == ["07:58"]
  promise.resolve(Nil)
}

pub fn discovery_finds_the_punch_list_selector_test() {
  use base_url <- promise.await(fixture.start(
    registered: ["07:58", "12:04"],
    lands_at: "14:02",
  ))

  let settings_env = env(base_url, [])
  let assert Ok(settings) = config.from_env(settings_env)
  let assert Ok(secrets) = credentials.from_env(settings_env)

  use found <- promise.await(discovery.discover(
    secrets: secrets,
    now: moment("14:00"),
    port: playwright.port(settings, selectors.for_discovery(settings_env)),
  ))
  use _ <- promise.await(fixture.stop())

  let text = discovery.to_text(found)
  assert string.contains(text, "nothing was clicked")
  assert string.contains(text, "candidates for PUNCH_LIST_SELECTOR")
  // The row is what a configuration wants, and discovery offers it.
  assert string.contains(text, "li.punch-row")
  assert string.contains(text, "07:58")
  // Reading the page left the day untouched.
  assert fixture.punches() == ["07:58", "12:04"]
  promise.resolve(Nil)
}
