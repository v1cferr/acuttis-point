//// Calendar and wall-clock primitives.
////
//// `TimeOfDay` is opaque on purpose: an out-of-range hour or a malformed
//// configuration value cannot reach the decision rules, because every way of
//// building one validates first.

import gleam/int
import gleam/list
import gleam/string

pub type Weekday {
  Monday
  Tuesday
  Wednesday
  Thursday
  Friday
  Saturday
  Sunday
}

pub type ClockError {
  HourOutOfRange(Int)
  MinuteOutOfRange(Int)
  MalformedTime(String)
  UnknownWeekday(String)
  YearOutOfRange(Int)
  MonthOutOfRange(Int)
  DayOutOfRange(Int)
  MalformedDate(String)
}

/// A wall-clock time inside a single day, held as minutes since midnight.
pub opaque type TimeOfDay {
  TimeOfDay(minutes: Int)
}

/// A calendar day. Opaque for the same reason as `TimeOfDay`: the ranges are
/// checked once at the edge, so `weekday` can never be handed a 13th month.
pub opaque type Date {
  Date(year: Int, month: Int, day: Int)
}

/// A moment in the configured timezone: the calendar day plus the time on it.
pub type Instant {
  Instant(date: Date, time: TimeOfDay)
}

pub fn new_time(
  hour hour: Int,
  minute minute: Int,
) -> Result(TimeOfDay, ClockError) {
  case hour < 0 || hour > 23 {
    True -> Error(HourOutOfRange(hour))
    False ->
      case minute < 0 || minute > 59 {
        True -> Error(MinuteOutOfRange(minute))
        False -> Ok(TimeOfDay(hour * 60 + minute))
      }
  }
}

/// Parse the `HH:MM` form used by every time in the configuration.
pub fn parse_time(raw: String) -> Result(TimeOfDay, ClockError) {
  case string.split(string.trim(raw), on: ":") {
    [hour, minute] ->
      case int.parse(hour), int.parse(minute) {
        Ok(hour), Ok(minute) -> new_time(hour: hour, minute: minute)
        _, _ -> Error(MalformedTime(raw))
      }
    _ -> Error(MalformedTime(raw))
  }
}

pub fn new_date(
  year year: Int,
  month month: Int,
  day day: Int,
) -> Result(Date, ClockError) {
  case year < 1 {
    True -> Error(YearOutOfRange(year))
    False ->
      case month < 1 || month > 12 {
        True -> Error(MonthOutOfRange(month))
        False ->
          case day < 1 || day > days_in_month(year: year, month: month) {
            True -> Error(DayOutOfRange(day))
            False -> Ok(Date(year: year, month: month, day: day))
          }
      }
  }
}

/// Parse the `YYYY-MM-DD` form used by `SKIP_DATES` and by log records.
pub fn parse_date(raw: String) -> Result(Date, ClockError) {
  case string.split(string.trim(raw), on: "-") {
    [year, month, day] ->
      case int.parse(year), int.parse(month), int.parse(day) {
        Ok(year), Ok(month), Ok(day) ->
          new_date(year: year, month: month, day: day)
        _, _, _ -> Error(MalformedDate(raw))
      }
    _ -> Error(MalformedDate(raw))
  }
}

pub fn year(date: Date) -> Int {
  date.year
}

pub fn month(date: Date) -> Int {
  date.month
}

pub fn day(date: Date) -> Int {
  date.day
}

pub fn is_leap_year(year: Int) -> Bool {
  year % 4 == 0 && { year % 100 != 0 || year % 400 == 0 }
}

pub fn days_in_month(year year: Int, month month: Int) -> Int {
  case month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    4 | 6 | 9 | 11 -> 30
    2 ->
      case is_leap_year(year) {
        True -> 29
        False -> 28
      }
    _ -> 0
  }
}

pub fn hour(time: TimeOfDay) -> Int {
  time.minutes / 60
}

pub fn minute(time: TimeOfDay) -> Int {
  time.minutes % 60
}

pub fn minutes_since_midnight(time: TimeOfDay) -> Int {
  time.minutes
}

/// Minutes from `from` to `to`, negative when `to` is earlier in the day.
pub fn minutes_between(from from: TimeOfDay, to to: TimeOfDay) -> Int {
  to.minutes - from.minutes
}

/// Render as zero padded `HH:MM`, the same shape the configuration uses.
pub fn time_to_string(time: TimeOfDay) -> String {
  pad(hour(time)) <> ":" <> pad(minute(time))
}

pub fn date_to_string(date: Date) -> String {
  int.to_string(date.year) <> "-" <> pad(date.month) <> "-" <> pad(date.day)
}

/// Sakamoto's algorithm. Deriving the weekday here keeps it pure and testable
/// instead of trusting the JavaScript side for one more thing.
pub fn weekday(date: Date) -> Weekday {
  let month_offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  let offset = case list.drop(month_offsets, date.month - 1) {
    [offset, ..] -> offset
    [] -> 0
  }
  // January and February belong to the previous year's leap cycle.
  let year = case date.month < 3 {
    True -> date.year - 1
    False -> date.year
  }
  let index =
    { year + year / 4 - year / 100 + year / 400 + offset + date.day } % 7
  case index {
    0 -> Sunday
    1 -> Monday
    2 -> Tuesday
    3 -> Wednesday
    4 -> Thursday
    5 -> Friday
    _ -> Saturday
  }
}

pub fn weekday_to_string(day: Weekday) -> String {
  case day {
    Monday -> "MON"
    Tuesday -> "TUE"
    Wednesday -> "WED"
    Thursday -> "THU"
    Friday -> "FRI"
    Saturday -> "SAT"
    Sunday -> "SUN"
  }
}

/// Parse the three letter codes accepted by `WORK_DAYS`.
pub fn parse_weekday(raw: String) -> Result(Weekday, ClockError) {
  case string.uppercase(string.trim(raw)) {
    "MON" -> Ok(Monday)
    "TUE" -> Ok(Tuesday)
    "WED" -> Ok(Wednesday)
    "THU" -> Ok(Thursday)
    "FRI" -> Ok(Friday)
    "SAT" -> Ok(Saturday)
    "SUN" -> Ok(Sunday)
    _ -> Error(UnknownWeekday(raw))
  }
}

fn pad(value: Int) -> String {
  value
  |> int.to_string
  |> string.pad_start(to: 2, with: "0")
}
