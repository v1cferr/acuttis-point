//// Runtime configuration.
////
//// Nothing here is hardcoded in the rules: the whole schedule arrives as a
//// plain string map, which the FFI fills from the process environment and
//// tests fill by hand. Credentials deliberately live elsewhere, so a `Config`
//// is always safe to print.

import acuttis_point/balance
import acuttis_point/clock
import acuttis_point/holiday
import acuttis_point/punch
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The time each punch of the day is expected at.
pub type Schedule {
  Schedule(
    entry: clock.TimeOfDay,
    lunch_start: clock.TimeOfDay,
    lunch_end: clock.TimeOfDay,
    exit: clock.TimeOfDay,
  )
}

pub type Config {
  Config(
    base_url: String,
    work_days: List(clock.Weekday),
    schedule: Schedule,
    /// How long after a scheduled time a punch may still be registered.
    tolerance_minutes: Int,
    /// The shortest lunch break the schedule is allowed to be able to produce.
    /// Not a target but a floor: a schedule whose worst case falls under it is
    /// refused, rather than left to come out short on an unlucky day.
    min_lunch_minutes: Int,
    timezone: String,
    /// Which days have no expedient: the holidays that can be derived, the
    /// ones that cannot, FAI's emenda, and whatever is declared by hand.
    calendar: holiday.Calendar,
    /// Where `scripts/calendar.sh` leaves the holidays that cannot be derived —
    /// the municipal and state ones. Read at startup and merged into the
    /// calendar above; missing is not an error, it just leaves the derived
    /// national holidays on their own.
    local_holidays_file: String,
    /// Days the calendar called off and a human said had expedient after all,
    /// one `YYYY-MM-DD` per line. Written by an answered question.
    expedient_file: String,
    /// The questions already asked, so a day off is asked about once rather
    /// than at every window of it.
    questions_file: String,
    /// Ask, on a day without expedient, whether the calendar got it right.
    /// Off makes such a day silent again.
    ask_about_calendar: Bool,
    /// This run is carrying the answer to one of those questions.
    answer: Result(String, Nil),
    /// Decide and log, but never touch Acuttis.
    dry_run: Bool,
    /// How long any single browser step may take.
    timeout_seconds: Int,
    /// False shows the browser, which is how the punch selectors get found.
    headless: Bool,
    /// Sign in, describe the page, and stop. Clicks no punch control at all,
    /// which is the only way to look at the real interface with no chance of
    /// registering a punch.
    discover: Bool,
    /// Rehearse the punch shortly before it is due: sign in, read the day, and
    /// check the punch button would take a click. Registers nothing.
    preflight: Bool,
    /// Ask instead of acting: decide as usual, then offer a one-time token and
    /// let a tap on the phone spend it. Registers nothing itself.
    ask: Bool,
    /// Where that token lives. One file, and taking it is what authorises a
    /// punch — see `pending`.
    pending_file: String,
    /// Spend a token that was offered earlier, and punch.
    claim: Claim,
    /// Read the whole receipt and report the days that do not add up. Registers
    /// nothing, clicks no punch control.
    audit: Bool,
    /// The working day the balance is measured against. Derived from the
    /// schedule unless set, so there is one place the day's shape is written
    /// down — but a contract is a contract, and DAILY_MINUTES overrides it.
    daily_minutes: Int,
    /// The most the hour bank may hold either way. Reported, not enforced:
    /// nothing here can stop hours accumulating.
    ///
    /// FAI's own limite de compensação is 40 hours, and this is not that
    /// number. On 2026-10 the coordinator asked for ten either way, and of two
    /// ceilings the tighter one is the one that applies.
    compensation_limit_minutes: Int,
    /// Past this the bank is not a number to watch any more. Double the
    /// ceiling, by default.
    bank_alarm_minutes: Int,
    /// Where the bank stood when FAI last closed a folha, and which month that
    /// folha closes. Their sheet is the only record of the months the receipt no
    /// longer reaches, so without it the room left against the limit is only
    /// this month's, which reads as more room than there is.
    carried_bank: Result(balance.Carried, Nil),
    /// The dates already announced, so a day is only reported once. The days
    /// already sent to Gestão de Pessoas stay wrong in Acuttis until they fix
    /// them, and an audit repeating itself every evening teaches its reader to
    /// ignore it.
    announced_file: String,
    /// Where to drop a screenshot when a run fails. The page at that moment is
    /// the only witness to an interface that changed.
    screenshot_dir: Result(String, Nil),
    /// Send the browser's traffic through this proxy, so the punch reaches
    /// Acuttis from somewhere other than this machine's address. What it is for
    /// here is arriving from inside the university network: the punch is a
    /// record of being at work, and the address it comes from is part of that
    /// record. `scripts/with-fai-proxy.sh` opens one over ssh for the length of
    /// a single run.
    proxy_server: Result(String, Nil),
  )
}

/// Who is asking to spend the pending token.
pub type Claim {
  /// Nobody: this run is not here to spend anything.
  NoClaim
  /// A tap on the notification, quoting the token it was given.
  WithToken(String)
  /// The deadline, which takes whatever is pending. It has no token to quote
  /// because nobody types one into a timer.
  AtDeadline
}

pub type ConfigError {
  MissingKey(key: String)
  InvalidValue(key: String, value: String, reason: clock.ClockError)
  NotAnInteger(key: String, value: String)
  OutOfRange(key: String, value: String, minimum: Int, maximum: Int)
  NotABoolean(key: String, value: String)
  EmptyValue(key: String)
  InsecureUrl(key: String, value: String)
  /// A proxy address the browser would not understand. Refused rather than
  /// ignored: a proxy silently dropped means the run goes out from here, which
  /// is the one thing configuring it was meant to prevent.
  UnsupportedProxy(key: String, value: String)
  /// The configured times do not run forward through the day.
  ScheduleOutOfOrder(earlier: punch.Punch, later: punch.Punch)
  /// The schedule could produce a lunch break shorter than allowed.
  LunchCouldBeTooShort(guaranteed: Int, required: Int)
  /// The schedule could produce a stretch of work longer than allowed without a
  /// break.
  StretchCouldBeTooLong(period: String, worst: Int, allowed: Int)
  /// Both ways of claiming at once. Refused rather than resolved, because the
  /// two mean different things and guessing which was meant could punch.
  ConflictingClaim
  /// A month written some way other than YYYY-MM.
  NotAMonth(key: String, value: String)
  /// Half of the carried bank: a figure with no month, or a month with no
  /// figure. Refused rather than half-applied, because a figure whose month is
  /// unknown cannot be checked against the month being reported.
  IncompleteCarriedBank
  /// A local holiday with no name. Refused rather than named after its own
  /// date: a notification saying the day off is "2026-11-04" explains nothing,
  /// and an emenda has to be able to name the holiday it bridges.
  NamelessHoliday(key: String, value: String)
}

const default_base_url = "https://app.acuttis.com.br"

const default_work_days = "MON,TUE,WED,THU,FRI"

const default_timezone = "America/Sao_Paulo"

const default_tolerance_minutes = 10

const default_timeout_seconds = 30

const default_pending_file = "state/pending.json"

const default_announced_file = "state/announced.txt"

const default_local_holidays_file = "state/local-holidays.txt"

const default_expedient_file = "state/expedient.txt"

const default_questions_file = "state/questions.txt"

/// Ten hours. FAI's own limite de compensação is forty, and this is not that:
/// on 2026-10 the coordinator asked for ten either way, and the tighter of two
/// ceilings is the one that applies.
const default_compensation_limit_minutes = 600

/// Twenty hours: double the ceiling, and the point at which the bank stops
/// being a number to watch.
const default_bank_alarm_minutes = 1200

/// Five hours, which is FAI's limit on working without a break: "garantir que a
/// carga de trabalho não exceda 5 horas consecutivas em ambos os períodos".
const default_max_consecutive_minutes = 300

/// One hour, which is the legal minimum in Brazil for a working day over six
/// hours. A floor rather than a default to aim at.
const default_min_lunch_minutes = 60

/// Largest accepted tolerance. Four hours is already generous; beyond that a
/// late run would be registering a time that has little to do with reality.
const max_tolerance_minutes = 240

pub fn from_env(env: Dict(String, String)) -> Result(Config, ConfigError) {
  use base_url <- result.try(secure_url(env, "ACUTTIS_URL", default_base_url))
  use work_days <- result.try(weekday_list(env, "WORK_DAYS"))
  use entry <- result.try(time(env, "ENTRY_TIME"))
  use lunch_start <- result.try(time(env, "LUNCH_START"))
  use lunch_end <- result.try(time(env, "LUNCH_END"))
  use exit <- result.try(time(env, "EXIT_TIME"))
  use tolerance_minutes <- result.try(bounded_int(
    env,
    "TIME_TOLERANCE_MINUTES",
    default_tolerance_minutes,
    0,
    max_tolerance_minutes,
  ))
  use calendar <- result.try(calendar(env))
  use dry_run <- result.try(boolean(env, "DRY_RUN", False))
  use timeout_seconds <- result.try(bounded_int(
    env,
    "STEP_TIMEOUT_SECONDS",
    default_timeout_seconds,
    5,
    300,
  ))
  use min_lunch_minutes <- result.try(bounded_int(
    env,
    "MIN_LUNCH_MINUTES",
    default_min_lunch_minutes,
    0,
    480,
  ))
  use headless <- result.try(boolean(env, "HEADLESS", True))
  use discover <- result.try(boolean(env, "DISCOVER", False))
  use preflight <- result.try(boolean(env, "PREFLIGHT", False))
  use ask <- result.try(boolean(env, "ASK", False))
  use audit <- result.try(boolean(env, "AUDIT", False))
  let announced_file = lookup_or(env, "ANNOUNCED_FILE", default_announced_file)
  let local_holidays_file =
    lookup_or(env, "LOCAL_HOLIDAYS_FILE", default_local_holidays_file)
  let expedient_file = lookup_or(env, "EXPEDIENT_FILE", default_expedient_file)
  let questions_file = lookup_or(env, "QUESTIONS_FILE", default_questions_file)
  use ask_about_calendar <- result.try(boolean(env, "ASK_ABOUT_CALENDAR", True))
  let answer = optional(env, "ANSWER_TOKEN")
  use claim_deadline <- result.try(boolean(env, "CLAIM_DEADLINE", False))
  use claim <- result.try(case optional(env, "CLAIM_TOKEN"), claim_deadline {
    Ok(_), True -> Error(ConflictingClaim)
    Ok(token), False -> Ok(WithToken(token))
    Error(Nil), True -> Ok(AtDeadline)
    Error(Nil), False -> Ok(NoClaim)
  })
  let pending_file = lookup_or(env, "PENDING_FILE", default_pending_file)
  use proxy_server <- result.try(proxy(env, "PROXY_SERVER"))
  let screenshot_dir = optional(env, "SCREENSHOT_DIR")

  use max_consecutive_minutes <- result.try(bounded_int(
    env,
    "MAX_CONSECUTIVE_MINUTES",
    default_max_consecutive_minutes,
    60,
    720,
  ))
  let timezone = lookup_or(env, "TIMEZONE", default_timezone)
  use schedule <- result.try(
    ordered_schedule(Schedule(entry:, lunch_start:, lunch_end:, exit:)),
  )
  use schedule <- result.try(long_enough_lunch(
    schedule,
    tolerance_minutes,
    min_lunch_minutes,
  ))
  use schedule <- result.try(short_enough_stretches(
    schedule,
    tolerance_minutes,
    max_consecutive_minutes,
  ))

  use compensation_limit_minutes <- result.try(bounded_int(
    env,
    "COMPENSATION_LIMIT_MINUTES",
    default_compensation_limit_minutes,
    0,
    // A thousand hours. Past that it is not a compensation limit.
    60_000,
  ))
  use bank_alarm_minutes <- result.try(bounded_int(
    env,
    "BANK_ALARM_MINUTES",
    default_bank_alarm_minutes,
    0,
    60_000,
  ))
  use carried_bank <- result.try(carried_bank(env))
  use daily_minutes <- result.try(bounded_int(
    env,
    "DAILY_MINUTES",
    nominal_day_minutes(schedule),
    1,
    // Twelve hours. Past that it is not a working day being described.
    720,
  ))

  Ok(Config(
    base_url:,
    work_days:,
    schedule:,
    tolerance_minutes:,
    min_lunch_minutes:,
    timezone:,
    calendar:,
    local_holidays_file:,
    expedient_file:,
    questions_file:,
    ask_about_calendar:,
    answer:,
    dry_run:,
    timeout_seconds:,
    headless:,
    discover:,
    preflight:,
    ask:,
    pending_file:,
    claim:,
    audit:,
    daily_minutes:,
    compensation_limit_minutes:,
    bank_alarm_minutes:,
    carried_bank:,
    announced_file:,
    screenshot_dir:,
    proxy_server:,
  ))
}

/// The shortest lunch this schedule could produce, in minutes.
///
/// Worst case in both directions at once: the punch leaving for lunch lands as
/// late as its window allows, and the one returning lands as early as its window
/// allows. Both punches can happen anywhere inside `[time, time + tolerance]`,
/// so the floor is what the later start and the earlier return leave between
/// them — and it does not depend on how the timer happens to be jittered.
pub fn guaranteed_lunch_minutes(
  schedule: Schedule,
  tolerance_minutes: Int,
) -> Int {
  clock.minutes_between(from: schedule.lunch_start, to: schedule.lunch_end)
  - tolerance_minutes
}

fn long_enough_lunch(
  schedule: Schedule,
  tolerance_minutes: Int,
  required: Int,
) -> Result(Schedule, ConfigError) {
  let guaranteed = guaranteed_lunch_minutes(schedule, tolerance_minutes)
  case guaranteed < required {
    True ->
      Error(LunchCouldBeTooShort(guaranteed: guaranteed, required: required))
    False -> Ok(schedule)
  }
}

/// The day the schedule describes: first punch to last, less the break between
/// them. With entry 07:51, lunch 12:35 to 13:51 and exit 17:30 that is 8h23.
///
/// Derived rather than configured by default, so the balance is measured against
/// the same day the punches are scheduled around instead of a second number that
/// can quietly disagree with the first.
pub fn nominal_day_minutes(schedule: Schedule) -> Int {
  clock.minutes_between(from: schedule.entry, to: schedule.exit)
  - clock.minutes_between(from: schedule.lunch_start, to: schedule.lunch_end)
}

/// The longest either period could run, and a refusal when that is too long.
///
/// The worst case is the punch opening a period landing on time and the one
/// closing it landing as late as the tolerance allows. FAI treats five
/// consecutive hours as a limit the coordinator monitors rather than one the
/// system blocks — their own folha shows 27/07 at 5h01 and 30/07 at 5h03,
/// credited in full — but a schedule that can produce a breach will produce one,
/// and configuration time is the cheapest place to find that out.
///
/// It would have refused a lunch at 12:45 against an entry at 07:51: 5h04 in the
/// worst case. At 12:40 the worst case is 4h59.
fn short_enough_stretches(
  schedule: Schedule,
  tolerance_minutes: Int,
  allowed: Int,
) -> Result(Schedule, ConfigError) {
  let morning =
    clock.minutes_between(from: schedule.entry, to: schedule.lunch_start)
    + tolerance_minutes
  let afternoon =
    clock.minutes_between(from: schedule.lunch_end, to: schedule.exit)
    + tolerance_minutes

  case morning > allowed, afternoon > allowed {
    True, _ ->
      Error(StretchCouldBeTooLong(
        period: "morning",
        worst: morning,
        allowed: allowed,
      ))
    _, True ->
      Error(StretchCouldBeTooLong(
        period: "afternoon",
        worst: afternoon,
        allowed: allowed,
      ))
    _, _ -> Ok(schedule)
  }
}

pub fn scheduled_time(
  schedule: Schedule,
  target: punch.Punch,
) -> clock.TimeOfDay {
  case target {
    punch.Entry -> schedule.entry
    punch.LunchStart -> schedule.lunch_start
    punch.LunchEnd -> schedule.lunch_end
    punch.Exit -> schedule.exit
  }
}

/// The next punch the schedule expects after this moment, if the day has one
/// left. Read from the configuration alone, so it can be answered without
/// opening a browser — which is what makes it usable in the reply to a tap that
/// arrived too late to do anything else.
pub fn next_scheduled(
  schedule: Schedule,
  after: clock.TimeOfDay,
) -> Result(#(punch.Punch, clock.TimeOfDay), Nil) {
  punch.sequence
  |> list.map(fn(target) { #(target, scheduled_time(schedule, target)) })
  |> list.filter(fn(pair) {
    clock.minutes_since_midnight(pair.1) > clock.minutes_since_midnight(after)
  })
  |> list.first
}

/// The effective settings, for the header of a run log. Safe to print: a
/// `Config` never carries credentials.
pub fn describe(config: Config) -> String {
  let days =
    config.work_days
    |> list.map(clock.weekday_to_string)
    |> string.join(",")
  let times =
    punch.sequence
    |> list.map(fn(target) {
      punch.to_string(target)
      <> "="
      <> clock.time_to_string(scheduled_time(config.schedule, target))
    })
    |> string.join(" ")

  "url="
  <> config.base_url
  <> " days="
  <> days
  <> " "
  <> times
  <> " tolerance="
  <> int.to_string(config.tolerance_minutes)
  <> "m tz="
  <> config.timezone
  <> " lunch>="
  <> int.to_string(guaranteed_lunch_minutes(
    config.schedule,
    config.tolerance_minutes,
  ))
  <> "m calendar="
  <> holiday.describe(config.calendar)
  <> " dry_run="
  <> bool_to_string(config.dry_run)
  <> case config.proxy_server {
    Error(Nil) -> ""
    Ok(server) -> " proxy=" <> server
  }
}

pub fn error_to_string(error: ConfigError) -> String {
  case error {
    MissingKey(key:) -> key <> " is not set"
    InvalidValue(key:, value:, reason:) ->
      key <> "=" <> value <> " is invalid: " <> clock_error_to_string(reason)
    NotAnInteger(key:, value:) -> key <> "=" <> value <> " is not an integer"
    OutOfRange(key:, value:, minimum:, maximum:) ->
      key
      <> "="
      <> value
      <> " is outside "
      <> int.to_string(minimum)
      <> ".."
      <> int.to_string(maximum)
    NotABoolean(key:, value:) ->
      key <> "=" <> value <> " is not a boolean, use true or false"
    EmptyValue(key:) -> key <> " is empty"
    InsecureUrl(key:, value:) ->
      key <> "=" <> value <> " must be an https:// url"
    StretchCouldBeTooLong(period:, worst:, allowed:) ->
      "this schedule could have you working "
      <> int.to_string(worst)
      <> " minutes straight in the "
      <> period
      <> ", over the "
      <> int.to_string(allowed)
      <> " allowed; move a lunch punch, or raise MAX_CONSECUTIVE_MINUTES"
    ConflictingClaim ->
      "CLAIM_TOKEN and CLAIM_DEADLINE are both set, and they mean different"
      <> " things; use one"
    UnsupportedProxy(key:, value:) ->
      key
      <> "="
      <> value
      <> " needs a scheme the browser understands: socks5://, socks4://,"
      <> " http:// or https://"
    ScheduleOutOfOrder(earlier:, later:) ->
      punch.to_string(later)
      <> " is scheduled before "
      <> punch.to_string(earlier)
    NotAMonth(key:, value:) ->
      key <> "=" <> value <> " is not a month, write it as YYYY-MM"
    NamelessHoliday(key:, value:) ->
      key
      <> "="
      <> value
      <> " needs a name, write it as YYYY-MM-DD=Aniversario de Sao Carlos"
    IncompleteCarriedBank ->
      "BANK_CARRIED_MINUTES and BANK_CARRIED_THROUGH are one figure and the"
      <> " month it closes; set both or neither"
    LunchCouldBeTooShort(guaranteed:, required:) ->
      "this schedule could produce a lunch break of only "
      <> int.to_string(guaranteed)
      <> " minutes, under the "
      <> int.to_string(required)
      <> " required; move LUNCH_END later, LUNCH_START earlier, or lower"
      <> " TIME_TOLERANCE_MINUTES"
  }
}

fn clock_error_to_string(error: clock.ClockError) -> String {
  case error {
    clock.HourOutOfRange(hour) -> "hour " <> int.to_string(hour)
    clock.MinuteOutOfRange(minute) -> "minute " <> int.to_string(minute)
    clock.MalformedTime(raw) -> "expected HH:MM, got " <> raw
    clock.UnknownWeekday(raw) -> "unknown weekday " <> raw
    clock.YearOutOfRange(year) -> "year " <> int.to_string(year)
    clock.MonthOutOfRange(month) -> "month " <> int.to_string(month)
    clock.DayOutOfRange(day) -> "day " <> int.to_string(day)
    clock.MalformedDate(raw) -> "expected YYYY-MM-DD, got " <> raw
  }
}

fn bool_to_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

/// The punches have to run forward through the day, otherwise the windows
/// overlap and the decision rules lose their meaning.
fn ordered_schedule(schedule: Schedule) -> Result(Schedule, ConfigError) {
  let ordered =
    punch.sequence
    |> list.map(fn(target) { #(target, scheduled_time(schedule, target)) })

  case check_ascending(ordered) {
    Error(error) -> Error(error)
    Ok(_) -> Ok(schedule)
  }
}

fn check_ascending(
  entries: List(#(punch.Punch, clock.TimeOfDay)),
) -> Result(Nil, ConfigError) {
  case entries {
    [#(earlier, earlier_at), #(later, later_at), ..rest] ->
      case clock.minutes_between(from: earlier_at, to: later_at) < 0 {
        True -> Error(ScheduleOutOfOrder(earlier: earlier, later: later))
        False -> check_ascending([#(later, later_at), ..rest])
      }
    _ -> Ok(Nil)
  }
}

/// A value that is present but blank counts as missing: an `EnvironmentFile`
/// line like `ENTRY_TIME=` should not slip through as a default.
fn lookup(
  env: Dict(String, String),
  key: String,
) -> Result(String, ConfigError) {
  case dict.get(env, key) {
    Error(Nil) -> Error(MissingKey(key))
    Ok(value) ->
      case string.trim(value) {
        "" -> Error(MissingKey(key))
        trimmed -> Ok(trimmed)
      }
  }
}

/// Absent or blank both mean "not configured".
fn optional(env: Dict(String, String), key: String) -> Result(String, Nil) {
  case lookup(env, key) {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn lookup_or(
  env: Dict(String, String),
  key: String,
  fallback: String,
) -> String {
  case lookup(env, key) {
    Ok(value) -> value
    Error(_) -> fallback
  }
}

fn time(
  env: Dict(String, String),
  key: String,
) -> Result(clock.TimeOfDay, ConfigError) {
  use raw <- result.try(lookup(env, key))
  clock.parse_time(raw)
  |> result.map_error(fn(reason) {
    InvalidValue(key: key, value: raw, reason: reason)
  })
}

fn weekday_list(
  env: Dict(String, String),
  key: String,
) -> Result(List(clock.Weekday), ConfigError) {
  let raw = lookup_or(env, key, default_work_days)
  use days <- result.try(
    raw
    |> split_list
    |> list.try_map(fn(item) {
      clock.parse_weekday(item)
      |> result.map_error(fn(reason) {
        InvalidValue(key: key, value: item, reason: reason)
      })
    }),
  )
  case days {
    [] -> Error(EmptyValue(key))
    _ -> Ok(list.unique(days))
  }
}

/// The calendar of days without expedient.
///
/// Four keys, because they are four different claims. `NATIONAL_HOLIDAYS` turns
/// on the ones derivable from the year alone; `LOCAL_HOLIDAYS` carries the ones
/// that are not. Of those, the state and municipal ones repeat on the same date
/// every year and go in `ANNUAL_HOLIDAYS` as a rule, so they keep working in a
/// year no published calendar has reached; `LOCAL_HOLIDAYS` is for one
/// particular date that even that cannot predict. `BRIDGE_HOLIDAYS` is FAI's
/// emenda, and `SKIP_DATES` is a day off that is nobody's holiday.
fn calendar(
  env: Dict(String, String),
) -> Result(holiday.Calendar, ConfigError) {
  use national <- result.try(boolean(env, "NATIONAL_HOLIDAYS", True))
  use bridges <- result.try(boolean(env, "BRIDGE_HOLIDAYS", True))
  use annual <- result.try(annual_list(env, "ANNUAL_HOLIDAYS"))
  use local <- result.try(named_date_list(env, "LOCAL_HOLIDAYS"))
  use declared <- result.try(date_list(env, "SKIP_DATES"))

  Ok(
    holiday.Calendar(
      national: national,
      annual: annual,
      local: local,
      declared: declared,
      bridges: bridges,
      with_expedient: [],
    ),
  )
}

/// `MM-DD=Name`, comma separated: a holiday on the same date every year.
///
/// The state and municipal ones go here. They are law rather than a yearly
/// publication — São Paulo's 09-07, São Carlos' 08-15 and 11-04 — so writing
/// them as a rule is what keeps them working in a year no published calendar
/// has reached yet.
///
/// Validated against a leap year, so 02-29 is a date somebody may legitimately
/// mean; in the years it does not exist it simply never matches.
fn annual_list(
  env: Dict(String, String),
  key: String,
) -> Result(List(#(Int, Int, String)), ConfigError) {
  case lookup(env, key) {
    Error(_) -> Ok([])
    Ok(raw) ->
      raw
      |> split_list
      |> list.try_map(fn(item) {
        case string.split_once(item, on: "=") {
          Error(Nil) -> Error(NamelessHoliday(key: key, value: item))
          Ok(#(when, name)) ->
            case string.split(string.trim(when), on: "-"), string.trim(name) {
              _, "" -> Error(NamelessHoliday(key: key, value: item))
              [month, day], name ->
                case int.parse(month), int.parse(day) {
                  Ok(month), Ok(day) ->
                    clock.new_date(year: 2024, month: month, day: day)
                    |> result.map(fn(_) { #(month, day, name) })
                    |> result.map_error(fn(reason) {
                      InvalidValue(key: key, value: item, reason: reason)
                    })
                  _, _ ->
                    Error(InvalidValue(
                      key: key,
                      value: item,
                      reason: clock.MalformedDate(when),
                    ))
                }
              _, _ ->
                Error(InvalidValue(
                  key: key,
                  value: item,
                  reason: clock.MalformedDate(when),
                ))
            }
        }
      })
  }
}

/// `YYYY-MM-DD=Name`, comma separated. The name is not optional: see
/// `NamelessHoliday`.
fn named_date_list(
  env: Dict(String, String),
  key: String,
) -> Result(List(#(clock.Date, String)), ConfigError) {
  case lookup(env, key) {
    Error(_) -> Ok([])
    Ok(raw) ->
      raw
      |> split_list
      |> list.try_map(fn(item) {
        case string.split_once(item, on: "=") {
          Error(Nil) -> Error(NamelessHoliday(key: key, value: item))
          Ok(#(date, name)) ->
            case string.trim(name) {
              "" -> Error(NamelessHoliday(key: key, value: item))
              name ->
                clock.parse_date(date)
                |> result.map(fn(date) { #(date, name) })
                |> result.map_error(fn(reason) {
                  InvalidValue(key: key, value: item, reason: reason)
                })
            }
        }
      })
  }
}

fn date_list(
  env: Dict(String, String),
  key: String,
) -> Result(List(clock.Date), ConfigError) {
  case lookup(env, key) {
    // Skip dates are optional: no holidays configured is a valid setup.
    Error(_) -> Ok([])
    Ok(raw) ->
      raw
      |> split_list
      |> list.try_map(fn(item) {
        clock.parse_date(item)
        |> result.map_error(fn(reason) {
          InvalidValue(key: key, value: item, reason: reason)
        })
      })
  }
}

fn bounded_int(
  env: Dict(String, String),
  key: String,
  fallback: Int,
  minimum: Int,
  maximum: Int,
) -> Result(Int, ConfigError) {
  case lookup(env, key) {
    Error(_) -> Ok(fallback)
    Ok(raw) ->
      case int.parse(raw) {
        Error(Nil) -> Error(NotAnInteger(key: key, value: raw))
        Ok(value) ->
          case value < minimum || value > maximum {
            True ->
              Error(OutOfRange(
                key: key,
                value: raw,
                minimum: minimum,
                maximum: maximum,
              ))
            False -> Ok(value)
          }
      }
  }
}

/// The bank as the last folha closed it. Both keys or neither: a figure with no
/// month cannot be matched against the month being reported, and a month with no
/// figure says nothing at all. Half of it configured is a mistake to refuse, not
/// a default to guess at.
fn carried_bank(
  env: Dict(String, String),
) -> Result(Result(balance.Carried, Nil), ConfigError) {
  case
    optional(env, "BANK_CARRIED_THROUGH"),
    optional(env, "BANK_CARRIED_MINUTES")
  {
    Error(Nil), Error(Nil) -> Ok(Error(Nil))
    Ok(_), Error(Nil) | Error(Nil), Ok(_) -> Error(IncompleteCarriedBank)
    Ok(through), Ok(minutes) -> {
      use #(year, month) <- result.try(year_month(
        "BANK_CARRIED_THROUGH",
        through,
      ))
      use minutes <- result.try(signed_int(
        "BANK_CARRIED_MINUTES",
        minutes,
        // A thousand hours either way, the same bound the limit itself takes.
        -60_000,
        60_000,
      ))
      Ok(Ok(balance.Carried(year: year, month: month, minutes: minutes)))
    }
  }
}

fn year_month(key: String, raw: String) -> Result(#(Int, Int), ConfigError) {
  case string.split(raw, on: "-") {
    [year, month] ->
      // `08` parses as eight, so a month copied straight off the folha reads.
      case int.parse(year), int.parse(month) {
        Ok(year), Ok(month) if month >= 1 && month <= 12 && year >= 2000 ->
          Ok(#(year, month))
        _, _ -> Error(NotAMonth(key: key, value: raw))
      }
    _ -> Error(NotAMonth(key: key, value: raw))
  }
}

/// A bank figure reads either way, so unlike the other numbers here this one
/// takes a sign — and a leading `+`, which is how the folha writes a credit.
fn signed_int(
  key: String,
  raw: String,
  minimum: Int,
  maximum: Int,
) -> Result(Int, ConfigError) {
  let digits = case string.starts_with(raw, "+") {
    True -> string.drop_start(raw, 1)
    False -> raw
  }

  case int.parse(digits) {
    Error(Nil) -> Error(NotAnInteger(key: key, value: raw))
    Ok(value) ->
      case value < minimum || value > maximum {
        True ->
          Error(OutOfRange(
            key: key,
            value: raw,
            minimum: minimum,
            maximum: maximum,
          ))
        False -> Ok(value)
      }
  }
}

fn boolean(
  env: Dict(String, String),
  key: String,
  fallback: Bool,
) -> Result(Bool, ConfigError) {
  case lookup(env, key) {
    Error(_) -> Ok(fallback)
    Ok(raw) ->
      case string.lowercase(raw) {
        "1" | "true" | "yes" | "on" -> Ok(True)
        "0" | "false" | "no" | "off" -> Ok(False)
        _ -> Error(NotABoolean(key: key, value: raw))
      }
  }
}

/// A proxy the browser can actually be pointed at. Chromium takes the scheme as
/// part of the address, and a hostname with no scheme is read as http, which
/// would quietly turn a SOCKS tunnel into a failed connection.
fn proxy(
  env: Dict(String, String),
  key: String,
) -> Result(Result(String, Nil), ConfigError) {
  case optional(env, key) {
    Error(Nil) -> Ok(Error(Nil))
    Ok(raw) ->
      case supported_proxy(raw) {
        True -> Ok(Ok(raw))
        False -> Error(UnsupportedProxy(key: key, value: raw))
      }
  }
}

fn supported_proxy(raw: String) -> Bool {
  let schemes = ["socks5://", "socks4://", "http://", "https://"]
  list.any(schemes, fn(scheme) {
    string.starts_with(raw, scheme)
    && string.length(raw) > string.length(scheme)
  })
}

/// Https, or plain http on the loopback interface. The reason to demand https
/// is that credentials cross a network; talking to a fixture on this machine
/// has no network to cross.
fn secure_url(
  env: Dict(String, String),
  key: String,
  fallback: String,
) -> Result(String, ConfigError) {
  let raw = lookup_or(env, key, fallback)
  case string.starts_with(raw, "https://") || is_loopback(raw) {
    True -> Ok(string.drop_end(raw, count_trailing_slashes(raw)))
    False -> Error(InsecureUrl(key: key, value: raw))
  }
}

fn is_loopback(raw: String) -> Bool {
  string.starts_with(raw, "http://localhost")
  || string.starts_with(raw, "http://127.0.0.1")
  || string.starts_with(raw, "http://[::1]")
}

fn count_trailing_slashes(raw: String) -> Int {
  case string.ends_with(raw, "/") {
    False -> 0
    True -> 1 + count_trailing_slashes(string.drop_end(raw, 1))
  }
}

fn split_list(raw: String) -> List(String) {
  raw
  |> string.split(on: ",")
  |> list.map(string.trim)
  |> list.filter(fn(item) { item != "" })
}
