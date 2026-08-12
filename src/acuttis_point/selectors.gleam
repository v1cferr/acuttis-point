//// Where the automation touches the Acuttis page.
////
//// Acuttis is a client rendered application, so none of this can be derived
//// from a url. These selectors are configuration rather than constants,
//// because the ticket lists an interface change as a failure mode to survive
//// and swapping a selector should not mean editing Gleam.
////
//// The sign-in selectors were read from the live sign-in page and are known
//// good, so they carry defaults. The punch selectors are not: that interface
//// only exists behind a login, and the two defaults below are what the public
//// punch modal on the sign-in page uses, which may or may not be the same
//// component once authenticated.
////
//// `PUNCH_LIST_SELECTOR` deliberately has no default. Without it the
//// automation cannot know which times it is reading, and reading the wrong
//// times is exactly how a punch lands against the wrong event — so it refuses
//// to start instead of guessing.

import gleam/dict.{type Dict}
import gleam/string

pub type Selectors {
  Selectors(
    username_field: String,
    password_field: String,
    submit_button: String,
    /// Opens the punch interface. Empty means the punches are already on the
    /// page and nothing needs to be clicked to see them — which is also the
    /// safest configuration, since it leaves a dry run unable to click at all.
    punch_trigger: String,
    /// Present once the punch interface is open. Empty means there is nothing
    /// to wait for.
    punch_modal: String,
    /// Registers the punch.
    punch_button: String,
    /// Matches one element per punch already registered today, in order.
    punch_list: String,
  )
}

pub type SelectorError {
  MissingSelector(key: String)
}

// Verified against https://app.acuttis.com.br/signin.
const default_username_field = "input#username"

const default_password_field = "input#password"

const default_submit_button = "form.login-form button[type=submit]"

// Seen on the sign-in page's public punch modal. Not verified behind a login.
const default_punch_trigger = "button.modal-trigger"

const default_punch_modal = "#mark_modal"

pub fn from_env(env: Dict(String, String)) -> Result(Selectors, SelectorError) {
  case required(env, "PUNCH_LIST_SELECTOR") {
    Error(error) -> Error(error)
    Ok(punch_list) -> Ok(with_punch_list(env, punch_list))
  }
}

/// Selectors for a discovery run. Discovery exists to find
/// `PUNCH_LIST_SELECTOR`, so it cannot be the one thing it demands up front —
/// and it never reads the punch list anyway.
pub fn for_discovery(env: Dict(String, String)) -> Selectors {
  with_punch_list(env, "")
}

fn with_punch_list(env: Dict(String, String), punch_list: String) -> Selectors {
  Selectors(
    username_field: or_default(env, "USERNAME_SELECTOR", default_username_field),
    password_field: or_default(env, "PASSWORD_SELECTOR", default_password_field),
    submit_button: or_default(env, "SUBMIT_SELECTOR", default_submit_button),
    punch_trigger: or_default(
      env,
      "PUNCH_TRIGGER_SELECTOR",
      default_punch_trigger,
    ),
    punch_modal: or_default(env, "PUNCH_MODAL_SELECTOR", default_punch_modal),
    punch_button: or_default(
      env,
      "PUNCH_BUTTON_SELECTOR",
      default_punch_button(default_punch_modal),
    ),
    punch_list: punch_list,
  )
}

pub fn error_to_string(error: SelectorError) -> String {
  case error {
    MissingSelector(key:) ->
      key
      <> " is not set; it has no safe default and has to be read from the"
      <> " acuttis interface once, signed in"
  }
}

/// Scoped to the modal so it cannot match the identically labelled button that
/// the sign-in page shows to unauthenticated visitors.
fn default_punch_button(modal: String) -> String {
  modal <> " button:has-text(\"Ponto\")"
}

fn required(
  env: Dict(String, String),
  key: String,
) -> Result(String, SelectorError) {
  case dict.get(env, key) {
    Error(Nil) -> Error(MissingSelector(key))
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(MissingSelector(key))
        trimmed -> Ok(trimmed)
      }
  }
}

/// Presence decides here, not blankness: an unset key takes the default, but a
/// key set to nothing means nothing on purpose. That is how
/// `PUNCH_TRIGGER_SELECTOR=` says "do not click anything".
///
/// `required` above uses the opposite rule, because a blank
/// `PUNCH_LIST_SELECTOR` is a mistake rather than an instruction.
fn or_default(
  env: Dict(String, String),
  key: String,
  fallback: String,
) -> String {
  case dict.get(env, key) {
    Error(Nil) -> fallback
    Ok(value) -> string.trim(value)
  }
}
