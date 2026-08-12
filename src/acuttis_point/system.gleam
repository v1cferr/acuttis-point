//// The edges of the process: the environment, the clock, the log file and the
//// exit status.
////
//// Kept in one small module so the rest of `src` stays pure. The FFI returns
//// plain numbers and strings rather than Gleam values, which keeps the
//// JavaScript side free of any assumption about how Gleam represents things.

import acuttis_point/clock
import gleam/dict.{type Dict}
import gleam/javascript/array.{type Array}

pub type SystemError {
  /// The configured `TIMEZONE` is not one the runtime knows.
  UnknownTimezone(String)
  /// The clock produced a date or time that does not exist. Should not happen,
  /// but the alternative is trusting it blindly.
  ImpossibleClock(clock.ClockError)
  WriteFailed(path: String, detail: String)
}

pub fn environment() -> Dict(String, String) {
  environment_entries()
  |> array.to_list
  |> dict.from_list
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
  }
}

@external(javascript, "./system_ffi.mjs", "environmentEntries")
fn environment_entries() -> Array(#(String, String))

/// Year, month, day, hour and minute in the given zone, or nothing at all when
/// the zone is unknown. A list keeps the FFI to numbers only.
@external(javascript, "./system_ffi.mjs", "clockParts")
fn clock_parts(timezone: String) -> Array(Int)

/// Returns an empty string on success, the failure detail otherwise.
@external(javascript, "./system_ffi.mjs", "appendToFile")
fn append_to_file(path: String, text: String) -> String

/// Sets the status the process will exit with, rather than exiting now, so
/// buffered output still reaches the journal.
@external(javascript, "./system_ffi.mjs", "setExitStatus")
pub fn set_exit_status(status: Int) -> Nil
