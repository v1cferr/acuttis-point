//// The hour bank, by FAI's rules rather than by arithmetic of my own.
////
//// An earlier version of this module summed the worked minutes and subtracted a
//// nominal day. That is not how the bank works, and the difference is not small:
//// it counted every stray minute, measured against the schedule instead of the
//// contract, and reported August as 1h22 in debt when the same markings were
//// 2h33 in credit.
////
//// The rules, from FAI's own sheet ("Sistema de ponto Eletrônico") and confirmed
//// against the folha for July 2026, which this module reproduces to the minute:
////
////   1. worked = the paired intervals of the day
////   2. a lunch break under an hour has its shortfall deducted
////   3. deviation = worked, net, minus the contractual day
////   4. a deviation of ten minutes or less does not reach the bank at all —
////      "qualquer registro, seja positivo ou negativo, só será considerado após
////      o décimo primeiro minuto"
////   5. past that, the whole deviation is banked, not the part above ten
////
//// Rule 4 is the one that is easy to get wrong in both directions. Ten minutes
//// exactly is nothing (24/07: 8h10 worked, no credit). Eleven is eleven, not one.
////
//// Rule 2 is why 30/07 was credited thirty minutes and not thirty-seven: a lunch
//// of fifty-three minutes cost the seven it was short.
////
//// What this still cannot see is Gestão de Pessoas' adjustments, which by their
//// own document never appear in the history. So a day they have corrected still
//// reads here as it was punched, and this number stays a floor.

import acuttis_point/audit
import acuttis_point/clock
import gleam/int
import gleam/list

/// FAI's rule on consecutive work: no period may exceed five hours. Monitored by
/// the coordinator rather than enforced by the system — 27/07 (5h01) and 30/07
/// (5h03) were both credited in full — so this is reported, never deducted.
pub const max_consecutive_minutes = 300

/// Compensation a single weekday may carry, past which it needs authorisation.
pub const max_daily_compensation_minutes = 120

pub type DayHours {
  Measured(
    date: clock.Date,
    /// The paired intervals, before any deduction.
    gross_minutes: Int,
    /// Deducted because the break was under the minimum.
    shortfall_minutes: Int,
    /// The break actually taken, or zero on a day with a single pair.
    lunch_minutes: Int,
    /// Net worked minus the contractual day. Signed, and not yet the bank.
    deviation_minutes: Int,
    /// What reaches the bank: the whole deviation, or nothing when it is inside
    /// the tolerance.
    banked_minutes: Int,
    /// The longest stretch without a break.
    longest_stretch_minutes: Int,
  )
  /// The markings do not pair up, so nothing about the day can be computed
  /// without deciding which one is missing — and deciding that invents hours.
  Unmeasurable(date: clock.Date, found: Int)
}

pub type Balance {
  Balance(
    year: Int,
    month: Int,
    daily_minutes: Int,
    tolerance_minutes: Int,
    min_lunch_minutes: Int,
    measured: List(DayHours),
    unmeasurable: List(DayHours),
    /// The most the bank may hold either way: FAI's limite de compensação.
    limit_minutes: Int,
  )
}

/// `month_of` picks the month to report; `today` is the day left out of it.
///
/// Two parameters rather than one, because they are two questions. In production
/// both are the same date, but reporting July while today is in August is the
/// only way to check this module against the folha July produced.
pub fn for_month(
  days days: List(audit.Day),
  month_of month_of: clock.Date,
  today today: clock.Date,
  daily_minutes daily_minutes: Int,
  tolerance_minutes tolerance_minutes: Int,
  min_lunch_minutes min_lunch_minutes: Int,
  limit_minutes limit_minutes: Int,
) -> Balance {
  let judged =
    days
    |> list.filter(fn(day) {
      clock.year(day.date) == clock.year(month_of)
      && clock.month(day.date) == clock.month(month_of)
      // Today is left out: unfinished, it would invent a debt the afternoon
      // fills.
      && day.date != today
    })
    |> list.map(measure(_, daily_minutes, tolerance_minutes, min_lunch_minutes))

  Balance(
    year: clock.year(month_of),
    month: clock.month(month_of),
    daily_minutes: daily_minutes,
    tolerance_minutes: tolerance_minutes,
    min_lunch_minutes: min_lunch_minutes,
    measured: list.filter(judged, is_measured),
    unmeasurable: list.filter(judged, fn(day) { !is_measured(day) }),
    limit_minutes: limit_minutes,
  )
}

/// Everything banked upwards, in minutes. FAI's "Banco Horas Créd".
pub fn credit(balance: Balance) -> Int {
  banked(balance) |> list.filter(fn(one) { one > 0 }) |> sum
}

/// Everything banked downwards, positive. FAI's "Banco Horas Déb".
pub fn debit(balance: Balance) -> Int {
  banked(balance) |> list.filter(fn(one) { one < 0 }) |> sum |> int.negate
}

/// Credit minus debit: the month's movement in the bank.
pub fn difference(balance: Balance) -> Int {
  credit(balance) - debit(balance)
}

/// Worked minutes, net of any shortfall. Not the bank — the hours themselves.
pub fn worked_minutes(balance: Balance) -> Int {
  balance.measured
  |> list.map(fn(day) {
    case day {
      Measured(gross_minutes:, shortfall_minutes:, ..) ->
        gross_minutes - shortfall_minutes
      Unmeasurable(..) -> 0
    }
  })
  |> sum
}

/// How much of the compensation limit this month has not used.
///
/// This month only. The limit is on the bank as a whole and the bank runs
/// further back than the receipt serves, so this is a floor on the room left
/// rather than the answer. The folha is the answer.
pub fn room_left(balance: Balance) -> Int {
  let used = int.absolute_value(difference(balance))
  int.max(0, balance.limit_minutes - used)
}

/// Days that broke a rule other than the hours themselves: more than five
/// consecutive hours, or more compensation in one day than a weekday may carry.
/// Both are reported and neither is deducted, because FAI's own sheet treats them
/// as monitored rather than automatic.
pub fn irregular(balance: Balance) -> List(DayHours) {
  list.filter(balance.measured, fn(day) {
    case day {
      Measured(longest_stretch_minutes:, banked_minutes:, ..) ->
        longest_stretch_minutes > max_consecutive_minutes
        || int.absolute_value(banked_minutes) > max_daily_compensation_minutes
      Unmeasurable(..) -> False
    }
  })
}

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
  <> duration(worked_minutes(balance))
  <> " credit="
  <> duration(credit(balance))
  <> " debit="
  <> duration(debit(balance))
  <> " balance="
  <> signed(difference(balance))
  <> " daily="
  <> duration(balance.daily_minutes)
  <> " unmeasurable="
  <> int.to_string(list.length(balance.unmeasurable))
  <> " irregular="
  <> int.to_string(list.length(irregular(balance)))
  <> " limit="
  <> duration(balance.limit_minutes)
}

/// What each measured day put into the bank, signed.
fn banked(balance: Balance) -> List(Int) {
  list.map(balance.measured, fn(day) {
    case day {
      Measured(banked_minutes:, ..) -> banked_minutes
      Unmeasurable(..) -> 0
    }
  })
}

fn measure(
  day: audit.Day,
  daily_minutes: Int,
  tolerance_minutes: Int,
  min_lunch_minutes: Int,
) -> DayHours {
  let found = list.length(day.times)

  case found % 2 {
    1 -> Unmeasurable(date: day.date, found: found)
    _ -> {
      let stretches = pairs(day.times)
      let gross = sum(stretches)
      let lunch = break_between(day.times)
      // A break shorter than the minimum costs what it was short. This is the
      // rule that explains 30/07: fifty three minutes of lunch, seven deducted.
      let shortfall = case lunch > 0 {
        True -> int.max(0, min_lunch_minutes - lunch)
        False -> 0
      }
      let deviation = gross - shortfall - daily_minutes

      Measured(
        date: day.date,
        gross_minutes: gross,
        shortfall_minutes: shortfall,
        lunch_minutes: lunch,
        deviation_minutes: deviation,
        // Inside the tolerance nothing is banked at all, in either direction.
        // Past it, the whole deviation is — not the part above the tolerance.
        banked_minutes: case
          int.absolute_value(deviation) <= tolerance_minutes
        {
          True -> 0
          False -> deviation
        },
        longest_stretch_minutes: list.fold(stretches, 0, int.max),
      )
    }
  }
}

/// The gap between the first pair and the second. Zero for a day of one pair,
/// which has no break to be short.
fn break_between(times: List(clock.TimeOfDay)) -> Int {
  case times {
    [_, out, back, ..] -> clock.minutes_between(from: out, to: back)
    _ -> 0
  }
}

/// Consecutive markings, paired: in to out, then in to out again.
fn pairs(times: List(clock.TimeOfDay)) -> List(Int) {
  case times {
    [start, end, ..rest] -> [
      clock.minutes_between(from: start, to: end),
      ..pairs(rest)
    ]
    _ -> []
  }
}

fn is_measured(day: DayHours) -> Bool {
  case day {
    Measured(..) -> True
    Unmeasurable(..) -> False
  }
}

fn sum(values: List(Int)) -> Int {
  list.fold(values, 0, int.add)
}

fn pad(value: Int) -> String {
  case value < 10 {
    True -> "0" <> int.to_string(value)
    False -> int.to_string(value)
  }
}
