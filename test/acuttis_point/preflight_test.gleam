import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/notification
import acuttis_point/preflight
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/dict
import gleam/javascript/promise
import gleam/list
import support/spy

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
  let assert Ok(date) = clock.parse_date("2026-08-17")
  clock.Instant(date: date, time: at(time))
}

fn fake(
  registered: List(state.Registered),
  sign_in: Result(Nil, browser.BrowserError),
  verify: Result(Nil, browser.BrowserError),
) -> #(browser.Port(Nil), spy.Cell(List(String))) {
  let cell = spy.new([])
  let record = fn(name: String) -> Nil {
    spy.set(cell, list.append(spy.get(cell), [name]))
  }

  let port =
    browser.Port(
      open: fn() {
        record("open")
        promise.resolve(Ok(Nil))
      },
      sign_in: fn(_session, _secrets) {
        record("sign_in")
        promise.resolve(sign_in)
      },
      read_punches: fn(_session, _today) {
        record("read_punches")
        promise.resolve(Ok(registered))
      },
      register: fn(_session, _target) {
        record("register")
        promise.resolve(Ok(Nil))
      },
      history: fn(_) { promise.resolve(Ok(#([], True))) },
      describe: fn(_session) {
        record("describe")
        promise.resolve(Ok([]))
      },
      verify: fn(_session) {
        record("verify")
        promise.resolve(verify)
      },
      capture: fn(_session, _path) {
        record("capture")
        promise.resolve(Ok(Nil))
      },
      close: fn(_session) {
        record("close")
        promise.resolve(Nil)
      },
    )

  #(port, cell)
}

fn punches(entries: List(#(punch.Punch, String))) -> List(state.Registered) {
  list.map(entries, fn(entry) {
    let #(kind, time) = entry
    state.Registered(punch: kind, at: at(time))
  })
}

// The one thing a rehearsal must never do.
pub fn a_rehearsal_never_registers_test() {
  let #(port, cell) = fake(punches([#(punch.Entry, "08:12")]), Ok(Nil), Ok(Nil))
  use _ <- promise.await(preflight.check(
    secrets: secrets(),
    now: moment("12:20"),
    port: port,
  ))

  assert !list.contains(spy.get(cell), "register")
  assert spy.get(cell) == ["open", "sign_in", "read_punches", "verify", "close"]
  promise.resolve(Nil)
}

// Reading the page is not enough: both production failures were in the click,
// so the rehearsal has to reach the button and check it would take one.
pub fn a_punch_button_that_would_not_take_a_click_is_not_ready_test() {
  let #(port, _) =
    fake(
      punches([#(punch.Entry, "08:12")]),
      Ok(Nil),
      Error(browser.PunchUnavailable("element is not visible")),
    )
  use checked <- promise.await(preflight.check(
    secrets: secrets(),
    now: moment("12:20"),
    port: port,
  ))

  assert checked
    == preflight.NotReady(
      at: moment("12:20"),
      stage: report.RegisteringPunch,
      detail: "the punch control is unavailable: element is not visible",
    )
  assert preflight.exit_code(checked) == 1
  promise.resolve(Nil)
}

pub fn a_working_path_is_ready_and_says_what_is_next_test() {
  let day = punches([#(punch.Entry, "08:12")])
  let #(port, _) = fake(day, Ok(Nil), Ok(Nil))
  use checked <- promise.await(preflight.check(
    secrets: secrets(),
    now: moment("12:20"),
    port: port,
  ))

  assert checked
    == preflight.Ready(
      at: moment("12:20"),
      day: state.Waiting(punch.LunchStart),
      registered: day,
    )
  assert preflight.exit_code(checked) == 0
  assert preflight.to_line(checked)
    == "2026-08-17 12:20 preflight=READY state=WAITING(LUNCH_START)"
    <> " punches=\"ENTRY@08:12\" next=LUNCH_START"
  promise.resolve(Nil)
}

// A finished day has no button left to rehearse, and reaching for one would be
// answering a question nobody asked.
pub fn a_finished_day_is_ready_without_touching_the_button_test() {
  let full =
    punches([
      #(punch.Entry, "08:12"),
      #(punch.LunchStart, "12:40"),
      #(punch.LunchEnd, "13:55"),
      #(punch.Exit, "17:35"),
    ])
  let #(port, cell) = fake(full, Ok(Nil), Ok(Nil))
  use checked <- promise.await(preflight.check(
    secrets: secrets(),
    now: moment("18:15"),
    port: port,
  ))

  assert !list.contains(spy.get(cell), "verify")
  assert preflight.exit_code(checked) == 0
  assert notification.from_preflight(checked).title == "Dia já está completo"
  promise.resolve(Nil)
}

pub fn a_rejected_sign_in_is_reported_early_test() {
  let #(port, cell) =
    fake([], Error(browser.AuthenticationRejected("wrong password")), Ok(Nil))
  use checked <- promise.await(preflight.check(
    secrets: secrets(),
    now: moment("07:36"),
    port: port,
  ))

  assert checked
    == preflight.NotReady(
      at: moment("07:36"),
      stage: report.Authenticating,
      detail: "acuttis rejected the sign in: wrong password",
    )
  // The browser still gets closed, and the button was never reached.
  assert spy.get(cell) == ["open", "sign_in", "close"]
  promise.resolve(Nil)
}

pub fn the_notification_says_what_is_ready_test() {
  let day = punches([#(punch.Entry, "08:12")])
  let ready =
    preflight.Ready(
      at: moment("12:20"),
      day: state.Waiting(punch.LunchStart),
      registered: day,
    )
  let message = notification.from_preflight(ready)
  assert message.title == "Tudo pronto para a saída para o almoço"
  assert message.priority == "default"

  let broken =
    preflight.NotReady(
      at: moment("12:20"),
      stage: report.RegisteringPunch,
      detail: "the punch button is disabled",
    )
  let alarm = notification.from_preflight(broken)
  assert alarm.title == "ATENÇÃO: não vai dar para bater"
  assert alarm.priority == "high"
}
