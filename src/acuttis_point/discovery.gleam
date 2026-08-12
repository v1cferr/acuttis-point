//// A look at the punch interface that touches nothing.
////
//// This exists because of an awkward corner: finding `PUNCH_LIST_SELECTOR`
//// needs an authenticated session, and an authenticated session is exactly
//// where a stray click could register a real punch.
////
//// So discovery signs in, reads the page and stops. It never clicks a punch
//// control, never opens anything, and never decides. A hidden element is still
//// in the DOM, so it can find the punch rows without opening the interface at
//// all.

import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/report
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string

pub type Discovery {
  Described(at: clock.Instant, lines: List(String))
  Stopped(at: clock.Instant, stage: report.Stage, detail: String)
}

pub fn discover(
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
) -> Promise(Discovery) {
  use opened <- promise.await(port.open())

  case opened {
    Error(error) -> promise.resolve(stopped(now, report.StartingBrowser, error))
    Ok(session) -> {
      use result <- promise.await(look(secrets, now, port, session))
      use _ <- promise.await(port.close(session))
      promise.resolve(result)
    }
  }
}

/// Zero on success. A discovery run has nothing to refuse, so there is no
/// third case here.
pub fn exit_code(discovery: Discovery) -> Int {
  case discovery {
    Described(..) -> 0
    Stopped(..) -> 1
  }
}

pub fn to_text(discovery: Discovery) -> String {
  case discovery {
    Described(at:, lines:) ->
      [timestamp(at) <> " discovery, nothing was clicked", ..lines]
      |> string.join("\n")
    Stopped(at:, stage:, detail:) ->
      timestamp(at)
      <> " discovery stopped: "
      <> report.stage_to_string(stage)
      <> " failed: "
      <> detail
  }
}

fn look(
  secrets: credentials.Credentials,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
) -> Promise(Discovery) {
  use signed_in <- promise.await(port.sign_in(session, secrets))

  case signed_in {
    Error(error) -> promise.resolve(stopped(now, report.Authenticating, error))
    Ok(Nil) -> {
      use described <- promise.await(port.describe(session))

      case described {
        Error(error) ->
          promise.resolve(stopped(now, report.ReadingPunches, error))
        Ok(lines) ->
          promise.resolve(Described(at: now, lines: list.map(lines, indent)))
      }
    }
  }
}

fn indent(line: String) -> String {
  "  " <> line
}

fn timestamp(at: clock.Instant) -> String {
  clock.date_to_string(at.date) <> " " <> clock.time_to_string(at.time)
}

fn stopped(
  now: clock.Instant,
  stage: report.Stage,
  error: browser.BrowserError,
) -> Discovery {
  Stopped(at: now, stage: stage, detail: browser.error_to_string(error))
}
