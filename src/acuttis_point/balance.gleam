//// The month's hours: how much was worked, against how much was owed.
////
//// Arithmetic over the same markings the audit reads, and nothing more. Worth
//// being explicit about what that means, because the number is the sort of thing
//// one is tempted to quote at Gestão de Pessoas: this is not FAI's official
//// balance. Theirs may round, may treat a tolerance differently, may count
//// holidays or a Saturday in ways nothing here knows about. This says what the
//// markings on the receipt add up to, which is a good way to notice a month
//// drifting and a bad way to win an argument.
////
//// Only days with markings are counted, on both sides of the sum. A day off, a
//// holiday or leave has no markings and so contributes neither hours worked nor
//// hours owed — otherwise every day of vacation would read as a deficit. The
//// cost of that choice is that a day worked and never punched at all is
//// invisible here; the audit is what catches those.
////
//// Days whose markings do not pair up are excluded and counted separately. With
//// an odd number of markings the time worked cannot be computed without deciding
//// which one is missing, and deciding that would be inventing hours.

import acuttis_point/audit
import acuttis_point/clock
import gleam/int
import gleam/list

pub type DayHours {
  /// The markings pair up, and this is what they add up to.
  Measured(date: clock.Date, minutes: Int)
  /// The markings do not pair up, so the day cannot be measured at all.
  Unmeasurable(date: clock.Date, found: Int)
}

pub type Balance {
  Balance(
    year: Int,
    month: Int,
    /// The daily expectation used, so the number can be checked against the
    /// contract rather than trusted.
    daily_minutes: Int,
    measured: List(DayHours),
    unmeasurable: List(DayHours),
    worked_minutes: Int,
    owed_minutes: Int,
  )
}

/// The month of `now`, from the days the audit read.
///
/// Today is left out. It is either unfinished, in which case counting it would
/// invent a deficit that the afternoon will fill, or it is finished and tomorrow
/// will count it.
pub fn for_month(
  days days: List(audit.Day),
  now now: clock.Date,
  daily_minutes daily_minutes: Int,
) -> Balance {
  let this_month =
    days
    |> list.filter(fn(day) {
      clock.year(day.date) == clock.year(now)
      && clock.month(day.date) == clock.month(now)
      && day.date != now
    })
    |> list.map(measure)

  let measured =
    list.filter(this_month, fn(day) {
      case day {
        Measured(..) -> True
        Unmeasurable(..) -> False
      }
    })
  let unmeasurable =
    list.filter(this_month, fn(day) {
      case day {
        Unmeasurable(..) -> True
        Measured(..) -> False
      }
    })

  Balance(
    year: clock.year(now),
    month: clock.month(now),
    daily_minutes: daily_minutes,
    measured: measured,
    unmeasurable: unmeasurable,
    worked_minutes: list.fold(measured, 0, fn(total, day) {
      case day {
        Measured(minutes:, ..) -> total + minutes
        Unmeasurable(..) -> total
      }
    }),
    owed_minutes: list.length(measured) * daily_minutes,
  )
}

/// Worked minus owed. Positive is credit, negative is a debt.
pub fn difference(balance: Balance) -> Int {
  balance.worked_minutes - balance.owed_minutes
}

/// Signed, and always with a sign, so a zero balance cannot be mistaken for a
/// missing one.
pub fn signed(minutes: Int) -> String {
  case minutes < 0 {
    True -> "-" <> duration(-minutes)
    False -> "+" <> duration(minutes)
  }
}

pub fn duration(minutes: Int) -> String {
  int.to_string(minutes / 60) <> "h" <> pad(minutes % 60)
}

pub fn to_line(balance: Balance) -> String {
  "balance month="
  <> int.to_string(balance.year)
  <> "-"
  <> pad(balance.month)
  <> " days="
  <> int.to_string(list.length(balance.measured))
  <> " worked="
  <> duration(balance.worked_minutes)
  <> " owed="
  <> duration(balance.owed_minutes)
  <> " diff="
  <> signed(difference(balance))
  <> " daily="
  <> duration(balance.daily_minutes)
  <> " unmeasurable="
  <> int.to_string(list.length(balance.unmeasurable))
}

/// Consecutive markings, paired: in to out, then in to out again. An odd count
/// leaves one unpaired, and nothing here guesses which.
fn measure(day: audit.Day) -> DayHours {
  let found = list.length(day.times)
  case found % 2 {
    0 -> Measured(date: day.date, minutes: pairs(day.times))
    _ -> Unmeasurable(date: day.date, found: found)
  }
}

fn pairs(times: List(clock.TimeOfDay)) -> Int {
  case times {
    [start, end, ..rest] ->
      clock.minutes_between(from: start, to: end) + pairs(rest)
    _ -> 0
  }
}

fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
