import acuttis_point/clock
import acuttis_point/system
import gleam/dict
import gleam/string

pub fn the_environment_is_readable_test() {
  let env = system.environment()
  // Set by the Nix dev shell, and the reason the Playwright adapter can find
  // its browsers at all.
  assert dict.has_key(env, "PLAYWRIGHT_BROWSERS_PATH")
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
