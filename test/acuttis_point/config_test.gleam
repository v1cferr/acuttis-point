import acuttis_point/balance
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/holiday
import acuttis_point/punch
import gleam/dict
import gleam/list

fn env(overrides: List(#(String, String))) -> dict.Dict(String, String) {
  [
    #("ENTRY_TIME", "08:00"),
    #("LUNCH_START", "12:00"),
    // 12:00 to 14:00 leaves 110 minutes even in the worst case, so the base
    // schedule clears the one-hour floor and each test can break it on purpose.
    #("LUNCH_END", "14:00"),
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
  assert loaded.calendar
    == holiday.Calendar(
      national: True,
      annual: [],
      local: [],
      declared: [],
      bridges: True,
    )
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
  assert times == ["08:00", "12:00", "14:00", "17:30"]
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
  // Equal times are allowed by the ordering rule; the pair chosen here is the
  // one that does not also have to clear the lunch floor.
  let assert Ok(loaded) = config.from_env(env([#("EXIT_TIME", "14:00")]))
  assert config.scheduled_time(loaded.schedule, punch.Exit) == at("14:00")
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
  assert loaded.calendar.declared == [independence, christmas]
}

pub fn local_holidays_are_parsed_with_their_names_test() {
  let assert Ok(loaded) =
    config.from_env(
      env([
        #(
          "LOCAL_HOLIDAYS",
          "2026-11-04=Aniversario de Sao Carlos, 2026-07-09=Revolucao Constitucionalista",
        ),
      ]),
    )
  let assert Ok(anniversary) = clock.parse_date("2026-11-04")
  let assert Ok(revolution) = clock.parse_date("2026-07-09")
  assert loaded.calendar.local
    == [
      #(anniversary, "Aniversario de Sao Carlos"),
      #(revolution, "Revolucao Constitucionalista"),
    ]
}

/// A day off that cannot say what it is belongs in SKIP_DATES, which asks for
/// no name because it promises none.
pub fn a_local_holiday_without_a_name_is_refused_test() {
  assert config.from_env(env([#("LOCAL_HOLIDAYS", "2026-11-04")]))
    == Error(config.NamelessHoliday(key: "LOCAL_HOLIDAYS", value: "2026-11-04"))

  assert config.from_env(env([#("LOCAL_HOLIDAYS", "2026-11-04=  ")]))
    == Error(config.NamelessHoliday(key: "LOCAL_HOLIDAYS", value: "2026-11-04="))
}

pub fn the_derived_calendar_and_the_emenda_can_be_turned_off_test() {
  let assert Ok(loaded) =
    config.from_env(
      env([#("NATIONAL_HOLIDAYS", "false"), #("BRIDGE_HOLIDAYS", "false")]),
    )
  assert loaded.calendar == holiday.nothing_off()
}

pub fn skip_dates_reject_impossible_days_test() {
  assert config.from_env(env([#("SKIP_DATES", "2026-02-30")]))
    == Error(config.InvalidValue(
      key: "SKIP_DATES",
      value: "2026-02-30",
      reason: clock.DayOutOfRange(30),
    ))
}

// A hard rule, so it must not depend on anyone doing the arithmetic right: a
// schedule whose worst case falls under an hour is refused outright.
pub fn a_schedule_that_could_shorten_lunch_below_an_hour_is_refused_test() {
  // 12:35 to 13:30 is 55 minutes even before the tolerance is spent.
  assert config.from_env(
      env([#("LUNCH_START", "12:35"), #("LUNCH_END", "13:30")]),
    )
    == Error(config.LunchCouldBeTooShort(guaranteed: 45, required: 60))

  // 12:35 to 13:45 looks like 70 minutes, but a punch can land ten minutes into
  // either window, and both landing the wrong way leaves 60.
  let assert Ok(_) =
    config.from_env(env([#("LUNCH_START", "12:35"), #("LUNCH_END", "13:45")]))

  // One minute less and the floor is broken.
  assert config.from_env(
      env([#("LUNCH_START", "12:36"), #("LUNCH_END", "13:45")]),
    )
    == Error(config.LunchCouldBeTooShort(guaranteed: 59, required: 60))
}

pub fn the_guaranteed_lunch_is_the_worst_case_of_both_windows_test() {
  let assert Ok(loaded) =
    config.from_env(
      env([
        #("LUNCH_START", "12:35"),
        #("LUNCH_END", "13:51"),
        #("TIME_TOLERANCE_MINUTES", "10"),
      ]),
    )

  // 13:51 minus a lunch start that landed as late as 12:45.
  assert config.guaranteed_lunch_minutes(loaded.schedule, 10) == 66
  assert loaded.min_lunch_minutes == 60
}

// A wider tolerance eats into the lunch from both ends, so it can break a
// schedule that was fine before.
pub fn widening_the_tolerance_can_break_the_floor_test() {
  assert config.from_env(
      env([
        #("LUNCH_START", "12:35"),
        #("LUNCH_END", "13:51"),
        #("TIME_TOLERANCE_MINUTES", "20"),
      ]),
    )
    == Error(config.LunchCouldBeTooShort(guaranteed: 56, required: 60))
}

pub fn the_floor_is_configurable_test() {
  // Someone whose contract allows a shorter break can say so.
  let assert Ok(loaded) =
    config.from_env(
      env([
        #("LUNCH_START", "12:35"),
        #("LUNCH_END", "13:30"),
        #("MIN_LUNCH_MINUTES", "45"),
      ]),
    )
  assert loaded.min_lunch_minutes == 45
}

pub fn the_error_says_how_to_fix_it_test() {
  assert config.error_to_string(config.LunchCouldBeTooShort(
      guaranteed: 45,
      required: 60,
    ))
    == "this schedule could produce a lunch break of only 45 minutes, under the"
    <> " 60 required; move LUNCH_END later, LUNCH_START earlier, or lower"
    <> " TIME_TOLERANCE_MINUTES"
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

// A proxy is not decoration: it decides where the punch appears to come from.
// Anything the browser would not understand has to be refused, because the
// alternative is a run that goes out from here believing it did not.
pub fn a_proxy_the_browser_would_not_understand_is_refused_test() {
  let assert Ok(none) = config.from_env(env([]))
  assert none.proxy_server == Error(Nil)

  let assert Ok(socks) =
    config.from_env(env([#("PROXY_SERVER", "socks5://127.0.0.1:11080")]))
  assert socks.proxy_server == Ok("socks5://127.0.0.1:11080")

  // A bare host:port is the tempting way to write it, and Chromium reads it as
  // http, which is not what a SOCKS tunnel speaks.
  assert config.from_env(env([#("PROXY_SERVER", "127.0.0.1:11080")]))
    == Error(config.UnsupportedProxy(
      key: "PROXY_SERVER",
      value: "127.0.0.1:11080",
    ))

  // A scheme with nothing after it is not an address either.
  assert config.from_env(env([#("PROXY_SERVER", "socks5://")]))
    == Error(config.UnsupportedProxy(key: "PROXY_SERVER", value: "socks5://"))

  // Blank reads as absent, like every other optional setting.
  let assert Ok(blank) = config.from_env(env([#("PROXY_SERVER", "   ")]))
  assert blank.proxy_server == Error(Nil)
}

pub fn describe_lists_the_effective_settings_test() {
  let assert Ok(loaded) = config.from_env(env([#("WORK_DAYS", "MON")]))
  assert config.describe(loaded)
    == "url=https://app.acuttis.com.br days=MON ENTRY=08:00 LUNCH_START=12:00 "
    <> "LUNCH_END=14:00 EXIT=17:30 tolerance=10m tz=America/Sao_Paulo "
    <> "lunch>=110m calendar=national+bridges+0annual+0local+0off dry_run=false"

  // Where a run goes out from belongs in the header: it is the difference
  // between two runs that otherwise log identically.
  let assert Ok(proxied) =
    config.from_env(
      env([#("WORK_DAYS", "MON"), #("PROXY_SERVER", "socks5://127.0.0.1:11080")]),
    )
  assert config.describe(proxied)
    == "url=https://app.acuttis.com.br days=MON ENTRY=08:00 LUNCH_START=12:00 "
    <> "LUNCH_END=14:00 EXIT=17:30 tolerance=10m tz=America/Sao_Paulo "
    <> "lunch>=110m calendar=national+bridges+0annual+0local+0off dry_run=false"
    <> " proxy=socks5://127.0.0.1:11080"
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

// FAI's rule: no period may run more than five consecutive hours. Their own
// folha shows it exceeded twice in July and credited in full, so the system does
// not block it — the coordinator watches. But a schedule that CAN breach it will,
// and configuration time is the cheapest place to find out.
//
// This would have refused the lunch at 12:45 that was chosen on 2026-08-24, and
// accepted the 12:40 that replaced it.
pub fn a_schedule_that_could_run_over_five_hours_is_refused_test() {
  let with_lunch_at = fn(at) {
    config.from_env(
      env([
        #("ENTRY_TIME", "07:51"),
        #("LUNCH_START", at),
        #("LUNCH_END", "13:55"),
        #("EXIT_TIME", "17:45"),
      ]),
    )
  }

  // 07:51 to 12:45 is 4h54, and ten minutes of tolerance makes 5h04.
  assert with_lunch_at("12:45")
    == Error(config.StretchCouldBeTooLong(
      period: "morning",
      worst: 304,
      allowed: 300,
    ))

  // 12:40 leaves the worst case at 4h59, with a minute to spare.
  let assert Ok(_) = with_lunch_at("12:40")

  // The afternoon is checked the same way: 13:55 to 19:00 could run 5h15.
  assert config.from_env(
      env([
        #("ENTRY_TIME", "07:51"),
        #("LUNCH_START", "12:40"),
        #("LUNCH_END", "13:55"),
        #("EXIT_TIME", "19:00"),
      ]),
    )
    == Error(config.StretchCouldBeTooLong(
      period: "afternoon",
      worst: 315,
      allowed: 300,
    ))
}

// The bank the receipt cannot see, copied off the last folha. Written the way
// the sheet writes it: a signed figure and the month it closes.
pub fn the_carried_bank_is_read_from_the_folha_test() {
  let assert Ok(loaded) =
    config.from_env(
      env([
        #("BANK_CARRIED_THROUGH", "2026-08"),
        #("BANK_CARRIED_MINUTES", "+851"),
      ]),
    )

  assert loaded.carried_bank == Ok(balance.Carried(2026, 8, 851))

  // A bank runs both ways, so the figure takes a sign.
  let assert Ok(in_debt) =
    config.from_env(
      env([
        #("BANK_CARRIED_THROUGH", "2026-12"),
        #("BANK_CARRIED_MINUTES", "-90"),
      ]),
    )

  assert in_debt.carried_bank == Ok(balance.Carried(2026, 12, -90))
}

// Nothing configured is the honest default: no folha means the room left is
// this month's, and the report says so rather than assuming an empty bank.
pub fn no_folha_configured_is_not_an_empty_bank_test() {
  let assert Ok(loaded) = config.from_env(env([]))

  assert loaded.carried_bank == Error(Nil)
}

// Half of it is a mistake, not a default. A figure with no month cannot be
// matched against the month being reported, and matching is the whole point.
pub fn half_a_carried_bank_is_refused_test() {
  assert config.from_env(env([#("BANK_CARRIED_MINUTES", "851")]))
    == Error(config.IncompleteCarriedBank)

  assert config.from_env(env([#("BANK_CARRIED_THROUGH", "2026-08")]))
    == Error(config.IncompleteCarriedBank)
}

pub fn a_carried_month_has_to_be_a_month_test() {
  let through = fn(raw) {
    config.from_env(
      env([#("BANK_CARRIED_THROUGH", raw), #("BANK_CARRIED_MINUTES", "851")]),
    )
  }

  assert through("agosto")
    == Error(config.NotAMonth("BANK_CARRIED_THROUGH", "agosto"))
  assert through("2026-13")
    == Error(config.NotAMonth("BANK_CARRIED_THROUGH", "2026-13"))
  assert through("2026-08-31")
    == Error(config.NotAMonth("BANK_CARRIED_THROUGH", "2026-08-31"))
}
