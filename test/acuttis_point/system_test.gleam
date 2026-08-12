import acuttis_point/clock
import acuttis_point/system
import gleam/dict
import gleam/string

pub fn the_environment_is_readable_test() {
  let environment = system.environment()
  // Set by the Nix dev shell, and the reason the Playwright adapter can find
  // its browsers at all.
  assert dict.has_key(environment.values, "PLAYWRIGHT_BROWSERS_PATH")
}

pub fn a_dotenv_assigns_values_test() {
  assert system.parse_dotenv(
      "ENTRY_TIME=08:00
LUNCH_START=12:00",
    )
    == dict.from_list([#("ENTRY_TIME", "08:00"), #("LUNCH_START", "12:00")])
}

pub fn a_dotenv_ignores_comments_and_blank_lines_test() {
  assert system.parse_dotenv(
      "# the schedule

ENTRY_TIME=08:00
   # indented comment
",
    )
    == dict.from_list([#("ENTRY_TIME", "08:00")])
}

pub fn a_dotenv_accepts_an_export_prefix_test() {
  assert system.parse_dotenv("export ACUTTIS_USERNAME=victor@example.test")
    == dict.from_list([#("ACUTTIS_USERNAME", "victor@example.test")])
}

pub fn a_dotenv_strips_surrounding_quotes_test() {
  assert system.parse_dotenv(
      "SINGLE='s3cret'
DOUBLE=\"s3cret\"
SPACED=\" s3cret \"",
    )
    == dict.from_list([
      #("SINGLE", "s3cret"),
      #("DOUBLE", "s3cret"),
      // Quotes are how a password keeps its outer spaces.
      #("SPACED", " s3cret "),
    ])
}

pub fn a_dotenv_keeps_a_value_containing_equals_or_hash_test() {
  assert system.parse_dotenv(
      "PUNCH_BUTTON_SELECTOR=#mark_modal button
TOKEN=abc==",
    )
    == dict.from_list([
      #("PUNCH_BUTTON_SELECTOR", "#mark_modal button"),
      #("TOKEN", "abc=="),
    ])
}

pub fn a_dotenv_skips_a_line_it_cannot_read_test() {
  assert system.parse_dotenv(
      "this is not an assignment
=novalue
ENTRY_TIME=08:00",
    )
    == dict.from_list([#("ENTRY_TIME", "08:00")])
}

pub fn a_dotenv_reads_an_empty_value_as_empty_test() {
  // Config treats blank as missing, which is what makes `PUNCH_LIST_SELECTOR=`
  // in the example file fail loudly instead of silently.
  assert system.parse_dotenv("PUNCH_LIST_SELECTOR=")
    == dict.from_list([#("PUNCH_LIST_SELECTOR", "")])
}

pub fn a_dotenv_survives_windows_line_endings_test() {
  assert system.parse_dotenv("ENTRY_TIME=08:00\r\nEXIT_TIME=17:30\r\n")
    == dict.from_list([#("ENTRY_TIME", "08:00"), #("EXIT_TIME", "17:30")])
}

pub fn a_known_timezone_gives_a_moment_test() {
  let assert Ok(here) = system.now("America/Sao_Paulo")
  // Nothing to compare against but the clock itself; what matters is that the
  // parts survived validation, which the opaque types already guarantee.
  assert string.length(clock.date_to_string(here.date)) == 10
  assert string.length(clock.time_to_string(here.time)) == 5
}

pub fn distant_timezones_disagree_test() {
  let assert Ok(here) = system.now("America/Sao_Paulo")
  let assert Ok(there) = system.now("Asia/Tokyo")
  assert here != there
}

pub fn an_unknown_timezone_is_reported_test() {
  assert system.now("Mars/Olympus_Mons")
    == Error(system.UnknownTimezone("Mars/Olympus_Mons"))
}

pub fn a_log_line_reaches_a_writable_path_test() {
  // Inside build/, which is not tracked and is wiped by `gleam clean`.
  assert system.append_line("build/system_test.log", "hello") == Ok(Nil)
}

pub fn an_unwritable_path_is_reported_test() {
  let assert Error(system.WriteFailed(path:, ..)) =
    system.append_line("/proc/version/nope.log", "hello")
  assert path == "/proc/version/nope.log"
}

pub fn error_to_string_never_shows_a_path_it_was_not_given_test() {
  assert system.error_to_string(system.UnknownTimezone("Mars/Olympus_Mons"))
    == "unknown timezone Mars/Olympus_Mons"
  assert system.error_to_string(system.WriteFailed(
      path: "/var/log/acuttis.log",
      detail: "permission denied",
    ))
    == "could not write /var/log/acuttis.log: permission denied"
}
