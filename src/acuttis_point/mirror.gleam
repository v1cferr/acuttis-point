//// A copy of the receipt that outlives it.
////
//// Acuttis shows a rolling window — on 2026-10-16 it reached back to 30/07 —
//// and once a day falls off the end it survives in exactly one place: the PDF
//// folha Gestão de Pessoas issues monthly. Answering "what time did I leave on
//// the fifth of May" then means opening a PDF, and it means being able to
//// answer only the months somebody remembered to download.
////
//// So every audit writes down what it read. It is a copy and never a source:
//// Acuttis decides what is true, and where the two disagree this one is wrong.
//// Nothing in the punch path reads it and nothing decides anything by it, so a
//// mirror that fails costs a line in the log and no punch.
////
//// What it cannot give back is FAI's own arithmetic. Their adjustments never
//// reach the history — their own document says so — so the markings are
//// recoverable from here and a month's closing balance is not.

import acuttis_point/audit
import acuttis_point/clock
import gleam/int
import gleam/list
import gleam/result

pub type Mirrored {
  Mirrored(days: Int, markings: Int, oldest: clock.Date, newest: clock.Date)
}

pub type Outcome {
  Copied(Mirrored)
  /// The receipt could not be read, or showed nothing worth keeping. Not a
  /// failure: an audit that found no history has none to copy.
  NothingToCopy
  Failed(detail: String)
}

/// The days worth copying.
///
/// Everything the receipt showed, less the oldest when the scrolling ran out
/// before the receipt did. A page boundary can fall inside a day, and half a
/// day written down is worse than a day missing — the half looks whole, and it
/// looks exactly like the short day that means somebody forgot to punch.
pub fn worth_copying(
  audited audited: audit.Audit,
  exhausted exhausted: Bool,
) -> List(audit.Day) {
  case exhausted, list.last(audited.days) {
    True, _ | _, Error(Nil) -> audited.days
    False, Ok(oldest) ->
      list.filter(audited.days, fn(day) { day.date != oldest.date })
  }
}

/// What a copy of these days would amount to. `Error(Nil)` when there are none.
pub fn summarise(days: List(audit.Day)) -> Result(Mirrored, Nil) {
  // The receipt reads newest first, and so does this list.
  use newest <- result.try(list.first(days))
  use oldest <- result.try(list.last(days))

  Ok(Mirrored(
    days: list.length(days),
    markings: list.fold(days, 0, fn(total, day) {
      total + list.length(day.times)
    }),
    oldest: oldest.date,
    newest: newest.date,
  ))
}

/// Write those days down, replacing whatever was held for each of them.
///
/// Replacing rather than adding, because Gestão de Pessoas corrects days. A
/// time they moved would otherwise leave both the old and the new behind, and
/// a marking they deleted would never leave at all — and a day with one
/// marking too many is the exact shape of the bug this whole project was built
/// to stop.
///
/// Only the days the receipt actually showed are touched. Everything older
/// stays as it was last seen, which is the entire point.
pub fn record(
  path path: String,
  days days: List(audit.Day),
  at at: clock.Instant,
) -> Outcome {
  case summarise(days) {
    Error(Nil) -> NothingToCopy
    Ok(summary) ->
      case ffi_replace_days(path, rows(days), stamp(at)) {
        "" -> Copied(summary)
        problem -> Failed(problem)
      }
  }
}

pub fn to_line(outcome: Outcome) -> String {
  case outcome {
    NothingToCopy -> "mirror=skipped"
    Failed(detail:) -> "mirror=FAILED detail=\"" <> detail <> "\""
    Copied(kept) ->
      "mirror=ok days="
      <> int.to_string(kept.days)
      <> " markings="
      <> int.to_string(kept.markings)
      <> " covering="
      <> clock.date_to_string(kept.oldest)
      <> ".."
      <> clock.date_to_string(kept.newest)
  }
}

fn rows(days: List(audit.Day)) -> List(#(String, List(String))) {
  list.map(days, fn(day) {
    #(clock.date_to_string(day.date), list.map(day.times, clock.time_to_string))
  })
}

fn stamp(at: clock.Instant) -> String {
  clock.date_to_string(at.date) <> " " <> clock.time_to_string(at.time)
}

@external(javascript, "./mirror_ffi.mjs", "replaceDays")
fn ffi_replace_days(
  path: String,
  days: List(#(String, List(String))),
  at: String,
) -> String
