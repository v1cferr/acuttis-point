import acuttis_point/clock
import acuttis_point/config
import acuttis_point/punch
import gleam/dict
import gleam/list

fn env(overrides: List(#(String, String))) -> dict.Dict(String, String) {
  [
    #("ENTRY_TIME", "08:00"),
    #("LUNCH_START", "12:00"),
    #("LUNCH_END", "13:00"),
    #("EXIT_TIME", "17:30"),
  ]
  |> list.append(overrides)
  |> dict.from_list
}

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

pub fn defaults_cover_everything_but_the_schedule_test() {
  let assert Ok(loaded) = config.from_env(env([]))

  assert loaded.base_url == "https://app.acuttis.com.br"
  assert loaded.work_days
    == [
      clock.Monday,
      clock.Tuesday,
      clock.Wednesday,
      clock.Thursday,
      clock.Friday,
    ]
  assert loaded.tolerance_minutes == 10
  assert loaded.timezone == "America/Sao_Paulo"
  assert loaded.skip_dates == []
  assert !loaded.dry_run
}

pub fn schedule_times_are_required_test() {
  assert config.from_env(dict.new()) == Error(config.MissingKey("ENTRY_TIME"))
  assert config.from_env(dict.from_list([#("ENTRY_TIME", "08:00")]))
    == Error(config.MissingKey("LUNCH_START"))
}

pub fn a_blank_value_counts_as_missing_test() {
  assert config.from_env(env([#("ENTRY_TIME", "   ")]))
    == Error(config.MissingKey("ENTRY_TIME"))
}

pub fn scheduled_time_maps_each_punch_test() {
  let assert Ok(loaded) = config.from_env(env([]))
  let times =
    punch.sequence
    |> list.map(fn(target) {
      clock.time_to_string(config.scheduled_time(loaded.schedule, target))
    })
  assert times == ["08:00", "12:00", "13:00", "17:30"]
}

pub fn schedule_must_run_forward_test() {
  assert config.from_env(env([#("LUNCH_START", "07:00")]))
    == Error(config.ScheduleOutOfOrder(
      earlier: punch.Entry,
      later: punch.LunchStart,
    ))
  assert config.from_env(env([#("EXIT_TIME", "12:30")]))
    == Error(config.ScheduleOutOfOrder(
      earlier: punch.LunchEnd,
      later: punch.Exit,
    ))
}

pub fn a_schedule_with_equal_times_is_accepted_test() {
  let assert Ok(loaded) = config.from_env(env([#("LUNCH_END", "12:00")]))
  assert config.scheduled_time(loaded.schedule, punch.LunchEnd) == at("12:00")
}

pub fn malformed_times_report_the_key_test() {
  assert config.from_env(env([#("EXIT_TIME", "25:00")]))
    == Error(config.InvalidValue(
      key: "EXIT_TIME",
      value: "25:00",
      reason: clock.HourOutOfRange(25),
    ))
}

pub fn work_days_are_parsed_and_deduplicated_test() {
  let assert Ok(loaded) =
    config.from_env(env([#("WORK_DAYS", " mon , WED,mon ")]))
  assert loaded.work_days == [clock.Monday, clock.Wednesday]
}

pub fn work_days_reject_unknown_names_test() {
  assert config.from_env(env([#("WORK_DAYS", "MON,FUNDAY")]))
    == Error(config.InvalidValue(
      key: "WORK_DAYS",
      value: "FUNDAY",
      reason: clock.UnknownWeekday("FUNDAY"),
    ))
}

pub fn work_days_reject_a_list_of_separators_test() {
  assert config.from_env(env([#("WORK_DAYS", ",,,")]))
    == Error(config.EmptyValue("WORK_DAYS"))
}

pub fn skip_dates_are_optional_and_parsed_test() {
  let assert Ok(loaded) =
    config.from_env(env([#("SKIP_DATES", "2026-09-07, 2026-12-25")]))
  let assert Ok(independence) = clock.parse_date("2026-09-07")
  let assert Ok(christmas) = clock.parse_date("2026-12-25")
  assert loaded.skip_dates == [independence, christmas]
}

pub fn skip_dates_reject_impossible_days_test() {
  assert config.from_env(env([#("SKIP_DATES", "2026-02-30")]))
    == Error(config.InvalidValue(
      key: "SKIP_DATES",
      value: "2026-02-30",
      reason: clock.DayOutOfRange(30),
    ))
}

pub fn tolerance_is_bounded_test() {
  let assert Ok(loaded) =
    config.from_env(env([#("TIME_TOLERANCE_MINUTES", "45")]))
  assert loaded.tolerance_minutes == 45

  assert config.from_env(env([#("TIME_TOLERANCE_MINUTES", "-1")]))
    == Error(config.OutOfRange(
      key: "TIME_TOLERANCE_MINUTES",
      value: "-1",
      minimum: 0,
      maximum: 240,
    ))
  assert config.from_env(env([#("TIME_TOLERANCE_MINUTES", "soon")]))
    == Error(config.NotAnInteger(key: "TIME_TOLERANCE_MINUTES", value: "soon"))
}

pub fn dry_run_accepts_common_spellings_test() {
  let assert Ok(on) = config.from_env(env([#("DRY_RUN", "TRUE")]))
  let assert Ok(off) = config.from_env(env([#("DRY_RUN", "no")]))
  assert on.dry_run
  assert !off.dry_run

  assert config.from_env(env([#("DRY_RUN", "maybe")]))
    == Error(config.NotABoolean(key: "DRY_RUN", value: "maybe"))
}

pub fn base_url_must_be_https_and_loses_trailing_slashes_test() {
  let assert Ok(loaded) =
    config.from_env(env([#("ACUTTIS_URL", "https://example.test//")]))
  assert loaded.base_url == "https://example.test"

  assert config.from_env(env([#("ACUTTIS_URL", "http://app.acuttis.com.br")]))
    == Error(config.InsecureUrl(
      key: "ACUTTIS_URL",
      value: "http://app.acuttis.com.br",
    ))
}

pub fn describe_lists_the_effective_settings_test() {
  let assert Ok(loaded) = config.from_env(env([#("WORK_DAYS", "MON")]))
  assert config.describe(loaded)
    == "url=https://app.acuttis.com.br days=MON ENTRY=08:00 LUNCH_START=12:00 "
    <> "LUNCH_END=13:00 EXIT=17:30 tolerance=10m tz=America/Sao_Paulo "
    <> "skipped=0 dry_run=false"
}

pub fn error_to_string_is_actionable_test() {
  assert config.error_to_string(config.MissingKey("ENTRY_TIME"))
    == "ENTRY_TIME is not set"
  assert config.error_to_string(config.InvalidValue(
      key: "EXIT_TIME",
      value: "25:00",
      reason: clock.HourOutOfRange(25),
    ))
    == "EXIT_TIME=25:00 is invalid: hour 25"
  assert config.error_to_string(config.ScheduleOutOfOrder(
      earlier: punch.Entry,
      later: punch.LunchStart,
    ))
    == "LUNCH_START is scheduled before ENTRY"
}
