import acuttis_point/selectors
import gleam/dict
import gleam/string

pub fn the_defaults_are_the_live_interface_test() {
  let loaded = selectors.from_env(dict.new())

  assert loaded.username_field == "input#username"
  assert loaded.password_field == "input#password"
  assert loaded.submit_button == "form.login-form button[type=submit]"
  // An anchor, not a button: the sign-in page's `modal-trigger` does not exist
  // once signed in.
  assert loaded.punch_trigger == "a.size-item-navbar"
  assert loaded.punch_modal == "#mark_modal"
  assert loaded.punch_list == "div.styles_containerMarkingAddress__lLpPc"
}

// `has-text` matches substrings, so it would also find "Comprovante de ponto".
// Matching the wrong control here is the one mistake that registers a punch.
pub fn the_punch_button_is_matched_on_exact_text_test() {
  let loaded = selectors.from_env(dict.new())

  assert loaded.punch_button == "#mark_modal button:text-is(\"Ponto\")"
  assert !string.contains(loaded.punch_button, "has-text")
  assert loaded.punch_receipt
    == "#mark_modal button:text-is(\"Comprovante de ponto\")"
  assert loaded.punch_back == "#mark_modal button:text-is(\"Voltar\")"
}

pub fn every_selector_can_be_overridden_test() {
  let loaded =
    selectors.from_env(
      dict.from_list([
        #("USERNAME_SELECTOR", "#login"),
        #("PASSWORD_SELECTOR", "#secret"),
        #("SUBMIT_SELECTOR", "#go"),
        #("PUNCH_TRIGGER_SELECTOR", "#open"),
        #("PUNCH_MODAL_SELECTOR", "#dialog"),
        #("PUNCH_RECEIPT_SELECTOR", "#receipt"),
        #("PUNCH_BACK_SELECTOR", "#back"),
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
      punch_receipt: "#receipt",
      punch_back: "#back",
      punch_button: "#mark",
      punch_list: "#rows li",
    )
}

// A step that is not needed can be configured away, which is how a deployment
// showing the punches on screen skips the clicking.
pub fn a_skippable_selector_set_to_nothing_means_nothing_test() {
  let loaded =
    selectors.from_env(
      dict.from_list([
        #("PUNCH_TRIGGER_SELECTOR", ""),
        #("PUNCH_RECEIPT_SELECTOR", "   "),
        #("PUNCH_BACK_SELECTOR", ""),
      ]),
    )

  assert loaded.punch_trigger == ""
  assert loaded.punch_receipt == ""
  assert loaded.punch_back == ""
}

// The rest fall back instead: a blank value there is a half-filled file rather
// than an instruction, and an empty selector would match nothing at all.
pub fn a_blank_required_selector_falls_back_to_the_default_test() {
  let loaded =
    selectors.from_env(
      dict.from_list([
        #("PUNCH_LIST_SELECTOR", ""),
        #("PUNCH_BUTTON_SELECTOR", "  "),
        #("USERNAME_SELECTOR", ""),
      ]),
    )

  assert loaded.punch_list == "div.styles_containerMarkingAddress__lLpPc"
  assert loaded.punch_button == "#mark_modal button:text-is(\"Ponto\")"
  assert loaded.username_field == "input#username"
}

pub fn values_are_trimmed_test() {
  let loaded =
    selectors.from_env(dict.from_list([#("PUNCH_LIST_SELECTOR", "  .row  ")]))
  assert loaded.punch_list == ".row"
}
