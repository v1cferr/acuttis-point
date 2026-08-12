import acuttis_point/credentials
import gleam/dict
import gleam/string

fn env(username: String, password: String) -> dict.Dict(String, String) {
  dict.from_list([
    #("ACUTTIS_USERNAME", username),
    #("ACUTTIS_PASSWORD", password),
  ])
}

pub fn both_credentials_are_required_test() {
  assert credentials.from_env(dict.new())
    == Error(credentials.MissingCredential("ACUTTIS_USERNAME"))
  assert credentials.from_env(
      dict.from_list([#("ACUTTIS_USERNAME", "victor@example.test")]),
    )
    == Error(credentials.MissingCredential("ACUTTIS_PASSWORD"))
  assert credentials.from_env(env("victor@example.test", "   "))
    == Error(credentials.MissingCredential("ACUTTIS_PASSWORD"))
}

pub fn a_password_keeps_its_surrounding_spaces_test() {
  let assert Ok(loaded) = credentials.from_env(env("victor", " s3cret "))
  assert credentials.reveal_password(loaded) == " s3cret "
}

pub fn a_username_is_trimmed_test() {
  let assert Ok(loaded) =
    credentials.from_env(env("  victor@example.test  ", "s3cret"))
  assert credentials.username(loaded) == "victor@example.test"
}

pub fn to_string_never_shows_the_password_test() {
  let assert Ok(loaded) =
    credentials.from_env(env("victor@example.test", "s3cret"))
  let rendered = credentials.to_string(loaded)

  assert rendered == "username=v***@example.test password=<redacted>"
  assert !string.contains(rendered, "s3cret")
}

pub fn to_string_masks_a_username_that_is_not_an_email_test() {
  let assert Ok(loaded) = credentials.from_env(env("v1cferr", "s3cret"))
  assert credentials.to_string(loaded) == "username=v*** password=<redacted>"
}

pub fn error_to_string_points_at_the_secret_store_test() {
  assert credentials.error_to_string(credentials.MissingCredential(
      "ACUTTIS_PASSWORD",
    ))
    == "ACUTTIS_PASSWORD is not set; it has to come from the host secret store"
}
