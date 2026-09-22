import acuttis_point/clock
import acuttis_point/holiday

fn on(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

/// The calendar as it is deployed: the national holidays derived, nothing
/// declared by hand, and FAI's emenda applied.
fn fai() -> holiday.Calendar {
  holiday.Calendar(
    national: True,
    annual: [],
    local: [],
    declared: [],
    bridges: True,
  )
}

pub fn easter_matches_the_known_sundays_test() {
  assert holiday.easter(2024) == Ok(on("2024-03-31"))
  assert holiday.easter(2025) == Ok(on("2025-04-20"))
  assert holiday.easter(2026) == Ok(on("2026-04-05"))
  assert holiday.easter(2027) == Ok(on("2027-03-28"))
}

/// The four that move. Carnival is why a fixed list would not do: it is not in
/// the same month two years running.
pub fn the_movable_holidays_hang_off_easter_test() {
  let calendar = fai()
  assert holiday.observance(calendar:, on: on("2026-02-16"))
    == Ok(holiday.Observed(holiday.Carnival))
  assert holiday.observance(calendar:, on: on("2026-02-17"))
    == Ok(holiday.Observed(holiday.Carnival))
  assert holiday.observance(calendar:, on: on("2026-04-03"))
    == Ok(holiday.Observed(holiday.GoodFriday))
  assert holiday.observance(calendar:, on: on("2026-06-04"))
    == Ok(holiday.Observed(holiday.CorpusChristi))
}

/// The one this module exists for. On 2026-09-07 the automation asked, at
/// 07:51, whether to register the entry of Independence Day.
pub fn a_national_holiday_needs_no_configuration_test() {
  assert holiday.observance(calendar: fai(), on: on("2026-09-07"))
    == Ok(holiday.Observed(holiday.Independence))
}

pub fn a_working_day_is_left_alone_test() {
  assert holiday.observance(calendar: fai(), on: on("2026-08-12")) == Error(Nil)
}

/// Corpus Christi 2026 falls on a Thursday, so the Friday goes with it.
pub fn a_thursday_holiday_costs_the_friday_test() {
  assert holiday.observance(calendar: fai(), on: on("2026-06-05"))
    == Ok(holiday.Bridge(holiday: holiday.CorpusChristi, date: on("2026-06-04")))
}

/// Tiradentes 2026 falls on a Tuesday, so the Monday goes with it.
pub fn a_tuesday_holiday_costs_the_monday_test() {
  assert holiday.observance(calendar: fai(), on: on("2026-04-20"))
    == Ok(holiday.Bridge(holiday: holiday.Tiradentes, date: on("2026-04-21")))
}

/// A holiday already against the weekend leaves nothing standing between the
/// two, so nothing is bridged. Independence 2026 is a Monday: the Friday before
/// it and the Tuesday after it are both ordinary working days.
pub fn a_holiday_beside_the_weekend_bridges_nothing_test() {
  assert holiday.observance(calendar: fai(), on: on("2026-09-04")) == Error(Nil)
  assert holiday.observance(calendar: fai(), on: on("2026-09-08")) == Error(Nil)
}

/// One day off cannot join a Wednesday to a weekend, so a midweek holiday
/// bridges in neither direction.
pub fn a_midweek_holiday_bridges_nothing_test() {
  let calendar =
    holiday.Calendar(..fai(), local: [
      #(on("2026-11-04"), "Aniversário de São Carlos"),
    ])
  assert holiday.observance(calendar:, on: on("2026-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário de São Carlos")))
  assert holiday.observance(calendar:, on: on("2026-11-03")) == Error(Nil)
  assert holiday.observance(calendar:, on: on("2026-11-05")) == Error(Nil)
}

/// A local holiday is a holiday: it bridges like any other. 2026-10-15 is a
/// Thursday.
pub fn a_local_holiday_bridges_too_test() {
  let calendar =
    holiday.Calendar(..fai(), local: [#(on("2026-10-15"), "Padroeira")])
  assert holiday.observance(calendar:, on: on("2026-10-16"))
    == Ok(holiday.Bridge(
      holiday: holiday.Local("Padroeira"),
      date: on("2026-10-15"),
    ))
}

/// Leave is not a holiday, and nobody emendas a vacation. The Thursday is off
/// and the Friday is a working day.
pub fn a_declared_day_off_bridges_nothing_test() {
  let calendar =
    holiday.Calendar(
      national: False,
      annual: [],
      local: [],
      declared: [on("2026-06-04")],
      bridges: True,
    )
  assert holiday.observance(calendar:, on: on("2026-06-04"))
    == Ok(holiday.Declared)
  assert holiday.observance(calendar:, on: on("2026-06-05")) == Error(Nil)
}

pub fn the_emenda_can_be_turned_off_test() {
  let calendar = holiday.Calendar(..fai(), bridges: False)
  assert holiday.observance(calendar:, on: on("2026-06-04"))
    == Ok(holiday.Observed(holiday.CorpusChristi))
  assert holiday.observance(calendar:, on: on("2026-06-05")) == Error(Nil)
}

pub fn the_national_calendar_can_be_turned_off_test() {
  assert holiday.observance(
      calendar: holiday.nothing_off(),
      on: on("2026-09-07"),
    )
    == Error(Nil)
}

/// A date named in the configuration wins over the derived name, so a holiday
/// FAI knows by another name reports the name FAI uses.
pub fn a_declared_name_wins_over_the_derived_one_test() {
  let calendar =
    holiday.Calendar(..fai(), local: [#(on("2026-09-07"), "Sete de Setembro")])
  assert holiday.observance(calendar:, on: on("2026-09-07"))
    == Ok(holiday.Observed(holiday.Local("Sete de Setembro")))
}

pub fn every_year_carries_the_same_thirteen_test() {
  assert list_length(holiday.national_holidays(2026)) == 13
  assert list_length(holiday.national_holidays(2027)) == 13
  assert list_length(holiday.national_holidays(2028)) == 13
}

fn list_length(items: List(a)) -> Int {
  case items {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

// --- The published calendar --------------------------------------------------
// What `scripts/calendar.sh` leaves behind: the state and municipal holidays,
// which are law rather than arithmetic and cannot be derived from the year.

const published_file = "# Written by scripts/calendar.sh on 2026-09-22.
#

2026-07-09=Revolução Constitucionalista
2026-11-04=Aniversário de São Carlos
"

pub fn a_published_calendar_is_read_past_its_comments_test() {
  let found = holiday.parse_published(published_file)
  assert found.unreadable == 0
  assert found.holidays
    == [
      #(on("2026-11-04"), "Aniversário de São Carlos"),
      #(on("2026-07-09"), "Revolução Constitucionalista"),
    ]
}

/// A line nobody can read is counted, never guessed at and never fatal: a
/// calendar file must not be able to stop the punches.
pub fn unreadable_lines_are_counted_rather_than_refused_test() {
  let found =
    holiday.parse_published(
      "2026-11-04=Aniversário\nnot a holiday\n2026-13-01=Impossible\n2026-11-05=\n",
    )
  assert found.holidays == [#(on("2026-11-04"), "Aniversário")]
  assert found.unreadable == 3
}

pub fn a_published_holiday_is_observed_and_bridges_test() {
  let calendar =
    holiday.with_published(
      holiday.Calendar(
        national: True,
        annual: [],
        local: [],
        declared: [],
        bridges: True,
      ),
      holiday.parse_published(published_file),
    )

  // 09/07/2026 is a Thursday, so the Friday goes with it.
  assert holiday.observance(calendar:, on: on("2026-07-09"))
    == Ok(holiday.Observed(holiday.Local("Revolução Constitucionalista")))
  assert holiday.observance(calendar:, on: on("2026-07-10"))
    == Ok(holiday.Bridge(
      holiday: holiday.Local("Revolução Constitucionalista"),
      date: on("2026-07-09"),
    ))

  // 04/11/2026 is a Wednesday: off, and bridging nothing.
  assert holiday.observance(calendar:, on: on("2026-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário de São Carlos")))
  assert holiday.observance(calendar:, on: on("2026-11-05")) == Error(Nil)
}

/// Hand-written wins: somebody chose that name.
pub fn a_configured_name_wins_over_a_published_one_test() {
  let calendar =
    holiday.with_published(
      holiday.Calendar(
        national: True,
        annual: [],
        local: [#(on("2026-11-04"), "Aniversário da cidade")],
        declared: [],
        bridges: True,
      ),
      holiday.parse_published(published_file),
    )
  assert holiday.observance(calendar:, on: on("2026-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário da cidade")))
}

/// A file that stops before this year still skips every national holiday — it
/// just no longer knows the municipal ones, and that is worth saying.
pub fn a_calendar_that_stops_short_is_visible_test() {
  let found = holiday.parse_published(published_file)
  assert holiday.reaches(found, 2026)
  assert !holiday.reaches(found, 2027)
  assert holiday.reaches(holiday.parse_published(""), 2026) == False
}

// --- The annual ones ----------------------------------------------------------
// São Paulo has one state holiday and São Carlos four, two of which already
// move with Easter. What is left is three fixed dates, and they are law rather
// than a yearly publication — which is the whole reason they are a rule here
// and not a download that stops at whatever year somebody last published.

fn sao_carlos() -> holiday.Calendar {
  holiday.Calendar(..fai(), annual: [
    #(7, 9, "Revolução Constitucionalista"),
    #(8, 15, "Nossa Senhora da Babilônia"),
    #(11, 4, "Aniversário de São Carlos"),
  ])
}

pub fn the_state_and_municipal_holidays_repeat_every_year_test() {
  let calendar = sao_carlos()

  assert holiday.observance(calendar:, on: on("2026-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário de São Carlos")))

  // The year no published calendar has reached. This is the one that matters:
  // a list would have gone quiet here, and a rule does not.
  assert holiday.observance(calendar:, on: on("2031-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário de São Carlos")))
  assert holiday.observance(calendar:, on: on("2031-08-15"))
    == Ok(holiday.Observed(holiday.Local("Nossa Senhora da Babilônia")))
  assert holiday.observance(calendar:, on: on("2031-07-09"))
    == Ok(holiday.Observed(holiday.Local("Revolução Constitucionalista")))
}

/// And they bridge like any other holiday. 09/07/2027 is a Friday and 15/08 a
/// Sunday, but 09/07/2026 is a Thursday — so 10/07/2026 is an emenda.
pub fn an_annual_holiday_bridges_test() {
  assert holiday.observance(calendar: sao_carlos(), on: on("2026-07-10"))
    == Ok(holiday.Bridge(
      holiday: holiday.Local("Revolução Constitucionalista"),
      date: on("2026-07-09"),
    ))
}

/// A date somebody wrote down for one particular year beats the rule about
/// every year, which is what a holiday moved by decree looks like.
pub fn a_dated_entry_beats_the_annual_rule_test() {
  let calendar =
    holiday.Calendar(..sao_carlos(), local: [
      #(on("2026-11-04"), "Aniversário, transferido"),
    ])
  assert holiday.observance(calendar:, on: on("2026-11-04"))
    == Ok(holiday.Observed(holiday.Local("Aniversário, transferido")))
}
