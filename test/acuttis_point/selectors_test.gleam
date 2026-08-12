import acuttis_point/selectors
import gleam/dict

fn env(overrides: List(#(String, String))) -> dict.Dict(String, String) {
  dict.from_list([#("PUNCH_LIST_SELECTOR", ".punch-row"), ..overrides])
}

pub fn the_punch_list_selector_has_no_default_test() {
  assert selectors.from_env(dict.new())
    == Error(selectors.MissingSelector("PUNCH_LIST_SELECTOR"))
  assert selectors.from_env(dict.from_list([#("PUNCH_LIST_SELECTOR", "  ")]))
    == Error(selectors.MissingSelector("PUNCH_LIST_SELECTOR"))
}

pub fn the_sign_in_selectors_default_to_the_live_page_test() {
  let assert Ok(loaded) = selectors.from_env(env([]))

  assert loaded.username_field == "input#username"
  assert loaded.password_field == "input#password"
  assert loaded.submit_button == "form.login-form button[type=submit]"
}

pub fn the_punch_button_default_is_scoped_to_the_modal_test() {
  let assert Ok(loaded) = selectors.from_env(env([]))

  // Unscoped it would also match the button the sign-in page shows to
  // unauthenticated visitors.
  assert loaded.punch_modal == "#mark_modal"
  assert loaded.punch_button == "#mark_modal button:has-text(\"Ponto\")"
}

pub fn every_selector_can_be_overridden_test() {
  let assert Ok(loaded) =
    selectors.from_env(
      env([
        #("USERNAME_SELECTOR", "#login"),
        #("PASSWORD_SELECTOR", "#secret"),
        #("SUBMIT_SELECTOR", "#go"),
        #("PUNCH_TRIGGER_SELECTOR", "#open"),
        #("PUNCH_MODAL_SELECTOR", "#dialog"),
        #("PUNCH_BUTTON_SELECTOR", "#mark"),
        #("PUNCH_LIST_SELECTOR", "#rows li"),
      ]),
    )

  assert loaded
    == selectors.Selectors(
      username_field: "#login",
      password_field: "#secret",
      submit_button: "#go",
      punch_trigger: "#open",
      punch_modal: "#dialog",
      punch_button: "#mark",
      punch_list: "#rows li",
    )
}

pub fn overriding_the_modal_does_not_move_the_punch_button_test() {
  // The button default is derived from the default modal, not the configured
  // one: half-overriding a pair would be worse than either choice.
  let assert Ok(loaded) =
    selectors.from_env(env([#("PUNCH_MODAL_SELECTOR", "#dialog")]))

  assert loaded.punch_modal == "#dialog"
  assert loaded.punch_button == "#mark_modal button:has-text(\"Ponto\")"
}

pub fn error_to_string_says_where_to_find_it_test() {
  assert selectors.error_to_string(selectors.MissingSelector(
      "PUNCH_LIST_SELECTOR",
    ))
    == "PUNCH_LIST_SELECTOR is not set; it has no safe default and has to be"
    <> " read from the acuttis interface once, signed in"
}
