//// Today's timekeeping state, derived from the punches Acuttis reports.
////
//// A legitimate day is always a prefix of `punch.sequence` with
//// non-decreasing timestamps. Anything else is an inconsistency, and the
//// automation refuses to act on it rather than guessing what the user meant.

import acuttis_point/clock
import acuttis_point/punch
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// A punch Acuttis already has on record, with the time it shows.
pub type Registered {
  Registered(punch: punch.Punch, at: clock.TimeOfDay)
}

pub type DayState {
  /// Every punch before this one is registered; this one is still missing.
  Waiting(punch.Punch)
  /// All four punches of the day are registered.
  Completed
  /// What Acuttis shows is not a valid partial day.
  Invalid(Inconsistency)
}

pub type Inconsistency {
  /// A punch showed up where the sequence expects a different one.
  OutOfOrder(expected: punch.Punch, found: punch.Punch)
  /// A punch beyond the four a day can hold.
  ExtraPunch(punch.Punch)
  /// More markings than a day has slots for, so which punch each one is cannot
  /// be worked out at all. What produces this is a punch made twice — a hand and
  /// a timer both reaching for the same one.
  MoreMarkingsThanADay(found: Int)
  /// A punch timestamped before the one preceding it.
  TimeWentBackwards(
    punch: punch.Punch,
    at: clock.TimeOfDay,
    previous: clock.TimeOfDay,
  )
}

/// Fold the registered punches, in the order Acuttis lists them, into a state.
pub fn from_punches(registered: List(Registered)) -> DayState {
  case walk(registered, punch.sequence, None) {
    Error(inconsistency) -> Invalid(inconsistency)
    Ok([]) -> Completed
    Ok([missing, ..]) -> Waiting(missing)
  }
}

/// Whether `target` is already on record. Only meaningful for a valid state,
/// so `Invalid` reports `False` and callers are expected to handle it first.
pub fn is_registered(state: DayState, target: punch.Punch) -> Bool {
  case state {
    Completed -> True
    Waiting(missing) -> punch.position(target) < punch.position(missing)
    Invalid(_) -> False
  }
}

/// The time Acuttis shows for `target`, when it is on record.
pub fn registered_at(
  registered: List(Registered),
  target: punch.Punch,
) -> Result(clock.TimeOfDay, Nil) {
  registered
  |> list.find(fn(entry) { entry.punch == target })
  |> result.map(fn(entry) { entry.at })
}

/// Short description for the `Current state` field of a run record.
pub fn to_string(state: DayState) -> String {
  case state {
    Waiting(missing) -> "WAITING(" <> punch.to_string(missing) <> ")"
    Completed -> "COMPLETED"
    Invalid(inconsistency) ->
      "INVALID(" <> inconsistency_to_string(inconsistency) <> ")"
  }
}

pub fn inconsistency_to_string(inconsistency: Inconsistency) -> String {
  case inconsistency {
    OutOfOrder(expected:, found:) ->
      "expected "
      <> punch.to_string(expected)
      <> " but found "
      <> punch.to_string(found)
    MoreMarkingsThanADay(found:) ->
      "acuttis shows "
      <> int.to_string(found)
      <> " markings today, more than a day has slots for"
    ExtraPunch(extra) ->
      "punch " <> punch.to_string(extra) <> " beyond a complete day"
    TimeWentBackwards(punch: target, at:, previous:) ->
      punch.to_string(target)
      <> " at "
      <> clock.time_to_string(at)
      <> " precedes "
      <> clock.time_to_string(previous)
  }
}

/// Render the registered punches the way they will appear in a log line.
pub fn registered_to_string(registered: List(Registered)) -> String {
  case registered {
    [] -> "none"
    _ ->
      registered
      |> list.map(fn(entry) {
        punch.to_string(entry.punch) <> "@" <> clock.time_to_string(entry.at)
      })
      |> string.join(", ")
  }
}

/// Consume the registered punches against the expected sequence, returning
/// whatever is still missing.
fn walk(
  registered: List(Registered),
  expected: List(punch.Punch),
  previous: Option(clock.TimeOfDay),
) -> Result(List(punch.Punch), Inconsistency) {
  case registered, expected {
    [], missing -> Ok(missing)
    [first, ..], [] -> Error(ExtraPunch(first.punch))
    [first, ..rest], [next, ..remaining] -> {
      use _ <- result.try(check_order(first, next))
      use _ <- result.try(check_not_backwards(first, previous))
      walk(rest, remaining, Some(first.at))
    }
  }
}

fn check_order(
  found: Registered,
  expected: punch.Punch,
) -> Result(Nil, Inconsistency) {
  case found.punch == expected {
    True -> Ok(Nil)
    False -> Error(OutOfOrder(expected: expected, found: found.punch))
  }
}

fn check_not_backwards(
  found: Registered,
  previous: Option(clock.TimeOfDay),
) -> Result(Nil, Inconsistency) {
  case previous {
    None -> Ok(Nil)
    Some(previous_at) ->
      case clock.minutes_between(from: previous_at, to: found.at) < 0 {
        True ->
          Error(TimeWentBackwards(
            punch: found.punch,
            at: found.at,
            previous: previous_at,
          ))
        False -> Ok(Nil)
      }
  }
}
