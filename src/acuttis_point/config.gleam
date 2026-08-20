//// Runtime configuration.
////
//// Nothing here is hardcoded in the rules: the whole schedule arrives as a
//// plain string map, which the FFI fills from the process environment and
//// tests fill by hand. Credentials deliberately live elsewhere, so a `Config`
//// is always safe to print.

import acuttis_point/clock
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
    /// Holidays, days off and anything else without an expedient.
    skip_dates: List(clock.Date),
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
  /// Both ways of claiming at once. Refused rather than resolved, because the
  /// two mean different things and guessing which was meant could punch.
  ConflictingClaim
}

const default_base_url = "https://app.acuttis.com.br"

const default_work_days = "MON,TUE,WED,THU,FRI"

const default_timezone = "America/Sao_Paulo"

const default_tolerance_minutes = 10

const default_timeout_seconds = 30

const default_pending_file = "state/pending.json"

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
  use skip_dates <- result.try(date_list(env, "SKIP_DATES"))
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

  let timezone = lookup_or(env, "TIMEZONE", default_timezone)
  use schedule <- result.try(
    ordered_schedule(Schedule(entry:, lunch_start:, lunch_end:, exit:)),
  )
  use schedule <- result.try(long_enough_lunch(
    schedule,
    tolerance_minutes,
    min_lunch_minutes,
  ))

  Ok(Config(
    base_url:,
    work_days:,
    schedule:,
    tolerance_minutes:,
    min_lunch_minutes:,
    timezone:,
    skip_dates:,
    dry_run:,
    timeout_seconds:,
    headless:,
    discover:,
    preflight:,
    ask:,
    pending_file:,
    claim:,
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
  <> "m skipped="
  <> int.to_string(list.length(config.skip_dates))
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
