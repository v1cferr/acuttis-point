//// The edges of the process: the environment, the clock, the log file and the
//// exit status.
////
//// Kept in one small module so the rest of `src` stays pure. The FFI returns
//// plain numbers and strings rather than Gleam values, which keeps the
//// JavaScript side free of any assumption about how Gleam represents things.

import acuttis_point/clock
import gleam/dict.{type Dict}
import gleam/javascript/array.{type Array}
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string

/// Where configuration was read from.
pub type Environment {
  Environment(
    values: Dict(String, String),
    /// The `.env` that contributed, when one did.
    dotenv: Result(String, Nil),
  )
}

pub type SystemError {
  /// The configured `TIMEZONE` is not one the runtime knows.
  UnknownTimezone(String)
  /// The clock produced a date or time that does not exist. Should not happen,
  /// but the alternative is trusting it blindly.
  ImpossibleClock(clock.ClockError)
  WriteFailed(path: String, detail: String)
  NotifyFailed(url: String, detail: String)
}

/// The process environment, with a `.env` file underneath it.
///
/// Real environment variables win over the file, always. A `.env` forgotten in
/// a working directory must not be able to override what systemd injected, and
/// in production there is no `.env` to read in the first place.
///
/// The file is `.env` unless `ENV_FILE` says otherwise.
pub fn environment() -> Environment {
  let from_process =
    environment_entries()
    |> array.to_list
    |> dict.from_list

  let path = case dict.get(from_process, "ENV_FILE") {
    Ok(configured) ->
      case string.trim(configured) {
        "" -> default_env_file
        trimmed -> trimmed
      }
    Error(Nil) -> default_env_file
  }

  let from_file = parse_dotenv(read_file(path))

  case dict.is_empty(from_file) {
    True -> Environment(values: from_process, dotenv: Error(Nil))
    False ->
      Environment(
        values: dict.merge(into: from_file, from: from_process),
        dotenv: Ok(path),
      )
  }
}

/// Parse a `.env`: one `KEY=value` per line, `#` comments, an optional `export`
/// prefix and optional surrounding quotes.
///
/// A line that is not an assignment is skipped rather than being an error: this
/// is a hand-edited file, and refusing to start over a stray line would be
/// worse than ignoring it. Values are trimmed, so a password with meaningful
/// leading or trailing spaces has to be quoted.
pub fn parse_dotenv(contents: String) -> Dict(String, String) {
  contents
  |> string.split(on: "\n")
  |> list.filter_map(parse_line)
  |> dict.from_list
}

fn parse_line(line: String) -> Result(#(String, String), Nil) {
  case string.trim(line) {
    "" -> Error(Nil)
    trimmed ->
      case string.starts_with(trimmed, "#") {
        True -> Error(Nil)
        False -> assignment(without_export(trimmed))
      }
  }
}

fn without_export(line: String) -> String {
  case string.starts_with(line, "export ") {
    True -> string.trim(string.drop_start(line, 7))
    False -> line
  }
}

fn assignment(line: String) -> Result(#(String, String), Nil) {
  case string.split_once(line, on: "=") {
    Error(Nil) -> Error(Nil)
    Ok(#(key, value)) ->
      case string.trim(key) {
        "" -> Error(Nil)
        name -> Ok(#(name, unquote(string.trim(value))))
      }
  }
}

fn unquote(value: String) -> String {
  case wrapped_in(value, "\"") || wrapped_in(value, "'") {
    True -> value |> string.drop_start(1) |> string.drop_end(1)
    False -> value
  }
}

fn wrapped_in(value: String, quote: String) -> Bool {
  string.length(value) >= 2
  && string.starts_with(value, quote)
  && string.ends_with(value, quote)
}

/// The current moment in `timezone`, so a schedule written in local time is
/// read in local time no matter how the host clock is set.
pub fn now(timezone: String) -> Result(clock.Instant, SystemError) {
  case array.to_list(clock_parts(timezone)) {
    [year, month, day, hour, minute] ->
      case
        clock.new_date(year: year, month: month, day: day),
        clock.new_time(hour: hour, minute: minute)
      {
        Ok(date), Ok(time) -> Ok(clock.Instant(date: date, time: time))
        Error(reason), _ -> Error(ImpossibleClock(reason))
        _, Error(reason) -> Error(ImpossibleClock(reason))
      }
    // An unknown timezone yields no parts at all.
    _ -> Error(UnknownTimezone(timezone))
  }
}

/// POST a notification, shaped the way ntfy reads one: title, priority and tags
/// as headers, the message as the body.
///
/// A failure here is returned rather than raised, because it must never change
/// the outcome of a run: the punch has already happened or not, and a message
/// that did not arrive does not change which.
pub fn notify(
  url url: String,
  title title: String,
  body body: String,
  priority priority: String,
  tags tags: String,
) -> Promise(Result(Nil, SystemError)) {
  post_notification(url, title, body, priority, tags)
  |> promise.map(fn(detail) {
    case detail {
      "" -> Ok(Nil)
      _ -> Error(NotifyFailed(url: url, detail: detail))
    }
  })
}

pub fn append_line(path: String, text: String) -> Result(Nil, SystemError) {
  case append_to_file(path, text <> "\n") {
    "" -> Ok(Nil)
    detail -> Error(WriteFailed(path: path, detail: detail))
  }
}

pub fn error_to_string(error: SystemError) -> String {
  case error {
    UnknownTimezone(timezone) -> "unknown timezone " <> timezone
    ImpossibleClock(_) -> "the system clock reported an impossible moment"
    WriteFailed(path:, detail:) -> "could not write " <> path <> ": " <> detail
    NotifyFailed(url:, detail:) -> "could not notify " <> url <> ": " <> detail
  }
}

const default_env_file = ".env"

@external(javascript, "./system_ffi.mjs", "environmentEntries")
fn environment_entries() -> Array(#(String, String))

/// The file's contents, or an empty string when there is nothing readable
/// there. A missing `.env` is the normal case in production, not a failure.
@external(javascript, "./system_ffi.mjs", "readFileOrEmpty")
fn read_file(path: String) -> String

/// Year, month, day, hour and minute in the given zone, or nothing at all when
/// the zone is unknown. A list keeps the FFI to numbers only.
@external(javascript, "./system_ffi.mjs", "clockParts")
fn clock_parts(timezone: String) -> Array(Int)

/// Returns an empty string on success, the failure detail otherwise.
@external(javascript, "./system_ffi.mjs", "appendToFile")
fn append_to_file(path: String, text: String) -> String

/// Same convention: an empty string means it arrived.
@external(javascript, "./system_ffi.mjs", "postNotification")
fn post_notification(
  url: String,
  title: String,
  body: String,
  priority: String,
  tags: String,
) -> Promise(String)

/// Sets the status the process will exit with, rather than exiting now, so
/// buffered output still reaches the journal.
@external(javascript, "./system_ffi.mjs", "setExitStatus")
pub fn set_exit_status(status: Int) -> Nil
