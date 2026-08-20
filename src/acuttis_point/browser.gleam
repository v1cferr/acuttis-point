//// The port to the outside world.
////
//// Every effect the automation needs sits in one record of functions, so the
//// orchestration in `runner` can be exercised against a fake and the real
//// Playwright adapter stays a leaf. The session type is a parameter because
//// only the adapter knows what a session is.

import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/punch
import acuttis_point/state
import gleam/javascript/promise.{type Promise}

/// Everything that can go wrong on the other side of the port. The list mirrors
/// the failure modes the ticket asks to handle, so a new one is a compile error
/// somewhere rather than a silent string.
pub type BrowserError {
  /// The browser itself would not start.
  LaunchFailed(detail: String)
  /// Acuttis could not be reached, or the connection dropped.
  Unreachable(detail: String)
  /// A step took longer than it was given.
  TimedOut(step: String)
  /// Acuttis refused the credentials.
  AuthenticationRejected(detail: String)
  /// The session stopped being valid partway through the run.
  SessionExpired
  /// Something the automation depends on is not on the page. The likeliest
  /// reading is that the Acuttis interface changed.
  InterfaceChanged(expected: String)
  /// The punch control is there but cannot be used right now.
  PunchUnavailable(detail: String)
  /// The page answered in a shape the adapter could not read.
  UnexpectedResponse(detail: String)
}

pub type Port(session) {
  Port(
    open: fn() -> Promise(Result(session, BrowserError)),
    sign_in: fn(session, credentials.Credentials) ->
      Promise(Result(Nil, BrowserError)),
    /// Today's date, because the receipt Acuttis shows spans several days and
    /// only one of them is the day being decided about.
    read_punches: fn(session, clock.Date) ->
      Promise(Result(List(state.Registered), BrowserError)),
    register: fn(session, punch.Punch) -> Promise(Result(Nil, BrowserError)),
    /// Every row the receipt holds, across every day it lists, and whether the
    /// list actually ran out. For auditing a timesheet rather than acting on
    /// today.
    ///
    /// The second half matters: the receipt paginates, a page boundary can fall
    /// inside a day, and a day read half way looks like a short day rather than
    /// an incomplete one. False means the oldest day is not safe to judge.
    history: fn(session) -> Promise(Result(#(List(String), Bool), BrowserError)),
    /// What the page looks like right now, in lines a human reads. Touches
    /// nothing: it is how the punch selectors get found without risking a
    /// click that registers a real punch.
    describe: fn(session) -> Promise(Result(List(String), BrowserError)),
    /// Everything a punch does except the click. Used by the readiness check,
    /// which has to exercise the click without making one — reading the page is
    /// not enough, because both production failures so far were in the click.
    verify: fn(session) -> Promise(Result(Nil, BrowserError)),
    /// Save a picture of the page as it stands, at the given path. Called only
    /// when a run went wrong: the page at that moment is the only witness to an
    /// interface that changed.
    capture: fn(session, String) -> Promise(Result(Nil, BrowserError)),
    /// Best effort. A run has already happened or not by the time it is called,
    /// so a failure here has nothing left to change.
    close: fn(session) -> Promise(Nil),
  )
}

pub fn error_to_string(error: BrowserError) -> String {
  case error {
    LaunchFailed(detail:) -> "the browser would not start: " <> detail
    Unreachable(detail:) -> "acuttis could not be reached: " <> detail
    TimedOut(step:) -> "timed out while " <> step
    AuthenticationRejected(detail:) ->
      "acuttis rejected the sign in: " <> detail
    SessionExpired -> "the session expired mid-run"
    InterfaceChanged(expected:) ->
      "could not find "
      <> expected
      <> "; the acuttis interface may have changed"
    PunchUnavailable(detail:) -> "the punch control is unavailable: " <> detail
    UnexpectedResponse(detail:) -> "unexpected response: " <> detail
  }
}
