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
////
//// The forty hour limit, though, is about the whole bank and not about one
//// month, and the bank runs further back than the receipt reaches. So the months
//// before this one arrive as a `Carried` figure copied from the last folha,
//// which is the only place they are written down.

import acuttis_point/audit
import acuttis_point/clock
import acuttis_point/holiday
import gleam/int
import gleam/list
import gleam/order

/// FAI's rule on consecutive work: no period may exceed five hours. Monitored by
/// the coordinator rather than enforced by the system — 27/07 (5h01) and 30/07
/// (5h03) were both credited in full — so this is reported, never deducted.
pub const max_consecutive_minutes = 300

/// Compensation a single weekday may carry, past which it needs authorisation.
pub const max_daily_compensation_minutes = 120

/// The bank as FAI's folha closed it, and the month that folha closes.
///
/// Their number rather than this module's. Recomputing the months the receipt no
/// longer reaches is not an option — the rows are gone — and their sheet has
/// already applied the adjustments this cannot see.
pub type Carried {
  Carried(year: Int, month: Int, minutes: Int)
}

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
    /// The most the bank may hold either way.
    ///
    /// FAI's own limite de compensação is forty hours, and that is not this
    /// number. On 2026-10 the coordinator set ten, and a tighter ceiling is
    /// the one that applies: being inside FAI's rule and outside his is still
    /// being outside.
    limit_minutes: Int,
    /// Past this, the bank is not a number to watch any more. Far enough over
    /// the ceiling to need a conversation rather than a few shorter days.
    alarm_minutes: Int,
    /// What the folha carried into this month, when the one configured closes
    /// the month before it. `Error(Nil)` when there is none, or when it closes
    /// some other month — the months between it and this one are unknown here,
    /// and adding it across them would invent them.
    carried_minutes: Result(Int, Nil),
    /// The emendas of this month that have already happened. Each one is a
    /// whole contractual day nobody worked and everybody owes: FAI grants the
    /// day and the hours come back later.
    ///
    /// They are here rather than among the measured days because they are not
    /// on the receipt and never will be — there is no marking to read on a day
    /// nobody came in.
    bridged: List(clock.Date),
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
  alarm_minutes alarm_minutes: Int,
  carried carried: Result(Carried, Nil),
  calendar calendar: holiday.Calendar,
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
    alarm_minutes: alarm_minutes,
    carried_minutes: carried_into(carried, month_of),
    bridged: bridged_so_far(calendar, month_of, today),
  )
}

/// The emendas of this month up to and including today. An emenda still ahead
/// is not a hole in the bank yet: nothing has been taken, so nothing is owed.
fn bridged_so_far(
  calendar: holiday.Calendar,
  month_of: clock.Date,
  today: clock.Date,
) -> List(clock.Date) {
  holiday.without_expedient(
    calendar: calendar,
    year: clock.year(month_of),
    month: clock.month(month_of),
  )
  |> list.filter_map(fn(entry) {
    let #(date, reason) = entry
    case reason, clock.compare(date, today) {
      holiday.Bridge(..), order.Lt | holiday.Bridge(..), order.Eq -> Ok(date)
      _, _ -> Error(Nil)
    }
  })
}

/// The hours the emendas of this month owe: a whole contractual day each.
///
/// FAI grants the day between a holiday and the weekend and takes the hours
/// back afterwards, so an emenda is a debt rather than a gift. Left out, the
/// extra hours worked to repay one read as pure credit, and the bank looks
/// better than it is by a working day every time.
pub fn owed(balance: Balance) -> Int {
  list.length(balance.bridged) * balance.daily_minutes
}

/// The carried figure, but only when it closes the month immediately before the
/// one being reported.
///
/// A folha from three months back is not a wrong number, it is a number about
/// other months, and the ones in between are not on this receipt either. Refused
/// rather than added, so a stale `BANK_CARRIED_THROUGH` shows up as a bank this
/// cannot state instead of one it states too low.
fn carried_into(
  carried: Result(Carried, Nil),
  month_of: clock.Date,
) -> Result(Int, Nil) {
  let previous = case clock.month(month_of) {
    1 -> #(clock.year(month_of) - 1, 12)
    month -> #(clock.year(month_of), month - 1)
  }

  case carried {
    Ok(Carried(year:, month:, minutes:)) if previous == #(year, month) ->
      Ok(minutes)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// Everything banked upwards, in minutes. FAI's "Banco Horas Créd".
pub fn credit(balance: Balance) -> Int {
  banked(balance) |> list.filter(fn(one) { one > 0 }) |> sum
}

/// Everything banked downwards, positive. FAI's "Banco Horas Déb".
pub fn debit(balance: Balance) -> Int {
  banked(balance) |> list.filter(fn(one) { one < 0 }) |> sum |> int.negate
}

/// What the month actually moved the bank by: credit, less debit, less the
/// emendas it owes.
///
/// `credit` and `debit` are the receipt's own two columns and stay that way, so
/// they can still be read against FAI's "Banco Horas Créd" and "Déb". The
/// emenda is not on the receipt and belongs to neither, but it moved the bank
/// all the same.
pub fn difference(balance: Balance) -> Int {
  credit(balance) - debit(balance) - owed(balance)
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

/// The whole bank: what the folha carried in, plus what this month has moved.
/// This, and not the month, is what the forty hour limit is about.
///
/// `Error(Nil)` when no folha closes the month before this one, and then the
/// month's own movement is all that can honestly be said.
pub fn accumulated(balance: Balance) -> Result(Int, Nil) {
  case balance.carried_minutes {
    Ok(carried) -> Ok(carried + difference(balance))
    Error(Nil) -> Error(Nil)
  }
}

/// Where the bank stands now, signed.
///
/// The whole bank when the folha says where it stood, and this month alone when
/// it does not — which reads as less bank than there is, never more, because
/// the earlier months are still in it. That is the wrong direction to be wrong
/// in, and it is why the carried figure exists.
pub fn standing_minutes(balance: Balance) -> Int {
  case accumulated(balance) {
    Ok(whole) -> whole
    Error(Nil) -> difference(balance)
  }
}

/// How the bank reads against the ceiling. Green, yellow, red.
pub type Standing {
  /// Inside the ceiling. Nothing to do.
  Within
  /// Over it. The way back is a run of shorter days, and the sooner the
  /// shorter they have to be.
  Over
  /// Far enough over that shorter days will not do it quietly.
  Alarming
}

pub fn standing(balance: Balance) -> Standing {
  let held = int.absolute_value(standing_minutes(balance))

  case held <= balance.limit_minutes, held >= balance.alarm_minutes {
    True, _ -> Within
    _, True -> Alarming
    _, _ -> Over
  }
}

/// How much of the ceiling the bank has not used. Zero once it is over, which
/// is honest: there is no room left, there is a debt to work off.
pub fn room_left(balance: Balance) -> Int {
  int.max(
    0,
    balance.limit_minutes - int.absolute_value(standing_minutes(balance)),
  )
}

/// How far past the ceiling the bank is, and so how much has to come back off
/// it. Zero while it is inside.
pub fn over_by(balance: Balance) -> Int {
  int.max(
    0,
    int.absolute_value(standing_minutes(balance)) - balance.limit_minutes,
  )
}

/// Whether another month like this one would put the bank past the limit.
///
/// The month is its own threshold, which is what makes this worth saying out
/// loud: a month that banked ten hours warns ten hours out, and a month that
/// banked nothing does not warn at all. Nothing here stops the hours
/// accumulating — the point is to hear about it while there is still a month to
/// do something in.
pub fn nearly_full(balance: Balance) -> Bool {
  room_left(balance) <= int.absolute_value(difference(balance))
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
  <> " emenda="
  <> int.to_string(list.length(balance.bridged))
  <> "d/"
  <> duration(owed(balance))
  <> " balance="
  <> signed(difference(balance))
  <> " daily="
  <> duration(balance.daily_minutes)
  <> " unmeasurable="
  <> int.to_string(list.length(balance.unmeasurable))
  <> " irregular="
  <> int.to_string(list.length(irregular(balance)))
  <> " accumulated="
  <> case accumulated(balance) {
    Ok(whole) -> signed(whole)
    // Said rather than left blank: a reader should know the difference between
    // a bank at zero and a bank nobody told this run about.
    Error(Nil) -> "unknown"
  }
  <> " room="
  <> duration(room_left(balance))
  <> " limit="
  <> duration(balance.limit_minutes)
  <> " standing="
  <> standing_to_string(standing(balance))
  <> case over_by(balance) {
    0 -> ""
    over -> " over_by=" <> duration(over)
  }
}

pub fn standing_to_string(how: Standing) -> String {
  case how {
    Within -> "within"
    Over -> "over"
    Alarming -> "alarming"
  }
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
