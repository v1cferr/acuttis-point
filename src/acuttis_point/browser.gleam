//// The port to the outside world.
////
//// Every effect the automation needs sits in one record of functions, so the
//// orchestration in `runner` can be exercised against a fake and the real
//// Playwright adapter stays a leaf. The session type is a parameter because
//// only the adapter knows what a session is.

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
    read_punches: fn(session) ->
      Promise(Result(List(state.Registered), BrowserError)),
    register: fn(session, punch.Punch) -> Promise(Result(Nil, BrowserError)),
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
