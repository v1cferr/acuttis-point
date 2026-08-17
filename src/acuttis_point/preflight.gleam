//// A rehearsal, shortly before a punch is due.
////
//// It exists because of how this automation has actually failed. Twice in
//// production the run got as far as the punch button and could not click it,
//// and both times the news arrived after the window had closed — too late to do
//// anything but punch by hand and hope it was noticed.
////
//// So this runs ahead of the window and exercises the whole path: sign in, read
//// the day, reach the punch button, and check that clicking it would work.
//// Playwright's trial mode performs every check a real click performs and then
//// declines to dispatch the event, which is what makes this a rehearsal rather
//// than an opinion.
////
//// It never registers anything. That is not a promise about intent but about
//// reach: the only operation here that could punch is `verify`, and its whole
//// job is to stop one step short.

import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/javascript/promise.{type Promise}
import gleam/string

pub type Preflight {
  /// The path works, and this is what the day looks like from here.
  Ready(
    at: clock.Instant,
    day: state.DayState,
    registered: List(state.Registered),
  )
  /// Something on the way to the punch button is broken. There is still time to
  /// do something about it, which is the entire point.
  NotReady(at: clock.Instant, stage: report.Stage, detail: String)
}

pub fn check(
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
) -> Promise(Preflight) {
  use opened <- promise.await(port.open())

  case opened {
    Error(error) ->
      promise.resolve(not_ready(now, report.StartingBrowser, error))
    Ok(session) -> {
      use result <- promise.await(rehearse(secrets, now, port, session))
      use _ <- promise.await(port.close(session))
      promise.resolve(result)
    }
  }
}

/// Zero when the punch would work. Non-zero makes the systemd unit red, which
/// is the second way of noticing after the notification.
pub fn exit_code(preflight: Preflight) -> Int {
  case preflight {
    Ready(..) -> 0
    NotReady(..) -> 1
  }
}

pub fn to_line(preflight: Preflight) -> String {
  case preflight {
    Ready(at:, day:, registered:) ->
      timestamp(at)
      <> " preflight=READY state="
      <> state.to_string(day)
      <> " punches=\""
      <> state.registered_to_string(registered)
      <> "\" next="
      <> next_punch(day)
    NotReady(at:, stage:, detail:) ->
      timestamp(at)
      <> " preflight=NOT_READY stage=\""
      <> report.stage_to_string(stage)
      <> "\" reason=\""
      <> string.replace(detail, each: "\"", with: "'")
      <> "\""
  }
}

/// The punch this rehearsal was about. A finished day has none, which is itself
/// worth saying.
pub fn next_punch(day: state.DayState) -> String {
  case day {
    state.Waiting(missing) -> punch.to_string(missing)
    state.Completed -> "NONE"
    state.Invalid(_) -> "UNKNOWN"
  }
}

fn rehearse(
  secrets: credentials.Credentials,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
) -> Promise(Preflight) {
  use signed_in <- promise.await(port.sign_in(session, secrets))

  case signed_in {
    Error(error) ->
      promise.resolve(not_ready(now, report.Authenticating, error))
    Ok(Nil) -> {
      use read <- promise.await(port.read_punches(session, now.date))

      case read {
        Error(error) ->
          promise.resolve(not_ready(now, report.ReadingPunches, error))
        Ok(registered) ->
          case state.from_punches(registered) {
            // A finished day has no button left to rehearse, and reaching for
            // one would be answering a question nobody asked.
            state.Completed ->
              promise.resolve(Ready(
                at: now,
                day: state.Completed,
                registered: registered,
              ))
            day -> confirm_punchable(now, port, session, day, registered)
          }
      }
    }
  }
}

fn confirm_punchable(
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
  day: state.DayState,
  registered: List(state.Registered),
) -> Promise(Preflight) {
  use punchable <- promise.await(port.verify(session))

  promise.resolve(case punchable {
    Error(error) -> not_ready(now, report.RegisteringPunch, error)
    Ok(Nil) -> Ready(at: now, day: day, registered: registered)
  })
}

fn timestamp(at: clock.Instant) -> String {
  clock.date_to_string(at.date) <> " " <> clock.time_to_string(at.time)
}

fn not_ready(
  now: clock.Instant,
  stage: report.Stage,
  error: browser.BrowserError,
) -> Preflight {
  NotReady(at: now, stage: stage, detail: browser.error_to_string(error))
}
