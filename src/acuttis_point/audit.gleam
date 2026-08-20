//// How many days do not add up, and which.
////
//// Gestão de Pessoas notices these before I do. Their e-mails name a date and a
//// punch — "05/08/2026 - Retorno do almoço" — and ask what time it happened,
//// which means the day is already closed and the answer has to be reconstructed
//// from memory. The point of auditing is to find those days while the answer is
//// still today's.
////
//// A full day is four markings: in, out for lunch, back from lunch, out. But
//// four is not the test, and finding that out is the reason this module exists
//// in the shape it does. A first version flagged every day without four, which
//// meant flagging 16/06 (12:35 to 15:35), 24/06 and 29/06 — days of three, four
//// and five hours, on which two markings are exactly right. Brazilian law
//// requires the break on a working day over six hours, so a short day has no
//// break to record and no punch missing.
////
//// So what is judged is whether the markings pair up, and whether a day long
//// enough to need a break has one. An odd count is always wrong: somebody left
//// without coming back. More than four means one was made twice, which is what
//// happens when a hand and a timer both reach for the same punch — that is how
//// 2026-08-19 ended with five.
////
//// Days with no markings at all are deliberately NOT judged here. A blank
//// working day is as likely to be leave, a holiday or a trip as a forgotten
//// one, and this has no way to tell those apart; guessing would produce an
//// e-mail to Gestão de Pessoas about a day off.

import acuttis_point/acuttis
import acuttis_point/clock
import gleam/int
import gleam/list
import gleam/order
import gleam/string

pub type Verdict {
  /// The markings pair up and the day needed no break it does not have.
  Complete
  /// A marking is missing: either the count is odd, so somebody left without
  /// coming back, or the day was long enough to need a break and has none.
  /// Which marking is missing is not stated — with an even count that is
  /// genuinely ambiguous from here.
  Missing(found: Int)
  /// More than four: a marking made twice.
  Extra(found: Int)
  /// Today, and the day is not over yet.
  InProgress(found: Int)
}

pub type Day {
  Day(date: clock.Date, times: List(clock.TimeOfDay), verdict: Verdict)
}

pub type Audit {
  Audit(
    /// Every day the receipt showed, newest first, however it read.
    days: List(Day),
    /// Just the ones worth an e-mail, newest first.
    inconsistent: List(Day),
  )
}

/// A full day, in markings.
pub const punches_per_day = 4

/// Above this, the day legally needs a break, so a day of two markings is a day
/// with a break missing. At or below it, two markings are the whole day. Six
/// hours is the threshold in Brazilian law, and one hour is the minimum break it
/// then requires — which is why `MIN_LUNCH_MINUTES` exists elsewhere.
pub const long_day_minutes = 360

/// Group the receipt's rows by date and judge each day.
///
/// Rows that carry no date and time are dropped rather than failing the audit: a
/// heading or a stray element is not a punch, and refusing to report anything
/// because of one unexpected row would be the wrong trade.
pub fn audit(rows rows: List(String), today today: clock.Date) -> Audit {
  let days =
    rows
    |> list.filter_map(acuttis.read_row)
    |> group_by_date
    |> list.map(judge(_, today))
    |> list.sort(by: newest_first)

  Audit(days: days, inconsistent: list.filter(days, is_inconsistent))
}

/// Never judge the oldest day the receipt showed.
///
/// A page boundary can fall inside a day, and a day read half way looks like a
/// short day rather than an incomplete one — or the reverse. Seen on 16/06,
/// which a truncated read showed as two markings and called complete, and a full
/// read showed as three.
///
/// This applies to every read, not only a truncated one, and that correction
/// came from 26/05: the receipt ends there, about three months back, which is far
/// more likely to be as far as Acuttis serves than the first day of anyone's
/// employment. "The list stopped growing" cannot tell those apart, so the last
/// day visible is always a day that might be cut off.
///
/// One day never judged is the price. It buys never writing to Gestão de Pessoas
/// about a day that only looks wrong because we could not see all of it. The day
/// stays in `days`, so the count and the coverage still report it — it is the
/// findings it stays out of.
pub fn ignoring_the_boundary(audited: Audit) -> Audit {
  case list.last(audited.days) {
    Error(Nil) -> audited
    Ok(oldest) ->
      Audit(
        ..audited,
        inconsistent: list.filter(audited.inconsistent, fn(day) {
          day.date != oldest.date
        }),
      )
  }
}

pub fn is_inconsistent(day: Day) -> Bool {
  case day.verdict {
    Missing(_) | Extra(_) -> True
    Complete | InProgress(_) -> False
  }
}

/// The oldest and newest day the receipt showed, so a read that did not go as
/// far back as usual is visible rather than passing for a clean audit.
pub fn covered(audited: Audit) -> Result(#(clock.Date, clock.Date), Nil) {
  case audited.days, list.last(audited.days) {
    [newest, ..], Ok(oldest) -> Ok(#(oldest.date, newest.date))
    _, _ -> Error(Nil)
  }
}

/// One line per day, for the log. The dates are in the form the receipt and the
/// e-mails use, so a line can be pasted into a reply as it stands.
pub fn to_line(day: Day) -> String {
  clock.date_to_dmy(day.date)
  <> " "
  <> verdict_to_string(day.verdict)
  <> " "
  <> times_to_string(day.times)
}

pub fn verdict_to_string(verdict: Verdict) -> String {
  case verdict {
    Complete -> "COMPLETE"
    Missing(found:) -> "MISSING(" <> int.to_string(found) <> "/4)"
    Extra(found:) -> "EXTRA(" <> int.to_string(found) <> "/4)"
    InProgress(found:) -> "IN_PROGRESS(" <> int.to_string(found) <> "/4)"
  }
}

pub fn times_to_string(times: List(clock.TimeOfDay)) -> String {
  times
  |> list.map(clock.time_to_string)
  |> string.join(" ")
}

fn judge(
  entry: #(clock.Date, List(clock.TimeOfDay)),
  today: clock.Date,
) -> Day {
  let #(date, times) = entry
  let sorted = list.sort(times, by: earliest_first)
  let found = list.length(sorted)

  let verdict = case date == today && found < punches_per_day {
    // Today is allowed to be unfinished; that is what the rest of this program
    // is for.
    True -> InProgress(found)
    False -> judge_closed(sorted, found)
  }

  Day(date: date, times: sorted, verdict: verdict)
}

/// A day that is over.
fn judge_closed(times: List(clock.TimeOfDay), found: Int) -> Verdict {
  case int.compare(found, punches_per_day) {
    // More than a full day. Five is odd as well as too many, and "one too many"
    // is the useful half of that: it is what a double punch leaves behind, and
    // what the correction has to remove.
    order.Gt -> Extra(found)
    order.Eq -> Complete
    order.Lt ->
      case found % 2 {
        // Odd: somebody left and did not come back.
        1 -> Missing(found)
        // Two markings. Right for a short day, and a missing break on a long
        // one. Nothing else can be said without knowing which it was.
        _ ->
          case span(times) > long_day_minutes {
            True -> Missing(found)
            False -> Complete
          }
      }
  }
}

/// First marking to last, in minutes. Zero for a day with fewer than two, which
/// cannot be long by definition.
fn span(times: List(clock.TimeOfDay)) -> Int {
  case times, list.last(times) {
    [first, ..], Ok(last) -> clock.minutes_between(from: first, to: last)
    _, _ -> 0
  }
}

fn group_by_date(
  rows: List(#(clock.Date, clock.TimeOfDay)),
) -> List(#(clock.Date, List(clock.TimeOfDay))) {
  list.fold(rows, [], fn(days, row) {
    let #(date, time) = row
    case list.key_find(days, date) {
      Ok(times) -> list.key_set(days, date, [time, ..times])
      Error(Nil) -> [#(date, [time]), ..days]
    }
  })
}

fn newest_first(a: Day, b: Day) -> order.Order {
  int.compare(stamp(b.date), stamp(a.date))
}

fn stamp(date: clock.Date) -> Int {
  clock.year(date) * 10_000 + clock.month(date) * 100 + clock.day(date)
}

fn earliest_first(a: clock.TimeOfDay, b: clock.TimeOfDay) -> order.Order {
  int.compare(clock.minutes_since_midnight(a), clock.minutes_since_midnight(b))
}
