import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/discovery
import acuttis_point/report
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

fn moment() -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-12")
  let assert Ok(time) = clock.parse_time("14:05")
  clock.Instant(date: date, time: time)
}

/// The fake records every call, which is how the test can assert that discovery
/// never reaches a punch control.
fn fake(
  sign_in: Result(Nil, browser.BrowserError),
  describe: Result(List(String), browser.BrowserError),
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
        promise.resolve(Ok([]))
      },
      register: fn(_session, _target) {
        record("register")
        promise.resolve(Ok(Nil))
      },
      describe: fn(_session) {
        record("describe")
        promise.resolve(describe)
      },
      close: fn(_session) {
        record("close")
        promise.resolve(Nil)
      },
    )

  #(port, cell)
}

// The whole reason this mode exists: it has to be impossible for a discovery
// run to register a punch.
pub fn discovery_never_touches_a_punch_control_test() {
  let #(port, cell) = fake(Ok(Nil), Ok(["url: /dashboard"]))
  use _ <- promise.await(discovery.discover(
    secrets: secrets(),
    now: moment(),
    port: port,
  ))

  assert spy.get(cell) == ["open", "sign_in", "describe", "close"]
  promise.resolve(Nil)
}

pub fn a_described_page_is_reported_and_succeeds_test() {
  let #(port, _) =
    fake(
      Ok(Nil),
      Ok(["url: /dashboard", "candidates for PUNCH_LIST_SELECTOR:"]),
    )
  use found <- promise.await(discovery.discover(
    secrets: secrets(),
    now: moment(),
    port: port,
  ))

  assert found
    == discovery.Described(at: moment(), lines: [
      "  url: /dashboard",
      "  candidates for PUNCH_LIST_SELECTOR:",
    ])
  assert discovery.exit_code(found) == 0
  assert discovery.to_text(found)
    == "2026-08-12 14:05 discovery, nothing was clicked
  url: /dashboard
  candidates for PUNCH_LIST_SELECTOR:"
  promise.resolve(Nil)
}

pub fn a_rejected_sign_in_stops_discovery_test() {
  let #(port, cell) =
    fake(Error(browser.AuthenticationRejected("wrong password")), Ok([]))
  use found <- promise.await(discovery.discover(
    secrets: secrets(),
    now: moment(),
    port: port,
  ))

  assert found
    == discovery.Stopped(
      at: moment(),
      stage: report.Authenticating,
      detail: "acuttis rejected the sign in: wrong password",
    )
  assert discovery.exit_code(found) == 1
  // The browser still gets closed, and describe was never reached.
  assert spy.get(cell) == ["open", "sign_in", "close"]
  promise.resolve(Nil)
}

pub fn an_unreadable_page_stops_discovery_test() {
  let #(port, _) =
    fake(Ok(Nil), Error(browser.InterfaceChanged("the dashboard")))
  use found <- promise.await(discovery.discover(
    secrets: secrets(),
    now: moment(),
    port: port,
  ))

  assert discovery.to_text(found)
    == "2026-08-12 14:05 discovery stopped: reading the registered punches"
    <> " failed: could not find the dashboard; the acuttis interface may have"
    <> " changed"
  promise.resolve(Nil)
}
