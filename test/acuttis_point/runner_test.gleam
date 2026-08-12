import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/decision
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/runner
import acuttis_point/state
import gleam/dict
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/result
import support/spy

const workday = "2026-08-12"

// --- fixtures ---------------------------------------------------------------

fn settings(overrides: List(#(String, String))) -> config.Config {
  let assert Ok(loaded) =
    [
      #("ENTRY_TIME", "08:00"),
      #("LUNCH_START", "12:00"),
      #("LUNCH_END", "14:00"),
      #("EXIT_TIME", "17:30"),
      #("TIME_TOLERANCE_MINUTES", "10"),
    ]
    |> list.append(overrides)
    |> dict.from_list
    |> config.from_env
  loaded
}

fn secrets() -> credentials.Credentials {
  let assert Ok(loaded) =
    credentials.from_env(
      dict.from_list([
        #("ACUTTIS_USERNAME", "victor@example.test"),
        #("ACUTTIS_PASSWORD", "s3cret"),
      ]),
    )
  loaded
}

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date(workday)
  clock.Instant(date: date, time: at(time))
}

// --- fake port --------------------------------------------------------------

type Journal {
  Journal(calls: List(String), punches: List(state.Registered))
}

/// Which steps succeed, and whether a registration actually lands. Everything
/// defaults to working, so each test names only what it breaks.
type Behaviour {
  Behaviour(
    open: Result(Nil, browser.BrowserError),
    sign_in: Result(Nil, browser.BrowserError),
    first_read: Result(Nil, browser.BrowserError),
    register: Result(Nil, browser.BrowserError),
    second_read: Result(Nil, browser.BrowserError),
    records_punch: Bool,
  )
}

fn working() -> Behaviour {
  Behaviour(
    open: Ok(Nil),
    sign_in: Ok(Nil),
    first_read: Ok(Nil),
    register: Ok(Nil),
    second_read: Ok(Nil),
    records_punch: True,
  )
}

fn fake(
  behaviour: Behaviour,
  existing: List(state.Registered),
  lands_at: clock.TimeOfDay,
) -> #(browser.Port(Nil), spy.Cell(Journal)) {
  let cell = spy.new(Journal(calls: [], punches: existing))

  let record = fn(name: String) -> Nil {
    let journal = spy.get(cell)
    spy.set(cell, Journal(..journal, calls: list.append(journal.calls, [name])))
  }

  let port =
    browser.Port(
      open: fn() {
        record("open")
        promise.resolve(behaviour.open)
      },
      sign_in: fn(_session, _secrets) {
        record("sign_in")
        promise.resolve(behaviour.sign_in)
      },
      read_punches: fn(_session) {
        record("read_punches")
        let journal = spy.get(cell)
        let reads =
          list.count(journal.calls, fn(call) { call == "read_punches" })
        let step = case reads {
          1 -> behaviour.first_read
          _ -> behaviour.second_read
        }
        promise.resolve(result.map(step, fn(_) { journal.punches }))
      },
      register: fn(_session, target) {
        record("register")
        case behaviour.register, behaviour.records_punch {
          Ok(Nil), True -> {
            let journal = spy.get(cell)
            spy.set(
              cell,
              Journal(
                ..journal,
                punches: list.append(journal.punches, [
                  state.Registered(punch: target, at: lands_at),
                ]),
              ),
            )
          }
          _, _ -> Nil
        }
        promise.resolve(behaviour.register)
      },
      describe: fn(_session) {
        record("describe")
        promise.resolve(Ok(["url: /dashboard"]))
      },
      close: fn(_session) {
        record("close")
        promise.resolve(Nil)
      },
    )

  #(port, cell)
}

fn calls(cell: spy.Cell(Journal)) -> List(String) {
  spy.get(cell).calls
}

fn punches(entries: List(#(punch.Punch, String))) -> List(state.Registered) {
  list.map(entries, fn(entry) {
    let #(kind, time) = entry
    state.Registered(punch: kind, at: at(time))
  })
}

fn go(
  behaviour: Behaviour,
  existing: List(state.Registered),
  now: String,
  overrides: List(#(String, String)),
) -> Promise(#(report.Report, spy.Cell(Journal))) {
  let #(port, cell) = fake(behaviour, existing, at(now))
  use record <- promise.await(runner.run(
    settings: settings(overrides),
    secrets: secrets(),
    now: moment(now),
    port: port,
  ))
  promise.resolve(#(record, cell))
}

// --- tests ------------------------------------------------------------------

pub fn a_due_punch_is_registered_and_confirmed_test() {
  use #(record, cell) <- promise.await(go(working(), [], "08:03", []))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Confirmed(at: at("08:03")),
    )
  // The punches are read a second time: the confirmation is observed, not
  // assumed from the click succeeding.
  assert calls(cell)
    == ["open", "sign_in", "read_punches", "register", "read_punches", "close"]
  promise.resolve(Nil)
}

pub fn a_registration_acuttis_does_not_show_back_fails_test() {
  let silent = Behaviour(..working(), records_punch: False)
  use #(record, cell) <- promise.await(go(silent, [], "08:03", []))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Failed(
        stage: report.ConfirmingPunch,
        detail: "acuttis does not show ENTRY after registering it",
      ),
    )
  assert report.exit_code(record) == 1
  assert list.contains(calls(cell), "close")
  promise.resolve(Nil)
}

pub fn a_dry_run_decides_but_never_registers_test() {
  use #(record, cell) <- promise.await(
    go(working(), [], "08:03", [#("DRY_RUN", "true")]),
  )

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Withheld,
    )
  assert calls(cell) == ["open", "sign_in", "read_punches", "close"]
  assert report.exit_code(record) == 0
  promise.resolve(Nil)
}

pub fn a_skip_never_reaches_the_punch_control_test() {
  use #(record, cell) <- promise.await(go(working(), [], "07:30", []))

  assert record
    == report.Decided(
      at: moment("07:30"),
      state: state.Waiting(punch.Entry),
      decision: decision.Skip(decision.TooEarly(
        next: punch.Entry,
        opens_at: at("08:00"),
      )),
      outcome: report.NothingToDo,
    )
  assert calls(cell) == ["open", "sign_in", "read_punches", "close"]
  promise.resolve(Nil)
}

pub fn an_abort_never_reaches_the_punch_control_test() {
  use #(record, cell) <- promise.await(go(working(), [], "11:00", []))

  assert record
    == report.Decided(
      at: moment("11:00"),
      state: state.Waiting(punch.Entry),
      decision: decision.Abort(decision.WindowClosed(
        punch: punch.Entry,
        expected_at: at("08:00"),
        minutes_late: 180,
      )),
      outcome: report.Refused,
    )
  assert calls(cell) == ["open", "sign_in", "read_punches", "close"]
  assert report.exit_code(record) == 2
  promise.resolve(Nil)
}

pub fn a_second_run_in_the_same_window_registers_nothing_test() {
  let already = punches([#(punch.Entry, "08:03")])
  use #(record, cell) <- promise.await(go(working(), already, "08:05", []))

  assert record
    == report.Decided(
      at: moment("08:05"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Skip(decision.AlreadyRegistered(
        punch: punch.Entry,
        at: at("08:03"),
      )),
      outcome: report.NothingToDo,
    )
  assert !list.contains(calls(cell), "register")
  promise.resolve(Nil)
}

pub fn a_browser_that_will_not_start_breaks_early_test() {
  let broken =
    Behaviour(..working(), open: Error(browser.LaunchFailed("no chromium")))
  use #(record, cell) <- promise.await(go(broken, [], "08:03", []))

  assert record
    == report.Broke(
      at: moment("08:03"),
      stage: report.StartingBrowser,
      detail: "the browser would not start: no chromium",
    )
  // Nothing was opened, so there is nothing to close.
  assert calls(cell) == ["open"]
  assert report.exit_code(record) == 1
  promise.resolve(Nil)
}

pub fn rejected_credentials_break_at_authentication_test() {
  let rejected =
    Behaviour(
      ..working(),
      sign_in: Error(browser.AuthenticationRejected("invalid password")),
    )
  use #(record, cell) <- promise.await(go(rejected, [], "08:03", []))

  assert record
    == report.Broke(
      at: moment("08:03"),
      stage: report.Authenticating,
      detail: "acuttis rejected the sign in: invalid password",
    )
  assert calls(cell) == ["open", "sign_in", "close"]
  promise.resolve(Nil)
}

pub fn an_unreadable_day_breaks_before_deciding_test() {
  let changed =
    Behaviour(
      ..working(),
      first_read: Error(browser.InterfaceChanged("the punch list")),
    )
  use #(record, _) <- promise.await(go(changed, [], "08:03", []))

  assert record
    == report.Broke(
      at: moment("08:03"),
      stage: report.ReadingPunches,
      detail: "could not find the punch list; the acuttis interface may have changed",
    )
  promise.resolve(Nil)
}

pub fn a_punch_control_that_refuses_fails_at_registration_test() {
  let unavailable =
    Behaviour(
      ..working(),
      register: Error(browser.PunchUnavailable("the button is disabled")),
    )
  use #(record, cell) <- promise.await(go(unavailable, [], "08:03", []))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Failed(
        stage: report.RegisteringPunch,
        detail: "the punch control is unavailable: the button is disabled",
      ),
    )
  assert calls(cell) == ["open", "sign_in", "read_punches", "register", "close"]
  promise.resolve(Nil)
}

pub fn a_session_that_expires_during_confirmation_fails_test() {
  let expired =
    Behaviour(..working(), second_read: Error(browser.SessionExpired))
  use #(record, _) <- promise.await(go(expired, [], "08:03", []))

  assert record
    == report.Decided(
      at: moment("08:03"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      outcome: report.Failed(
        stage: report.ConfirmingPunch,
        detail: "the session expired mid-run",
      ),
    )
  promise.resolve(Nil)
}

pub fn a_full_day_is_left_alone_test() {
  let full =
    punches([
      #(punch.Entry, "08:00"),
      #(punch.LunchStart, "12:00"),
      #(punch.LunchEnd, "14:00"),
      #(punch.Exit, "17:30"),
    ])
  use #(record, cell) <- promise.await(go(working(), full, "17:35", []))

  assert record
    == report.Decided(
      at: moment("17:35"),
      state: state.Completed,
      decision: decision.Skip(decision.DayAlreadyComplete),
      outcome: report.NothingToDo,
    )
  assert !list.contains(calls(cell), "register")
  promise.resolve(Nil)
}
