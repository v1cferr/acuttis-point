//// The Playwright adapter: the only module that knows a browser exists.
////
//// It implements `browser.Port` and nothing else, so everything above it stays
//// testable without Chromium. The JavaScript side reports failures as a
//// `#(kind, detail)` pair, which `classify` turns into a typed error — that
//// keeps the judgement about what a failure means on the Gleam side, where it
//// can be read and tested.
////
//// `register` ignores which punch is due. Acuttis records the next mark of the
//// day from a single control, the way a time clock does, so there is nothing to
//// choose. If that turns out to be wrong for some punch, the runner's
//// confirmation step catches it: it re-reads the day and the punch it asked for
//// has to be there.

import acuttis_point/acuttis
import acuttis_point/browser
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/selectors
import gleam/javascript/array.{type Array}
import gleam/javascript/promise.{type Promise}
import gleam/result

/// A Playwright browser, context and page, held on the JavaScript side.
pub type Session

/// How the JavaScript side reports a failure: a kind, and a detail for the log.
pub type Failure =
  #(String, String)

pub fn port(
  settings: config.Config,
  page_selectors: selectors.Selectors,
) -> browser.Port(Session) {
  browser.Port(
    open: fn() {
      ffi_open(
        settings.headless,
        settings.timeout_seconds * 1000,
        // Empty means do not persist: every run signs in from scratch.
        result.unwrap(settings.session_file, ""),
      )
      |> promise.map(translate)
    },
    sign_in: fn(session, secrets) {
      ffi_sign_in(
        session,
        settings.base_url,
        page_selectors.username_field,
        page_selectors.password_field,
        page_selectors.submit_button,
        credentials.username(secrets),
        credentials.reveal_password(secrets),
      )
      |> promise.map(translate)
    },
    read_punches: fn(session, today) {
      ffi_punch_texts(
        session,
        page_selectors.punch_trigger,
        page_selectors.punch_modal,
        page_selectors.punch_receipt,
        page_selectors.punch_list,
      )
      |> promise.map(fn(outcome) {
        use texts <- result.try(translate(outcome))
        acuttis.read_punches(rows: array.to_list(texts), today: today)
        |> result.map_error(fn(error) {
          case error {
            // Not a strange answer but a missing one, and the likeliest reading
            // is that the generated class name changed under us.
            acuttis.PunchListNotFound ->
              browser.InterfaceChanged("any row on the punch receipt")
            _ -> browser.UnexpectedResponse(acuttis.error_to_string(error))
          }
        })
      })
    },
    register: fn(session, _target) {
      ffi_register(
        session,
        page_selectors.punch_trigger,
        page_selectors.punch_modal,
        page_selectors.punch_receipt,
        page_selectors.punch_back,
        page_selectors.punch_button,
        page_selectors.punch_list,
      )
      |> promise.map(translate)
    },
    describe: fn(session) {
      ffi_describe(
        session,
        page_selectors.punch_trigger,
        page_selectors.punch_modal,
      )
      |> promise.map(fn(outcome) {
        translate(outcome)
        |> result.map(array.to_list)
      })
    },
    verify: fn(session) {
      ffi_verify(
        session,
        page_selectors.punch_trigger,
        page_selectors.punch_modal,
        page_selectors.punch_receipt,
        page_selectors.punch_back,
        page_selectors.punch_button,
        page_selectors.punch_list,
      )
      |> promise.map(translate)
    },
    capture: fn(session, path) {
      ffi_screenshot(session, path)
      |> promise.map(fn(detail) {
        case detail {
          "" -> Ok(Nil)
          _ -> Error(browser.UnexpectedResponse(detail))
        }
      })
    },
    close: ffi_close,
  )
}

/// Public because it is the whole contract with the JavaScript side, and worth
/// pinning down in a test.
pub fn classify(failure: Failure) -> browser.BrowserError {
  let #(kind, detail) = failure
  case kind {
    "launch" -> browser.LaunchFailed(detail)
    "unreachable" -> browser.Unreachable(detail)
    "timeout" -> browser.TimedOut(detail)
    "auth" -> browser.AuthenticationRejected(detail)
    "expired" -> browser.SessionExpired
    "interface" -> browser.InterfaceChanged(detail)
    "unavailable" -> browser.PunchUnavailable(detail)
    // A kind this version does not know about is still a failure, and saying so
    // beats crashing on it.
    _ -> browser.UnexpectedResponse(detail)
  }
}

fn translate(
  outcome: Result(value, Failure),
) -> Result(value, browser.BrowserError) {
  result.map_error(outcome, classify)
}

@external(javascript, "./playwright_ffi.mjs", "open")
fn ffi_open(
  headless: Bool,
  timeout_ms: Int,
  session_path: String,
) -> Promise(Result(Session, Failure))

/// Empty string on success, the failure detail otherwise.
@external(javascript, "./playwright_ffi.mjs", "screenshot")
fn ffi_screenshot(session: Session, path: String) -> Promise(String)

@external(javascript, "./playwright_ffi.mjs", "signIn")
fn ffi_sign_in(
  session: Session,
  base_url: String,
  username_selector: String,
  password_selector: String,
  submit_selector: String,
  username: String,
  password: String,
) -> Promise(Result(Nil, Failure))

@external(javascript, "./playwright_ffi.mjs", "punchTexts")
fn ffi_punch_texts(
  session: Session,
  trigger_selector: String,
  modal_selector: String,
  receipt_selector: String,
  list_selector: String,
) -> Promise(Result(Array(String), Failure))

/// Takes the whole set: registering means leaving the receipt, clicking the
/// punch, and coming back to watch the list grow by one.
@external(javascript, "./playwright_ffi.mjs", "registerPunch")
fn ffi_register(
  session: Session,
  trigger_selector: String,
  modal_selector: String,
  receipt_selector: String,
  back_selector: String,
  button_selector: String,
  list_selector: String,
) -> Promise(Result(Nil, Failure))

@external(javascript, "./playwright_ffi.mjs", "describePage")
fn ffi_describe(
  session: Session,
  trigger_selector: String,
  modal_selector: String,
) -> Promise(Result(Array(String), Failure))

@external(javascript, "./playwright_ffi.mjs", "verifyPunchable")
fn ffi_verify(
  session: Session,
  trigger_selector: String,
  modal_selector: String,
  receipt_selector: String,
  back_selector: String,
  button_selector: String,
  list_selector: String,
) -> Promise(Result(Nil, Failure))

@external(javascript, "./playwright_ffi.mjs", "close")
fn ffi_close(session: Session) -> Promise(Nil)
