import acuttis_point/clock
import acuttis_point/config
import acuttis_point/decision
import acuttis_point/punch
import acuttis_point/state
import gleam/dict
import gleam/list

// A Wednesday, with the schedule the example configuration uses.
const workday = "2026-08-12"

const saturday = "2026-08-15"

fn settings(overrides: List(#(String, String))) -> config.Config {
  let assert Ok(loaded) =
    [
      #("ENTRY_TIME", "08:00"),
      #("LUNCH_START", "12:00"),
      #("LUNCH_END", "14:00"),
      #("EXIT_TIME", "17:30"),
      #("TIME_TOLERANCE_MINUTES", "10"),
    ]
    |> list.append(overrides)
    |> dict.from_list
    |> config.from_env
  loaded
}

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn on(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

fn moment(date: String, time: String) -> clock.Instant {
  clock.Instant(date: on(date), time: at(time))
}

fn punches(entries: List(#(punch.Punch, String))) -> List(state.Registered) {
  list.map(entries, fn(entry) {
    let #(kind, time) = entry
    state.Registered(punch: kind, at: at(time))
  })
}

fn decide(
  now: clock.Instant,
  registered: List(state.Registered),
) -> decision.Decision {
  let outcome =
    decision.decide(settings: settings([]), now: now, registered: registered)
  outcome.decision
}

pub fn entry_is_registered_inside_its_window_test() {
  assert decide(moment(workday, "08:00"), [])
    == decision.Register(punch: punch.Entry, expected_at: at("08:00"))
  assert decide(moment(workday, "08:10"), [])
    == decision.Register(punch: punch.Entry, expected_at: at("08:00"))
}

pub fn nothing_happens_before_the_window_opens_test() {
  assert decide(moment(workday, "07:55"), [])
    == decision.Skip(decision.TooEarly(next: punch.Entry, opens_at: at("08:00")))
}

pub fn a_closed_window_aborts_instead_of_backdating_test() {
  assert decide(moment(workday, "08:11"), [])
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 11,
    ))
  assert decide(moment(workday, "10:30"), [])
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 150,
    ))
}

pub fn the_day_advances_through_the_sequence_test() {
  let entry = punches([#(punch.Entry, "08:02")])
  assert decide(moment(workday, "12:00"), entry)
    == decision.Register(punch: punch.LunchStart, expected_at: at("12:00"))

  let lunch = list.append(entry, punches([#(punch.LunchStart, "12:01")]))
  assert decide(moment(workday, "14:03"), lunch)
    == decision.Register(punch: punch.LunchEnd, expected_at: at("14:00"))

  let afternoon = list.append(lunch, punches([#(punch.LunchEnd, "14:03")]))
  assert decide(moment(workday, "17:30"), afternoon)
    == decision.Register(punch: punch.Exit, expected_at: at("17:30"))
}

// The property the whole design exists for: whatever the second run of a
// window sees, it never registers anything.
pub fn a_second_run_in_the_same_window_is_a_no_op_test() {
  let now = moment(workday, "08:05")
  assert decide(now, []) == decision.Register(punch.Entry, at("08:00"))
  assert decide(now, punches([#(punch.Entry, "08:03")]))
    == decision.Skip(decision.AlreadyRegistered(
      punch: punch.Entry,
      at: at("08:03"),
    ))
}

pub fn every_punch_is_idempotent_within_its_window_test() {
  let registered = [
    #(punch.Entry, "08:00", "08:05"),
    #(punch.LunchStart, "12:00", "12:04"),
    #(punch.LunchEnd, "14:00", "14:02"),
    #(punch.Exit, "17:30", "17:33"),
  ]

  list.each(registered, fn(row) {
    let #(kind, window, registered_at) = row
    let earlier =
      list.take_while(registered, fn(other) { other.0 != kind })
      |> list.map(fn(other) { #(other.0, other.2) })
      |> punches
    let done = list.append(earlier, punches([#(kind, registered_at)]))

    // Once the last punch lands the day is complete, so the second run reports
    // that instead of naming a next punch it is early for. Either way it
    // registers nothing.
    let second_run = case punch.next(kind) {
      Error(Nil) -> decision.Skip(decision.DayAlreadyComplete)
      Ok(_) ->
        decision.Skip(decision.AlreadyRegistered(
          punch: kind,
          at: at(registered_at),
        ))
    }

    assert decide(moment(workday, window), earlier)
      == decision.Register(punch: kind, expected_at: at(window))
    assert decide(moment(workday, registered_at), done) == second_run
  })
}

pub fn a_full_day_is_left_alone_test() {
  let full =
    punches([
      #(punch.Entry, "08:00"),
      #(punch.LunchStart, "12:00"),
      #(punch.LunchEnd, "14:00"),
      #(punch.Exit, "17:30"),
    ])
  assert decide(moment(workday, "17:35"), full)
    == decision.Skip(decision.DayAlreadyComplete)
  assert decide(moment(workday, "19:00"), full)
    == decision.Skip(decision.DayAlreadyComplete)
}

pub fn a_manual_punch_outside_any_window_only_shifts_the_next_one_test() {
  // Lunch was taken early and by hand; the run at 14:00 must not re-register
  // it, and lunch end is still not due.
  let early = punches([#(punch.Entry, "08:00"), #(punch.LunchStart, "11:20")])
  assert decide(moment(workday, "13:00"), early)
    == decision.Skip(decision.TooEarly(
      next: punch.LunchEnd,
      opens_at: at("14:00"),
    ))
}

pub fn weekends_are_skipped_test() {
  assert decide(moment(saturday, "08:00"), [])
    == decision.Skip(decision.NotAWorkDay(clock.Saturday))
}

pub fn the_calendar_is_checked_before_the_punches_test() {
  // A weekend the user worked by hand can look nothing like a normal day, and
  // that is not the automation's problem to report.
  let odd = punches([#(punch.LunchStart, "09:00")])
  assert decide(moment(saturday, "09:05"), odd)
    == decision.Skip(decision.NotAWorkDay(clock.Saturday))
}

pub fn configured_days_off_are_skipped_test() {
  let outcome =
    decision.decide(
      settings: settings([#("SKIP_DATES", workday)]),
      now: moment(workday, "08:00"),
      registered: [],
    )
  assert outcome.decision == decision.Skip(decision.NonWorkingDate(on(workday)))
}

pub fn an_impossible_day_aborts_test() {
  let outcome =
    decision.decide(
      settings: settings([]),
      now: moment(workday, "12:00"),
      registered: punches([#(punch.LunchStart, "12:00")]),
    )
  assert outcome.state
    == state.Invalid(state.OutOfOrder(
      expected: punch.Entry,
      found: punch.LunchStart,
    ))
  assert outcome.decision
    == decision.Abort(
      decision.InconsistentState(state.OutOfOrder(
        expected: punch.Entry,
        found: punch.LunchStart,
      )),
    )
}

pub fn a_wider_tolerance_widens_the_window_test() {
  let generous = settings([#("TIME_TOLERANCE_MINUTES", "60")])
  let outcome =
    decision.decide(
      settings: generous,
      now: moment(workday, "08:59"),
      registered: [],
    )
  assert outcome.decision
    == decision.Register(punch: punch.Entry, expected_at: at("08:00"))
}

pub fn a_zero_tolerance_allows_only_the_exact_minute_test() {
  let strict = settings([#("TIME_TOLERANCE_MINUTES", "0")])
  let exact =
    decision.decide(
      settings: strict,
      now: moment(workday, "08:00"),
      registered: [],
    )
  let late =
    decision.decide(
      settings: strict,
      now: moment(workday, "08:01"),
      registered: [],
    )

  assert exact.decision
    == decision.Register(punch: punch.Entry, expected_at: at("08:00"))
  assert late.decision
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 1,
    ))
}

pub fn the_outcome_carries_the_state_it_decided_from_test() {
  let outcome =
    decision.decide(
      settings: settings([]),
      now: moment(workday, "12:00"),
      registered: punches([#(punch.Entry, "08:00")]),
    )
  assert outcome.state == state.Waiting(punch.LunchStart)
}

// The end-of-day sweep rests entirely on this: once the last window has closed,
// no state of the day can produce a punch. The sweep can only stay quiet or
// raise the alarm, which is why it is safe to schedule at all.
pub fn after_the_last_window_nothing_can_be_registered_test() {
  let sweep = moment(workday, "18:30")
  let entry = punches([#(punch.Entry, "08:00")])
  let lunch = list.append(entry, punches([#(punch.LunchStart, "12:00")]))
  let back = list.append(lunch, punches([#(punch.LunchEnd, "14:00")]))
  let full = list.append(back, punches([#(punch.Exit, "17:30")]))

  list.each([[], entry, lunch, back, full], fn(registered) {
    let registers = case decide(sweep, registered) {
      decision.Register(..) -> True
      _ -> False
    }
    assert !registers
  })
}

// And it does raise the alarm: an unfinished day refuses, which exits non-zero
// and arrives as a high-priority notification naming the punch that is missing.
pub fn the_sweep_names_the_punch_that_is_missing_test() {
  let sweep = moment(workday, "18:30")

  assert decide(sweep, [])
    == decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("08:00"),
      minutes_late: 630,
    ))

  let missing_exit =
    punches([
      #(punch.Entry, "08:00"),
      #(punch.LunchStart, "12:00"),
      #(punch.LunchEnd, "14:00"),
    ])
  assert decide(sweep, missing_exit)
    == decision.Abort(decision.WindowClosed(
      punch: punch.Exit,
      expected_at: at("17:30"),
      minutes_late: 60,
    ))
}

// A finished day says nothing, so the sweep is silent on the days it should be.
pub fn the_sweep_is_silent_on_a_finished_day_test() {
  let full =
    punches([
      #(punch.Entry, "08:00"),
      #(punch.LunchStart, "12:00"),
      #(punch.LunchEnd, "14:00"),
      #(punch.Exit, "17:30"),
    ])
  assert decide(moment(workday, "18:30"), full)
    == decision.Skip(decision.DayAlreadyComplete)
}

pub fn action_to_string_names_only_a_real_punch_test() {
  assert decision.action_to_string(decision.Register(punch.Exit, at("17:30")))
    == "EXIT"
  assert decision.action_to_string(decision.Skip(decision.DayAlreadyComplete))
    == "NONE"
  assert decision.action_to_string(
      decision.Abort(decision.WindowClosed(
        punch: punch.Entry,
        expected_at: at("08:00"),
        minutes_late: 30,
      )),
    )
    == "NONE"
}

pub fn decisions_read_clearly_in_a_log_test() {
  assert decision.to_string(decision.Register(punch.Entry, at("08:00")))
    == "REGISTER ENTRY scheduled for 08:00"
  assert decision.to_string(
      decision.Skip(decision.AlreadyRegistered(punch.Entry, at("08:03"))),
    )
    == "SKIP ENTRY is already registered at 08:03"
  assert decision.to_string(
      decision.Abort(decision.WindowClosed(
        punch: punch.Exit,
        expected_at: at("17:30"),
        minutes_late: 42,
      )),
    )
    == "ABORT EXIT was due at 17:30, 42 minutes ago; refusing to backdate it"
}
