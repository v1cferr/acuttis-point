import acuttis_point/clock

fn date(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

pub fn parse_time_accepts_padded_and_unpadded_test() {
  let assert Ok(padded) = clock.parse_time("08:00")
  let assert Ok(unpadded) = clock.parse_time("8:0")
  assert clock.minutes_since_midnight(padded) == 480
  assert padded == unpadded
}

pub fn parse_time_trims_surrounding_whitespace_test() {
  let assert Ok(time) = clock.parse_time("  17:30  ")
  assert clock.time_to_string(time) == "17:30"
}

pub fn parse_time_rejects_malformed_values_test() {
  assert clock.parse_time("1730") == Error(clock.MalformedTime("1730"))
  assert clock.parse_time("12:34:56") == Error(clock.MalformedTime("12:34:56"))
  assert clock.parse_time("noon") == Error(clock.MalformedTime("noon"))
}

pub fn parse_time_rejects_out_of_range_values_test() {
  assert clock.parse_time("24:00") == Error(clock.HourOutOfRange(24))
  assert clock.parse_time("12:60") == Error(clock.MinuteOutOfRange(60))
  assert clock.new_time(hour: -1, minute: 0) == Error(clock.HourOutOfRange(-1))
}

pub fn time_to_string_zero_pads_test() {
  let assert Ok(time) = clock.new_time(hour: 7, minute: 5)
  assert clock.time_to_string(time) == "07:05"
}

pub fn minutes_between_is_signed_test() {
  let assert Ok(earlier) = clock.parse_time("12:00")
  let assert Ok(later) = clock.parse_time("12:44")
  assert clock.minutes_between(from: earlier, to: later) == 44
  assert clock.minutes_between(from: later, to: earlier) == -44
}

pub fn weekday_matches_the_calendar_test() {
  assert clock.weekday(date("2026-08-12")) == clock.Wednesday
  assert clock.weekday(date("2026-08-15")) == clock.Saturday
  assert clock.weekday(date("2026-08-16")) == clock.Sunday
}

pub fn weekday_handles_january_and_leap_years_test() {
  assert clock.weekday(date("2026-01-01")) == clock.Thursday
  assert clock.weekday(date("2026-02-28")) == clock.Saturday
  assert clock.weekday(date("2000-02-29")) == clock.Tuesday
  assert clock.weekday(date("1999-12-31")) == clock.Friday
}

pub fn parse_date_reads_padded_components_test() {
  let parsed = date("2026-08-05")
  assert clock.year(parsed) == 2026
  assert clock.month(parsed) == 8
  assert clock.day(parsed) == 5
}

pub fn parse_date_rejects_malformed_values_test() {
  assert clock.parse_date("20260805") == Error(clock.MalformedDate("20260805"))
  assert clock.parse_date("2026-08") == Error(clock.MalformedDate("2026-08"))
  assert clock.parse_date("2026-ago-05")
    == Error(clock.MalformedDate("2026-ago-05"))
}

pub fn parse_date_rejects_impossible_days_test() {
  assert clock.parse_date("2026-13-01") == Error(clock.MonthOutOfRange(13))
  assert clock.parse_date("2026-00-01") == Error(clock.MonthOutOfRange(0))
  assert clock.parse_date("2026-02-29") == Error(clock.DayOutOfRange(29))
  assert clock.parse_date("2026-04-31") == Error(clock.DayOutOfRange(31))
  assert clock.parse_date("2026-08-00") == Error(clock.DayOutOfRange(0))
}

pub fn february_follows_the_leap_year_rule_test() {
  assert clock.days_in_month(year: 2024, month: 2) == 29
  assert clock.days_in_month(year: 2026, month: 2) == 28
  assert clock.days_in_month(year: 1900, month: 2) == 28
  assert clock.days_in_month(year: 2000, month: 2) == 29
  assert clock.parse_date("2024-02-29") == Ok(date("2024-02-29"))
}

pub fn parse_weekday_is_case_insensitive_test() {
  assert clock.parse_weekday("mon") == Ok(clock.Monday)
  assert clock.parse_weekday(" FRI ") == Ok(clock.Friday)
  assert clock.parse_weekday("Sun") == Ok(clock.Sunday)
  assert clock.parse_weekday("Funday") == Error(clock.UnknownWeekday("Funday"))
}

pub fn date_to_string_zero_pads_test() {
  assert clock.date_to_string(date("2026-08-05")) == "2026-08-05"
}
