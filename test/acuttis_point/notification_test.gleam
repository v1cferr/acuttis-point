import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/notification
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-14")
  clock.Instant(date: date, time: at(time))
}

fn registered() -> report.Report {
  report.Decided(
    at: moment("07:57"),
    state: state.Waiting(punch.Entry),
    decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
    outcome: report.Confirmed(at: at("07:57")),
  )
}

fn nothing_to_do() -> report.Report {
  report.Decided(
    at: moment("08:00"),
    state: state.Waiting(punch.LunchStart),
    decision: decision.Skip(decision.AlreadyRegistered(
      punch: punch.Entry,
      at: at("07:57"),
    )),
    outcome: report.NothingToDo,
  )
}

fn refused() -> report.Report {
  report.Decided(
    at: moment("10:30"),
    state: state.Waiting(punch.Entry),
    decision: decision.Abort(decision.WindowClosed(
      punch: punch.Entry,
      expected_at: at("07:51"),
      minutes_late: 159,
    )),
    outcome: report.Refused,
  )
}

fn broke() -> report.Report {
  report.Broke(
    at: moment("07:57"),
    stage: report.Authenticating,
    detail: "acuttis rejected the sign in",
  )
}

pub fn a_registered_punch_says_which_and_when_test() {
  assert notification.from_report(registered())
    == notification.Notification(
      title: "Punch registered",
      body: "ENTRY at 07:57",
      priority: "default",
      tags: "white_check_mark",
    )
}

pub fn a_problem_arrives_at_high_priority_test() {
  let failed = notification.from_report(broke())
  assert failed.title == "Punch failed"
  assert failed.body == "authenticating failed: acuttis rejected the sign in"
  assert failed.priority == "high"
  assert failed.tags == "warning"

  let refusal = notification.from_report(refused())
  assert refusal.title == "Punch refused"
  assert refusal.body
    == "ENTRY was due at 07:51, 159 minutes ago; refusing to backdate it"
  assert refusal.priority == "high"
}

// Low priority arrives without a sound, which is what a run with nothing to do
// deserves if it is sent at all.
pub fn nothing_to_do_arrives_quietly_test() {
  let quiet = notification.from_report(nothing_to_do())
  assert quiet.title == "Nothing to do"
  assert quiet.body == "ENTRY is already registered at 07:57"
  assert quiet.priority == "low"
}

pub fn a_dry_run_says_it_registered_nothing_test() {
  let withheld =
    notification.from_report(report.Decided(
      at: moment("07:57"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
      outcome: report.Withheld,
    ))
  assert withheld.body == "ENTRY was due, and was not registered"
}

pub fn the_reason_comes_from_the_decision_test() {
  // Same source as the log, so a notification cannot disagree with the rule
  // that produced it.
  let record = refused()
  let assert report.Decided(decision: chosen, ..) = record
  let assert decision.Abort(reason) = chosen
  assert notification.from_report(record).body
    == decision.abort_reason_to_string(reason)
}

pub fn always_sends_everything_test() {
  assert notification.wanted(notification.Always, registered())
  assert notification.wanted(notification.Always, nothing_to_do())
  assert notification.wanted(notification.Always, refused())
  assert notification.wanted(notification.Always, broke())
}

pub fn action_stays_quiet_when_there_was_nothing_to_do_test() {
  assert notification.wanted(notification.OnAction, registered())
  assert notification.wanted(notification.OnAction, refused())
  assert notification.wanted(notification.OnAction, broke())
  assert !notification.wanted(notification.OnAction, nothing_to_do())
}

pub fn problem_sends_only_failures_and_refusals_test() {
  assert notification.wanted(notification.OnProblem, refused())
  assert notification.wanted(notification.OnProblem, broke())
  assert !notification.wanted(notification.OnProblem, registered())
  assert !notification.wanted(notification.OnProblem, nothing_to_do())
}

pub fn a_confirmation_failure_is_a_problem_test() {
  let record =
    report.Decided(
      at: moment("07:57"),
      state: state.Waiting(punch.Entry),
      decision: decision.Register(punch: punch.Entry, expected_at: at("07:51")),
      outcome: report.Failed(
        stage: report.ConfirmingPunch,
        detail: "acuttis does not show ENTRY after registering it",
      ),
    )
  assert notification.wanted(notification.OnProblem, record)
  assert notification.from_report(record).priority == "high"
}

pub fn parse_trigger_names_the_three_modes_test() {
  assert notification.parse_trigger("always") == Ok(notification.Always)
  assert notification.parse_trigger("action") == Ok(notification.OnAction)
  assert notification.parse_trigger("problem") == Ok(notification.OnProblem)
  assert notification.parse_trigger("sometimes")
    == Error("sometimes is not one of always, action, problem")
}
