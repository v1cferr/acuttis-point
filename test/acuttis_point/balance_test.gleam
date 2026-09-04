import acuttis_point/audit
import acuttis_point/balance
import acuttis_point/clock
import gleam/list

fn day(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

/// Eight hours: forty a week, which is the contract.
const daily = 480

const tolerance = 10

const min_lunch = 60

/// Rows in the shape the receipt prints them.
fn rows(entries: List(#(String, List(String)))) -> List(String) {
  list.flat_map(entries, fn(entry) {
    let #(date, times) = entry
    list.map(times, fn(time) { date <> " Seg - " <> time <> "location_on" })
  })
}

fn month(
  entries: List(#(String, List(String))),
  reporting: String,
  today: String,
) -> balance.Balance {
  carrying(entries, reporting, today, Error(Nil))
}

/// The same month, with a folha behind it.
fn carrying(
  entries: List(#(String, List(String))),
  reporting: String,
  today: String,
  carried: Result(balance.Carried, Nil),
) -> balance.Balance {
  balance.for_month(
    days: audit.audit(rows: rows(entries), today: day(today)).days,
    month_of: day(reporting),
    today: day(today),
    daily_minutes: daily,
    tolerance_minutes: tolerance,
    min_lunch_minutes: min_lunch,
    limit_minutes: 2400,
    carried: carried,
  )
}

/// The folha FAI produced for July 2026, every working day of it. This is the
/// specification: if this module and that sheet disagree, this module is wrong.
const july = [
  #("17/07/2026", ["08:02", "12:44", "14:38", "18:05"]),
  #("20/07/2026", ["08:05", "12:31", "14:04", "18:02"]),
  #("21/07/2026", ["08:06", "12:17", "14:05", "17:58"]),
  #("22/07/2026", ["08:09", "12:33", "13:58", "18:18"]),
  #("23/07/2026", ["08:07", "12:38", "14:20", "17:37"]),
  #("24/07/2026", ["08:06", "12:42", "14:02", "17:36"]),
  #("27/07/2026", ["07:55", "12:56", "14:00", "17:32"]),
  #("28/07/2026", ["08:04", "12:56", "13:59", "17:34"]),
  #("29/07/2026", ["08:02", "12:58", "14:01", "17:33"]),
  #("30/07/2026", ["08:04", "13:07", "14:00", "17:34"]),
  #("31/07/2026", ["08:03", "12:53", "14:00", "17:39"]),
]

// The whole point of this module: agree with the folha, to the minute.
pub fn july_matches_the_official_sheet_test() {
  let found = month(july, "2026-07-15", "2026-08-01")

  assert list.length(found.measured) == 11
  assert balance.duration(balance.credit(found)) == "3h35"
  assert balance.duration(balance.debit(found)) == "0h12"
  assert balance.signed(balance.difference(found)) == "+3h23"
}

fn banked_on(found: balance.Balance, date: String) -> Int {
  let assert Ok(balance.Measured(banked_minutes:, ..)) =
    list.find(found.measured, fn(one) {
      case one {
        balance.Measured(date: on, ..) -> clock.date_to_dmy(on) == date
        balance.Unmeasurable(..) -> False
      }
    })
  banked_minutes
}

// Ten minutes is nothing; eleven is eleven. "Qualquer registro, seja positivo ou
// negativo, só será considerado após o décimo primeiro minuto."
//
// The trap is in both directions: treating ten as one, or treating eleven as one.
// 24/07 worked 8h10 and was credited nothing at all.
pub fn the_tolerance_is_a_threshold_not_a_deduction_test() {
  let found = month(july, "2026-07-15", "2026-08-01")

  // Inside the tolerance: nothing banked, in either direction.
  assert banked_on(found, "17/07/2026") == 0
  // 8h09
  assert banked_on(found, "21/07/2026") == 0
  // 8h04
  assert banked_on(found, "24/07/2026") == 0
  // 8h10, exactly at it

  // Past it, the whole deviation — not the part above ten.
  assert banked_on(found, "20/07/2026") == 24
  assert banked_on(found, "23/07/2026") == -12
  assert banked_on(found, "22/07/2026") == 44
}

// 30/07 is the day that proves the lunch rule. Worked 8h37, credited 30 minutes,
// because the break was fifty three minutes and cost the seven it was short.
pub fn a_short_lunch_costs_what_it_was_short_test() {
  let found = month(july, "2026-07-15", "2026-08-01")

  let assert Ok(balance.Measured(
    gross_minutes:,
    shortfall_minutes:,
    lunch_minutes:,
    banked_minutes:,
    ..,
  )) =
    list.find(found.measured, fn(one) {
      case one {
        balance.Measured(date:, ..) -> clock.date_to_dmy(date) == "30/07/2026"
        balance.Unmeasurable(..) -> False
      }
    })

  assert lunch_minutes == 53
  assert shortfall_minutes == 7
  assert balance.duration(gross_minutes) == "8h37"
  assert banked_minutes == 30
}

// Five consecutive hours is FAI's limit, and the folha shows it was exceeded
// twice in July and credited in full both times. So it is reported, never
// deducted — a rule the coordinator watches, not one the system applies.
pub fn more_than_five_consecutive_hours_is_reported_not_deducted_test() {
  let found = month(july, "2026-07-15", "2026-08-01")
  let over = balance.irregular(found)

  assert list.length(over) == 2
  let dates =
    list.map(over, fn(one) {
      case one {
        balance.Measured(date:, ..) | balance.Unmeasurable(date:, ..) ->
          clock.date_to_dmy(date)
      }
    })
  // 27/07 worked 5h01 before lunch, 30/07 worked 5h03.
  assert dates == ["30/07/2026", "27/07/2026"]

  // And both were still banked in full.
  assert banked_on(found, "27/07/2026") == 33
  assert banked_on(found, "30/07/2026") == 30
}

// An odd number of markings cannot be measured without deciding which one is
// missing, and deciding that invents hours.
pub fn a_day_that_does_not_pair_up_is_not_measured_test() {
  let found =
    month(
      [#("05/08/2026", ["08:06", "12:55", "17:38"])],
      "2026-08-20",
      "2026-08-20",
    )

  assert found.measured == []
  assert list.length(found.unmeasurable) == 1
  assert balance.difference(found) == 0
}

// Today is left out: unfinished, it would invent a debt the afternoon fills.
pub fn today_is_not_counted_test() {
  let found =
    month([#("20/08/2026", ["07:59", "12:40"])], "2026-08-20", "2026-08-20")

  assert found.measured == []
  assert balance.signed(balance.difference(found)) == "+0h00"
}

// A short day has no break to be short of, so nothing is deducted from it. Its
// deficit is real and does reach the bank.
pub fn a_single_pair_is_not_charged_a_missing_lunch_test() {
  let found =
    month([#("16/06/2026", ["12:35", "15:35"])], "2026-06-20", "2026-06-20")

  let assert [balance.Measured(shortfall_minutes:, banked_minutes:, ..)] =
    found.measured
  assert shortfall_minutes == 0
  // Three hours against eight: five hours in debt, and no invented lunch.
  assert banked_minutes == -300
}

pub fn the_compensation_limit_is_reported_test() {
  let found = month(july, "2026-07-15", "2026-08-01")

  assert found.limit_minutes == 2400
  // Forty hours minus the 3h23 July moved.
  assert balance.duration(balance.room_left(found)) == "36h37"
  // And with no folha behind it, that is only July: the limit is about the whole
  // bank, and the months before this one are not on this receipt.
  assert balance.accumulated(found) == Error(Nil)
}

// The limit is on the bank, and the bank started before this month. Ten hours
// carried in and 3h23 moved is 13h23 against the forty, not 3h23.
pub fn the_bank_is_what_was_carried_in_plus_the_month_test() {
  let found =
    carrying(
      july,
      "2026-07-15",
      "2026-08-01",
      Ok(balance.Carried(2026, 6, 600)),
    )

  assert balance.signed(balance.accumulated(found) |> unwrap) == "+13h23"
  assert balance.duration(balance.room_left(found)) == "26h37"
}

// A folha that closes some other month is a number about other months. Refused
// rather than added, because the months in between are unknown here and the
// error would run in the comfortable direction: more room than there is.
pub fn a_folha_from_another_month_is_not_added_test() {
  let found =
    carrying(
      july,
      "2026-07-15",
      "2026-08-01",
      Ok(balance.Carried(2026, 5, 600)),
    )

  assert balance.accumulated(found) == Error(Nil)
  assert balance.duration(balance.room_left(found)) == "36h37"
}

// December closes January's previous month, which is the one case a subtraction
// gets wrong.
pub fn december_carries_into_january_test() {
  let found =
    carrying(
      july,
      "2027-01-15",
      "2027-01-20",
      Ok(balance.Carried(2026, 12, 900)),
    )

  assert found.measured == []
  assert balance.signed(balance.accumulated(found) |> unwrap) == "+15h00"
}

// The warning is the month itself: at this rate, one more like it crosses forty
// hours. Nothing here stops the hours accumulating, so the only thing worth
// doing is saying it while there is still a month to act in.
pub fn a_month_that_would_cross_the_limit_warns_test() {
  let close =
    carrying(
      july,
      "2026-07-15",
      "2026-08-01",
      Ok(balance.Carried(2026, 6, 2100)),
    )
  // 2100 carried plus 3h23 is 38h23, and 1h37 of room against a month of 3h23.
  assert balance.duration(balance.room_left(close)) == "1h37"
  assert balance.nearly_full(close)

  let far =
    carrying(
      july,
      "2026-07-15",
      "2026-08-01",
      Ok(balance.Carried(2026, 6, 600)),
    )
  assert !balance.nearly_full(far)
}

fn unwrap(minutes: Result(Int, Nil)) -> Int {
  let assert Ok(value) = minutes
  value
}

pub fn zero_carries_a_sign_test() {
  assert balance.signed(0) == "+0h00"
  assert balance.signed(-1) == "-0h01"
  assert balance.duration(480) == "8h00"
}
