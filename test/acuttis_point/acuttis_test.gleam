import acuttis_point/acuttis
import acuttis_point/clock
import acuttis_point/punch
import acuttis_point/state

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn on(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

const today = "2026-08-12"

/// The shape the real receipt uses: several days, newest first.
fn receipt() -> List(String) {
  [
    "12/08/2026 Qua - 18:08",
    "12/08/2026 Qua - 13:51",
    "12/08/2026 Qua - 12:44",
    "12/08/2026 Qua - 07:55",
    "11/08/2026 Ter - 17:37",
    "11/08/2026 Ter - 13:02",
  ]
}

pub fn only_todays_rows_are_read_test() {
  assert acuttis.read_punches(rows: receipt(), today: on(today))
    == Ok([
      state.Registered(punch: punch.Entry, at: at("07:55")),
      state.Registered(punch: punch.LunchStart, at: at("12:44")),
      state.Registered(punch: punch.LunchEnd, at: at("13:51")),
      state.Registered(punch: punch.Exit, at: at("18:08")),
    ])
}

// The receipt lists newest first, so the times have to be sorted rather than
// trusted in page order.
pub fn rows_are_sorted_not_taken_in_page_order_test() {
  let reversed = [
    "12/08/2026 Qua - 12:44",
    "12/08/2026 Qua - 07:55",
  ]
  assert acuttis.read_punches(rows: reversed, today: on(today))
    == Ok([
      state.Registered(punch: punch.Entry, at: at("07:55")),
      state.Registered(punch: punch.LunchStart, at: at("12:44")),
    ])
}

pub fn a_day_that_has_not_started_reads_as_empty_test() {
  let yesterday_only = ["11/08/2026 Ter - 17:37", "11/08/2026 Ter - 13:02"]
  assert acuttis.read_punches(rows: yesterday_only, today: on(today)) == Ok([])
}

// The safety property the multi-day receipt buys: no rows at all cannot be a
// fresh day, because the previous days would still be there.
pub fn no_rows_at_all_is_a_broken_selector_not_a_fresh_day_test() {
  assert acuttis.read_punches(rows: [], today: on(today))
    == Error(acuttis.PunchListNotFound)
}

pub fn a_row_for_today_without_a_time_is_an_error_test() {
  assert acuttis.read_punches(
      rows: ["12/08/2026 Qua - --:--", "12/08/2026 Qua - 07:55"],
      today: on(today),
    )
    == Error(acuttis.NoTimeIn("12/08/2026 Qua - --:--"))
}

pub fn a_row_for_another_day_without_a_time_is_ignored_test() {
  assert acuttis.read_punches(
      rows: ["cabeçalho sem hora", "12/08/2026 Qua - 07:55"],
      today: on(today),
    )
    == Ok([state.Registered(punch: punch.Entry, at: at("07:55"))])
}

pub fn more_rows_than_a_day_has_is_an_error_test() {
  let extra = [
    "12/08/2026 Qua - 18:08",
    "12/08/2026 Qua - 13:51",
    "12/08/2026 Qua - 12:44",
    "12/08/2026 Qua - 07:55",
    "12/08/2026 Qua - 19:00",
  ]
  assert acuttis.read_punches(rows: extra, today: on(today))
    == Error(acuttis.MorePunchesThanADayHas(5))
}

pub fn the_date_is_matched_exactly_test() {
  // A row from the same day of a different month must not be picked up.
  assert acuttis.read_punches(
      rows: ["12/09/2026 Sáb - 08:00", "12/08/2026 Qua - 07:55"],
      today: on(today),
    )
    == Ok([state.Registered(punch: punch.Entry, at: at("07:55"))])
}

pub fn a_single_digit_day_is_zero_padded_to_match_test() {
  assert acuttis.read_punches(
      rows: ["05/08/2026 Qua - 08:03"],
      today: on("2026-08-05"),
    )
    == Ok([state.Registered(punch: punch.Entry, at: at("08:03"))])
}

pub fn a_loose_looking_number_is_not_a_time_test() {
  assert acuttis.read_punches(
      rows: ["12/08/2026 Qua - 8:034"],
      today: on(today),
    )
    == Error(acuttis.NoTimeIn("12/08/2026 Qua - 8:034"))
  assert acuttis.read_punches(
      rows: ["12/08/2026 Qua - 25:00"],
      today: on(today),
    )
    == Error(acuttis.NoTimeIn("12/08/2026 Qua - 25:00"))
}

pub fn a_seconds_suffix_still_reads_as_the_time_test() {
  assert acuttis.read_punches(
      rows: ["12/08/2026 Qua - 07:55:41"],
      today: on(today),
    )
    == Ok([state.Registered(punch: punch.Entry, at: at("07:55"))])
}

pub fn error_to_string_points_at_discovery_test() {
  assert acuttis.error_to_string(acuttis.PunchListNotFound)
    == "the punch receipt showed no rows at all, so the selector no longer"
    <> " matches; run with DISCOVER=true to find the new one"
  assert acuttis.error_to_string(acuttis.MorePunchesThanADayHas(5))
    == "acuttis shows 5 punches today, more than a day has"
}
