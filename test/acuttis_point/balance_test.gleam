import acuttis_point/audit
import acuttis_point/balance
import acuttis_point/clock
import gleam/list

fn day(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

/// Eight hours and twenty three minutes, which is what this schedule's own
/// nominal day comes to. The point of passing it in is that it can be wrong
/// without the arithmetic being wrong.
const daily = 503

fn audited(rows: List(String), today: String) -> List(audit.Day) {
  audit.audit(rows: rows, today: day(today)).days
}

// Real days, from the receipt. 18/08 is 08:17 to 12:51 and 13:51 to 17:43,
// which is 4h34 plus 3h52 — eight hours and twenty six minutes.
pub fn a_day_is_the_sum_of_its_pairs_test() {
  let rows = [
    "18/08/2026 Ter - 08:17location_on",
    "18/08/2026 Ter - 12:51location_on",
    "18/08/2026 Ter - 13:51location_on",
    "18/08/2026 Ter - 17:43location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-08-20"),
      now: day("2026-08-20"),
      daily_minutes: daily,
    )

  assert found.worked_minutes == 4 * 60 + 34 + 3 * 60 + 52
  assert balance.duration(found.worked_minutes) == "8h26"
  assert found.owed_minutes == daily
  // Three minutes over the day's own nominal, which is the whole point of the
  // schedule being written the way it is.
  assert balance.signed(balance.difference(found)) == "+0h03"
}

// A day off has no markings, so it owes nothing. Otherwise every day of leave
// would read as a deficit and the balance would be a measure of holidays.
pub fn a_day_without_markings_owes_nothing_test() {
  let rows = [
    "03/08/2026 Seg - 08:04location_on",
    "03/08/2026 Seg - 12:43location_on",
    "03/08/2026 Seg - 13:53location_on",
    "03/08/2026 Seg - 17:44location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-08-20"),
      now: day("2026-08-20"),
      daily_minutes: daily,
    )

  // One day measured, one day owed, whatever else the month contains.
  assert list.length(found.measured) == 1
  assert found.owed_minutes == daily
}

// An odd number of markings cannot be measured without deciding which one is
// missing, and deciding that would be inventing hours. So the day is left out of
// both sides of the sum and counted where it can be seen.
pub fn a_day_that_does_not_pair_up_is_not_measured_test() {
  let rows = [
    "05/08/2026 Qua - 08:06location_on",
    "05/08/2026 Qua - 12:55location_on",
    "05/08/2026 Qua - 17:38location_on",
    "18/08/2026 Ter - 08:17location_on",
    "18/08/2026 Ter - 12:51location_on",
    "18/08/2026 Ter - 13:51location_on",
    "18/08/2026 Ter - 17:43location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-08-20"),
      now: day("2026-08-20"),
      daily_minutes: daily,
    )

  assert list.length(found.measured) == 1
  assert list.length(found.unmeasurable) == 1
  let assert [balance.Unmeasurable(date:, found: markings)] = found.unmeasurable
  assert clock.date_to_dmy(date) == "05/08/2026"
  assert markings == 3
  // And the balance is over the day it could measure, not over both.
  assert found.owed_minutes == daily
}

// Today is left out: unfinished, it would invent a deficit the afternoon fills.
pub fn today_is_not_counted_test() {
  let rows = [
    "20/08/2026 Qui - 07:59location_on",
    "20/08/2026 Qui - 08:08location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-08-20"),
      now: day("2026-08-20"),
      daily_minutes: daily,
    )

  assert found.measured == []
  assert found.worked_minutes == 0
  assert found.owed_minutes == 0
  assert balance.signed(balance.difference(found)) == "+0h00"
}

pub fn only_the_current_month_counts_test() {
  let rows = [
    "31/07/2026 Sex - 08:03location_on",
    "31/07/2026 Sex - 12:53location_on",
    "31/07/2026 Sex - 14:00location_on",
    "31/07/2026 Sex - 17:39location_on",
    "03/08/2026 Seg - 08:04location_on",
    "03/08/2026 Seg - 12:43location_on",
    "03/08/2026 Seg - 13:53location_on",
    "03/08/2026 Seg - 17:44location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-08-20"),
      now: day("2026-08-20"),
      daily_minutes: daily,
    )

  assert list.length(found.measured) == 1
  assert found.month == 8
  assert found.year == 2026
}

// A short day is measured as what it was, not padded to a full one. The deficit
// is real: three hours worked against a day owed.
pub fn a_short_day_shows_as_a_deficit_test() {
  let rows = [
    "16/06/2026 Ter - 12:35location_on",
    "16/06/2026 Ter - 15:35location_on",
  ]
  let found =
    balance.for_month(
      days: audited(rows, "2026-06-20"),
      now: day("2026-06-20"),
      daily_minutes: daily,
    )

  assert balance.duration(found.worked_minutes) == "3h00"
  assert balance.signed(balance.difference(found)) == "-5h23"
}

// Zero carries a sign, so it cannot be read as a missing number.
pub fn a_balance_of_zero_still_has_a_sign_test() {
  assert balance.signed(0) == "+0h00"
  assert balance.signed(-1) == "-0h01"
  assert balance.signed(65) == "+1h05"
  assert balance.duration(503) == "8h23"
}
