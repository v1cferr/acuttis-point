//// Reading the Acuttis punch receipt.
////
//// The receipt lists several days at once, newest first, one row per punch:
////
////     12/08/2026 Qua - 18:08
////     12/08/2026 Qua - 13:51
////     ...
////     11/08/2026 Ter - 17:37
////
//// So today's rows have to be picked out by date, and the times sorted. The
//// order the page happens to use is a presentation choice and does not belong
//// in a contract; sorting means a reversed list, or a redesign that reorders
//// them, changes nothing here.
////
//// That the receipt spans days buys a real safety property. A selector that
//// has silently stopped matching produces no rows at all, while a day that has
//// simply not started yet still produces the previous days' rows. The two are
//// therefore distinguishable, and only the second one is a day worth acting
//// on — which matters most in the entry window, the one moment where an empty
//// day and a broken selector would otherwise both say "punch".
////
//// Only the first page is read, which is twenty rows: the receipt loads more as
//// it is scrolled. Today is always on the first page, so scrolling would buy
//// nothing here — but it does mean the row count is not a measure of anything.

import acuttis_point/clock
import acuttis_point/punch
import acuttis_point/state
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

pub type ReadError {
  /// Not one row, on any day. The receipt always lists something, so this is a
  /// selector that stopped matching rather than a day that has not started.
  PunchListNotFound
  /// A row for today that holds no time.
  NoTimeIn(text: String)
  MorePunchesThanADayHas(found: Int)
}

/// Turn the text of every row on the receipt into the punches registered today.
pub fn read_punches(
  rows rows: List(String),
  today today: clock.Date,
) -> Result(List(state.Registered), ReadError) {
  case rows {
    [] -> Error(PunchListNotFound)
    _ -> today_only(rows, clock.date_to_dmy(today))
  }
}

pub fn error_to_string(error: ReadError) -> String {
  case error {
    PunchListNotFound ->
      "the punch receipt showed no rows at all, so the selector no longer"
      <> " matches; run with DISCOVER=true to find the new one"
    NoTimeIn(text:) -> "no time found in \"" <> text <> "\""
    MorePunchesThanADayHas(found:) ->
      "acuttis shows "
      <> int.to_string(found)
      <> " punches today, more than a day has"
  }
}

fn today_only(
  rows: List(String),
  stamp: String,
) -> Result(List(state.Registered), ReadError) {
  use times <- result.try(
    rows
    |> list.filter(string.contains(_, stamp))
    |> list.try_map(fn(row) {
      find_time(row)
      |> result.replace_error(NoTimeIn(row))
    }),
  )

  let found = list.length(times)
  case found > list.length(punch.sequence) {
    True -> Error(MorePunchesThanADayHas(found))
    False ->
      Ok(
        punch.sequence
        |> list.zip(list.sort(times, by: earliest_first))
        |> list.map(fn(pair) { state.Registered(punch: pair.0, at: pair.1) }),
      )
  }
}

fn earliest_first(a: clock.TimeOfDay, b: clock.TimeOfDay) -> order.Order {
  int.compare(clock.minutes_since_midnight(a), clock.minutes_since_midnight(b))
}

/// The first `HH:MM` in the row. Each row carries a date and a weekday around
/// the time, so this scans rather than parsing the whole string.
fn find_time(text: String) -> Result(clock.TimeOfDay, Nil) {
  scan(string.to_graphemes(text))
}

fn scan(graphemes: List(String)) -> Result(clock.TimeOfDay, Nil) {
  case graphemes {
    [] -> Error(Nil)
    [_, ..rest] ->
      case at_start(graphemes) {
        Ok(time) -> Ok(time)
        Error(Nil) -> scan(rest)
      }
  }
}

/// Exactly two digits, a colon, two digits. A looser reader would find a time
/// inside a duration or an identifier, and a time read wrong here becomes a
/// punch registered against the wrong event.
///
/// The digits are checked here rather than left to `parse_time`, which trims
/// its input: without this, the ` 8:03` inside `8:034` parses as 08:03 and the
/// trailing digit disappears.
fn at_start(graphemes: List(String)) -> Result(clock.TimeOfDay, Nil) {
  case graphemes {
    [hour_tens, hour_units, ":", minute_tens, minute_units, ..] ->
      case
        is_digit(hour_tens)
        && is_digit(hour_units)
        && is_digit(minute_tens)
        && is_digit(minute_units)
      {
        False -> Error(Nil)
        True ->
          clock.parse_time(
            hour_tens <> hour_units <> ":" <> minute_tens <> minute_units,
          )
          |> result.replace_error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}
