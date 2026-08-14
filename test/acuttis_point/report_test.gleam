import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/list

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn read(entries: List(#(punch.Punch, String))) -> List(state.Registered) {
  list.map(entries, fn(entry) {
    let #(kind, time) = entry
    state.Registered(punch: kind, at: at(time))
  })
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-12")
  clock.Instant(date: date, time: at(time))
}

pub fn a_confirmed_punch_reads_like_the_ticket_test() {
  let record =
    report.Decided(
      at: moment("07:55"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      registered: [],
      outcome: report.Confirmed(at: at("07:55")),
    )

  assert report.to_text(record) == "2026-08-12 07:55
Action: ENTRY
Expected: ENTRY
Current state: WAITING(ENTRY)
Punches: none
Result: SUCCESS
Acuttis confirmation: 07:55"
  assert report.exit_code(record) == 0
}

pub fn a_failure_names_the_stage_and_the_detail_test() {
  let record =
    report.Decided(
      at: moment("12:44"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Register(
        punch: punch.LunchStart,
        expected_at: at("12:00"),
      ),
      registered: read([#(punch.Entry, "08:03")]),
      outcome: report.Failed(
        stage: report.ConfirmingPunch,
        detail: "acuttis did not show the punch back",
      ),
    )

  assert report.to_text(record) == "2026-08-12 12:44
Action: LUNCH_START
Expected: LUNCH_START
Current state: WAITING(LUNCH_START)
Punches: ENTRY@08:03
Result: FAILED
Reason: confirming the punch failed: acuttis did not show the punch back"
  assert report.exit_code(record) == 1
}

pub fn a_skip_borrows_its_reason_from_the_decision_test() {
  let record =
    report.Decided(
      at: moment("08:05"),
      state: state.Waiting(punch.LunchStart),
      decision: decision.Skip(decision.AlreadyRegistered(
        punch: punch.Entry,
        at: at("08:03"),
      )),
      registered: read([#(punch.Entry, "08:03")]),
      outcome: report.NothingToDo,
    )

  assert report.to_text(record) == "2026-08-12 08:05
Action: NONE
Expected: LUNCH_START
Current state: WAITING(LUNCH_START)
Punches: ENTRY@08:03
Result: SKIPPED
Reason: ENTRY is already registered at 08:03"
  assert report.exit_code(record) == 0
}

pub fn a_refusal_exits_non_zero_so_systemd_shows_it_test() {
  let record =
    report.Decided(
      at: moment("10:30"),
      state: state.Waiting(punch.Entry),
      decision: decision.Abort(decision.WindowClosed(
        punch: punch.Entry,
        expected_at: at("08:00"),
        minutes_late: 150,
      )),
      registered: [],
      outcome: report.Refused,
    )

  assert report.to_text(record) == "2026-08-12 10:30
Action: NONE
Expected: ENTRY
Current state: WAITING(ENTRY)
Punches: none
Result: ABORTED
Reason: ENTRY was due at 08:00, 150 minutes ago; refusing to backdate it"
  assert report.exit_code(record) == 2
}

pub fn an_impossible_day_has_no_expected_punch_test() {
  let inconsistency =
    state.OutOfOrder(expected: punch.Entry, found: punch.LunchStart)
  let record =
    report.Decided(
      at: moment("12:00"),
      state: state.Invalid(inconsistency),
      decision: decision.Abort(decision.InconsistentState(inconsistency)),
      registered: read([#(punch.LunchStart, "12:00")]),
      outcome: report.Refused,
    )

  assert report.to_text(record) == "2026-08-12 12:00
Action: NONE
Expected: UNKNOWN
Current state: INVALID(expected ENTRY but found LUNCH_START)
Punches: LUNCH_START@12:00
Result: ABORTED
Reason: acuttis shows an impossible day: expected ENTRY but found LUNCH_START"
}

pub fn a_completed_day_expects_nothing_test() {
  let record =
    report.Decided(
      at: moment("18:00"),
      state: state.Completed,
      decision: decision.Skip(decision.DayAlreadyComplete),
      registered: read([
        #(punch.Entry, "07:55"),
        #(punch.LunchStart, "12:00"),
        #(punch.LunchEnd, "13:02"),
        #(punch.Exit, "17:31"),
      ]),
      outcome: report.NothingToDo,
    )

  assert report.to_text(record) == "2026-08-12 18:00
Action: NONE
Expected: NONE
Current state: COMPLETED
Punches: ENTRY@07:55, LUNCH_START@12:00, LUNCH_END@13:02, EXIT@17:31
Result: SKIPPED
Reason: every punch of the day is already registered"
}

pub fn a_dry_run_says_so_and_still_succeeds_test() {
  let record =
    report.Decided(
      at: moment("08:00"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      registered: [],
      outcome: report.Withheld,
    )

  assert report.to_text(record) == "2026-08-12 08:00
Action: ENTRY
Expected: ENTRY
Current state: WAITING(ENTRY)
Punches: none
Result: DRY_RUN
Reason: dry run, the punch was decided but not registered"
  assert report.exit_code(record) == 0
}

pub fn the_one_line_form_keeps_every_field_test() {
  let record =
    report.Decided(
      at: moment("07:55"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      registered: [],
      outcome: report.Confirmed(at: at("07:55")),
    )

  assert report.to_line(record)
    == "2026-08-12 07:55 result=SUCCESS action=ENTRY expected=ENTRY "
    <> "state=WAITING(ENTRY) punches=\"none\" confirmation=07:55"
}

pub fn the_one_line_form_quotes_a_free_text_reason_test() {
  let record =
    report.Decided(
      at: moment("08:00"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("08:00")),
      registered: [],
      outcome: report.Failed(
        stage: report.Authenticating,
        detail: "acuttis answered \"invalid credentials\"",
      ),
    )

  assert report.to_line(record)
    == "2026-08-12 08:00 result=FAILED action=ENTRY expected=ENTRY "
    <> "state=WAITING(ENTRY) punches=\"none\" "
    <> "reason=\"authenticating failed: acuttis answered 'invalid credentials'\""
}
