//// Reading the Acuttis punch list.
////
//// Acuttis lists the punches of the day in order, so the nth time on the page
//// is the nth punch of the sequence. That is the one assumption the automation
//// cannot check against the page itself, which is why a count it does not
//// expect is an error rather than a quiet truncation: reading four times as
//// three would make the next punch land in the wrong slot.

import acuttis_point/clock
import acuttis_point/punch
import acuttis_point/state
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type ReadError {
  /// A row was found where a punch should be, but it holds no time.
  NoTimeIn(text: String)
  MorePunchesThanADayHas(found: Int)
}

/// Turn the text of each punch row, in the order the page shows them, into
/// registered punches.
pub fn read_punches(
  texts: List(String),
) -> Result(List(state.Registered), ReadError) {
  use times <- result.try(
    list.try_map(texts, fn(text) {
      find_time(text)
      |> result.replace_error(NoTimeIn(text))
    }),
  )

  let found = list.length(times)
  case found > list.length(punch.sequence) {
    True -> Error(MorePunchesThanADayHas(found))
    False ->
      Ok(
        punch.sequence
        |> list.zip(times)
        |> list.map(fn(pair) { state.Registered(punch: pair.0, at: pair.1) }),
      )
  }
}

pub fn error_to_string(error: ReadError) -> String {
  case error {
    NoTimeIn(text:) -> "no time found in \"" <> text <> "\""
    MorePunchesThanADayHas(found:) ->
      "acuttis shows "
      <> int.to_string(found)
      <> " punches, more than a day has"
  }
}

/// The first `HH:MM` in the text. Rows tend to carry a label or a date around
/// the time, so this scans rather than parses the whole string.
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
fn at_start(graphemes: List(String)) -> Result(clock.TimeOfDay, Nil) {
  case graphemes {
    [hour_tens, hour_units, ":", minute_tens, minute_units, ..] ->
      clock.parse_time(
        hour_tens <> hour_units <> ":" <> minute_tens <> minute_units,
      )
      |> result.replace_error(Nil)
    _ -> Error(Nil)
  }
}
