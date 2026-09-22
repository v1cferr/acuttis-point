//// Which days have no expediente, and why.
////
//// Three sources, and they are not the same kind of thing.
////
//// The national holidays are a rule, not a list: nine fixed dates and four that
//// move with Easter, computed for whatever year is asked about. A list would
//// have to be extended every December, and the December it is forgotten is the
//// September the automation punches on Independence Day — which is exactly what
//// happened on 2026-09-07, at 07:51, with a phone asking whether to register
//// the entry of a national holiday.
////
//// The state and municipal ones cannot be derived from the year, but they are
//// not a publication either: they are law, and law repeats. São Paulo has one
//// state holiday and São Carlos has four, and of those four, two already move
//// with Easter. What is left is three fixed dates — 09/07, 15/08, 04/11 — which
//// are a rule like any other, just a rule this program has to be told once.
//// That is `annual`.
////
//// Dated entries are for what even that cannot predict: a recesso, a day FAI
//// closes for its own reasons, a municipal holiday moved by decree in one year.
//// They are declared *with a name*, because a day off has to be able to say
//// what it is — and because the emenda below needs to name the holiday it
//// bridges.
////
//// The emenda is the third, and it is on no calendar at all. FAI takes the
//// working day left standing between a holiday and the weekend: a holiday on
//// Thursday costs the Friday, one on Tuesday costs the Monday. Derived rather
//// than declared, for the same reason the national ones are.
////
//// A holiday in the middle of the week bridges nothing — one day off does not
//// reach the weekend from a Wednesday — and neither does a day merely declared
//// off. Leave is not a holiday, and nobody emendas a vacation.

import acuttis_point/clock
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// The holidays this knows by name. Named rather than stringly typed so the
/// Portuguese they are said in lives in `ptbr` with the rest of the phone's
/// words, and so a misspelling is a compile error rather than a notification.
pub type Holiday {
  NewYear
  /// Both days of it. Monday and Tuesday are one holiday as far as a day
  /// without expediente is concerned.
  Carnival
  GoodFriday
  Tiradentes
  LabourDay
  CorpusChristi
  Independence
  OurLadyOfAparecida
  AllSouls
  RepublicDay
  BlackConsciousness
  Christmas
  /// One this cannot derive: municipal, institutional, FAI's own. It arrives
  /// from the configuration carrying the name it is known by.
  Local(name: String)
}

/// Why a day has no expediente.
pub type Reason {
  /// The day is the holiday.
  Observed(Holiday)
  /// The day is the emenda: a working day taken off because it was the only
  /// one left between `holiday`, on `date`, and the weekend.
  Bridge(holiday: Holiday, date: clock.Date)
  /// Declared off with no name — leave, a recesso, a one-off. It bridges
  /// nothing.
  Declared
}

pub type Calendar {
  Calendar(
    /// Apply the national holidays. Off leaves only what is declared here.
    national: Bool,
    /// Holidays on the same date every year, as `#(month, day, name)`: the
    /// state and municipal ones. Law rather than a yearly publication, so they
    /// keep working in a year nobody has published a calendar for yet.
    annual: List(#(Int, Int, String)),
    /// Holidays on one particular date, each with the name it is known by:
    /// what even an annual rule cannot predict.
    local: List(#(clock.Date, String)),
    /// Days off with no name.
    declared: List(clock.Date),
    /// Take the working day between a holiday and the weekend off as well.
    bridges: Bool,
    /// Days this calendar called off and a human said otherwise.
    ///
    /// Checked before everything else, because it is not another rule: it is
    /// somebody who was there saying the rules were wrong today. See
    /// `question`.
    with_expedient: List(clock.Date),
  )
}

/// A calendar that skips nothing, for a test or for a deployment that wants the
/// dates written out by hand.
pub fn nothing_off() -> Calendar {
  Calendar(
    national: False,
    annual: [],
    local: [],
    declared: [],
    bridges: False,
    with_expedient: [],
  )
}

/// Why this day has no expediente, or `Error(Nil)` when it is a working day.
///
/// The order is the order of certainty. A holiday is a holiday whatever else it
/// is; a day declared off is off whether or not it would also have bridged; an
/// emenda is the only one of the three that is inferred, so it answers last.
pub fn observance(
  calendar calendar: Calendar,
  on date: clock.Date,
) -> Result(Reason, Nil) {
  use <- bool.guard(
    when: list.contains(calendar.with_expedient, date),
    return: Error(Nil),
  )

  case holiday_on(calendar, date) {
    Ok(holiday) -> Ok(Observed(holiday))
    Error(Nil) ->
      case list.contains(calendar.declared, date) {
        True -> Ok(Declared)
        False -> bridge(calendar, date)
      }
  }
}

/// The emenda. Only a Monday before a Tuesday holiday and a Friday after a
/// Thursday one: those are the days a single day off joins to the weekend.
fn bridge(calendar: Calendar, date: clock.Date) -> Result(Reason, Nil) {
  case calendar.bridges {
    False -> Error(Nil)
    True ->
      case clock.weekday(date) {
        clock.Monday -> bridging(calendar, clock.next_day(date))
        clock.Friday -> bridging(calendar, clock.previous_day(date))
        _ -> Error(Nil)
      }
  }
}

fn bridging(calendar: Calendar, neighbour: clock.Date) -> Result(Reason, Nil) {
  holiday_on(calendar, neighbour)
  |> result.map(fn(holiday) { Bridge(holiday: holiday, date: neighbour) })
}

/// In order of how specific the claim is. A date somebody wrote down beats a
/// rule about every year, which beats the national calendar — so a holiday
/// moved by decree in one year reports as itself, and a municipal name wins
/// over the derived one on a day both know about.
fn holiday_on(calendar: Calendar, date: clock.Date) -> Result(Holiday, Nil) {
  case
    list.key_find(calendar.local, date)
    |> result.map(fn(name) { Local(name) })
  {
    Ok(holiday) -> Ok(holiday)
    Error(Nil) ->
      case annual_on(calendar.annual, date) {
        Ok(holiday) -> Ok(holiday)
        Error(Nil) ->
          case calendar.national {
            False -> Error(Nil)
            True -> list.key_find(national_holidays(clock.year(date)), date)
          }
      }
  }
}

fn annual_on(
  annual: List(#(Int, Int, String)),
  date: clock.Date,
) -> Result(Holiday, Nil) {
  annual
  |> list.find(fn(entry) {
    entry.0 == clock.month(date) && entry.1 == clock.day(date)
  })
  |> result.map(fn(entry) { Local(entry.2) })
}

/// Every national holiday of a year, in no particular order.
///
/// Carnival and Corpus Christi are ponto facultativo rather than feriado in the
/// letter of the law. They are here because FAI does not work them, which is
/// the question this module answers.
pub fn national_holidays(year: Int) -> List(#(clock.Date, Holiday)) {
  let fixed =
    [
      #(1, 1, NewYear),
      #(4, 21, Tiradentes),
      #(5, 1, LabourDay),
      #(9, 7, Independence),
      #(10, 12, OurLadyOfAparecida),
      #(11, 2, AllSouls),
      #(11, 15, RepublicDay),
      #(11, 20, BlackConsciousness),
      #(12, 25, Christmas),
    ]
    |> list.filter_map(fn(entry) {
      let #(month, day, holiday) = entry
      clock.new_date(year: year, month: month, day: day)
      |> result.map(fn(date) { #(date, holiday) })
    })

  let movable = case easter(year) {
    Error(_) -> []
    Ok(sunday) -> [
      #(clock.add_days(sunday, -48), Carnival),
      #(clock.add_days(sunday, -47), Carnival),
      #(clock.add_days(sunday, -2), GoodFriday),
      #(clock.add_days(sunday, 60), CorpusChristi),
    ]
  }

  list.append(fixed, movable)
}

/// Easter Sunday, by the anonymous Gregorian computus.
///
/// Four holidays hang off it and none of them is on a fixed date: Carnival is
/// the Monday and Tuesday forty-eight and forty-seven days before, Good Friday
/// is two before, and Corpus Christi is sixty after.
pub fn easter(year: Int) -> Result(clock.Date, clock.ClockError) {
  let a = year % 19
  let b = year / 100
  let c = year % 100
  let d = b / 4
  let e = b % 4
  let f = { b + 8 } / 25
  let g = { b - f + 1 } / 3
  let h = { 19 * a + b - d - g + 15 } % 30
  let i = c / 4
  let k = c % 4
  let l = { 32 + 2 * e + 2 * i - h - k } % 7
  let m = { a + 11 * h + 22 * l } / 451
  let offset = h + l - 7 * m + 114

  clock.new_date(year: year, month: offset / 31, day: offset % 31 + 1)
}

/// Every day of a month that has no expedient, in calendar order, each with
/// the reason it is off.
///
/// The hour bank is what wants this: an emenda is a day nobody worked and
/// everybody owes, and it never appears on the receipt because there is nothing
/// to appear — no marking was made.
pub fn without_expedient(
  calendar calendar: Calendar,
  year year: Int,
  month month: Int,
) -> List(#(clock.Date, Reason)) {
  days_of(clock.days_in_month(year: year, month: month), [])
  |> list.filter_map(fn(day) {
    use date <- result.try(
      clock.new_date(year: year, month: month, day: day)
      |> result.replace_error(Nil),
    )
    use reason <- result.try(observance(calendar: calendar, on: date))
    Ok(#(date, reason))
  })
}

fn days_of(day: Int, found: List(Int)) -> List(Int) {
  case day < 1 {
    True -> found
    False -> days_of(day - 1, [day, ..found])
  }
}

/// A published calendar, as `scripts/calendar.sh` leaves it: one
/// `YYYY-MM-DD=Name` per line, with `#` comments and blank lines.
pub type Published {
  Published(
    holidays: List(#(clock.Date, String)),
    /// Lines that are neither blank, a comment, nor a holiday.
    unreadable: Int,
  )
}

/// Read that file.
///
/// A line it cannot make sense of is counted, not refused. Refusing would stop
/// the punches over a calendar file, which is the wrong way round — but a
/// holiday silently dropped is the exact failure this module exists to prevent,
/// so the count goes where it can be seen rather than nowhere.
pub fn parse_published(contents: String) -> Published {
  contents
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "#") })
  |> list.fold(Published(holidays: [], unreadable: 0), fn(found, line) {
    case string.split_once(line, on: "=") {
      Error(Nil) -> Published(..found, unreadable: found.unreadable + 1)
      Ok(#(date, name)) ->
        case clock.parse_date(date), string.trim(name) {
          Ok(_), "" | Error(_), _ ->
            Published(..found, unreadable: found.unreadable + 1)
          Ok(date), name ->
            Published(..found, holidays: [#(date, name), ..found.holidays])
        }
    }
  })
}

/// One `YYYY-MM-DD` per line: the days somebody said had expedient after all.
/// Comments and blanks ignored, and a line that is not a date is dropped —
/// what dropping one costs is a day skipped, which is the safe direction.
pub fn parse_dates(contents: String) -> List(clock.Date) {
  contents
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" && !string.starts_with(line, "#") })
  |> list.filter_map(fn(line) {
    clock.parse_date(line) |> result.replace_error(Nil)
  })
}

/// Whether the published calendar still has anything to say about `year` or
/// later. A file that stops short is not an error — the national holidays are
/// derived and keep working — but from there on the municipal and state ones
/// are missing, which is worth saying before a Wednesday in November.
pub fn reaches(published: Published, year: Int) -> Bool {
  list.any(published.holidays, fn(entry) { clock.year(entry.0) >= year })
}

/// Merge a published calendar into a configured one. What was configured by
/// hand comes first and so wins the name, because somebody chose it.
pub fn with_published(calendar: Calendar, published: Published) -> Calendar {
  Calendar(..calendar, local: list.append(calendar.local, published.holidays))
}

/// The en-US name, for a log line. What the phone says is `ptbr.holiday_name`.
pub fn to_string(holiday: Holiday) -> String {
  case holiday {
    NewYear -> "New Year's Day"
    Carnival -> "Carnival"
    GoodFriday -> "Good Friday"
    Tiradentes -> "Tiradentes"
    LabourDay -> "Labour Day"
    CorpusChristi -> "Corpus Christi"
    Independence -> "Independence Day"
    OurLadyOfAparecida -> "Our Lady of Aparecida"
    AllSouls -> "All Souls' Day"
    RepublicDay -> "Republic Day"
    BlackConsciousness -> "Black Consciousness Day"
    Christmas -> "Christmas Day"
    Local(name:) -> name
  }
}

pub fn reason_to_string(reason: Reason) -> String {
  case reason {
    Observed(holiday) -> to_string(holiday)
    Bridge(holiday:, date:) ->
      "bridges " <> to_string(holiday) <> " on " <> clock.date_to_string(date)
    Declared -> "declared a day off"
  }
}

/// The effective calendar, for the header of a run log. No spaces: that header
/// is space separated `key=value`.
pub fn describe(calendar: Calendar) -> String {
  [
    case calendar.national {
      True -> ["national"]
      False -> []
    },
    case calendar.bridges {
      True -> ["bridges"]
      False -> []
    },
    [int.to_string(list.length(calendar.annual)) <> "annual"],
    [int.to_string(list.length(calendar.local)) <> "local"],
    [int.to_string(list.length(calendar.declared)) <> "off"],
    case calendar.with_expedient {
      [] -> []
      days -> [int.to_string(list.length(days)) <> "worked"]
    },
  ]
  |> list.flatten
  |> string.join("+")
}
