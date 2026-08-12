//// Acuttis sign-in credentials.
////
//// The type is opaque and its `to_string` is redacted, so the ordinary way of
//// getting a value into a log cannot leak one. Reaching the password takes
//// `reveal_password`, which is named to stand out in a diff — the only place
//// that should ever call it is the code filling the sign-in form.

import gleam/dict.{type Dict}
import gleam/string

pub opaque type Credentials {
  Credentials(username: String, password: String)
}

pub type CredentialsError {
  MissingCredential(key: String)
}

const username_key = "ACUTTIS_USERNAME"

const password_key = "ACUTTIS_PASSWORD"

/// Read the credentials from the environment. They have no defaults and no
/// in-repository fallback: an unset secret is an error, never a guess.
pub fn from_env(
  env: Dict(String, String),
) -> Result(Credentials, CredentialsError) {
  case required(env, username_key), required(env, password_key) {
    Ok(username), Ok(password) ->
      // The username is a form field and safe to normalise. The password is
      // taken exactly as given, since a space can be part of it.
      Ok(Credentials(username: string.trim(username), password: password))
    Error(error), _ -> Error(error)
    _, Error(error) -> Error(error)
  }
}

pub fn username(credentials: Credentials) -> String {
  credentials.username
}

/// The password in clear. Every call site is a place a secret could escape.
pub fn reveal_password(credentials: Credentials) -> String {
  credentials.password
}

/// Enough to tell which account was used, and nothing more.
pub fn to_string(credentials: Credentials) -> String {
  "username=" <> mask(credentials.username) <> " password=<redacted>"
}

pub fn error_to_string(error: CredentialsError) -> String {
  case error {
    MissingCredential(key:) ->
      key <> " is not set; it has to come from the host secret store"
  }
}

fn required(
  env: Dict(String, String),
  key: String,
) -> Result(String, CredentialsError) {
  case dict.get(env, key) {
    Error(Nil) -> Error(MissingCredential(key))
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(MissingCredential(key))
        _ -> Ok(value)
      }
  }
}

fn mask(value: String) -> String {
  case string.split(value, on: "@") {
    [local, domain] -> keep_first(local) <> "@" <> domain
    _ -> keep_first(value)
  }
}

fn keep_first(value: String) -> String {
  case string.first(value) {
    Ok(first) -> first <> "***"
    Error(Nil) -> "***"
  }
}
