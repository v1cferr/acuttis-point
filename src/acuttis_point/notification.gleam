//// Turning a run record into a push notification.
////
//// Shaped for ntfy, which reads the title, priority and tags off request
//// headers and takes the body as the message. Nothing here is ntfy specific
//// beyond those names, so any endpoint accepting a POST works.
////
//// Pure, so what lands on the phone is decided by a test rather than by
//// running the automation and waiting.

import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/preflight
import acuttis_point/report
import acuttis_point/state

pub type Notification {
  Notification(title: String, body: String, priority: String, tags: String)
}

/// Which runs are worth a phone buzzing.
pub type Trigger {
  /// Every run, including the ones that found nothing to do.
  Always
  /// Runs that did something, or could not. Silent when there was nothing to
  /// do, which is the common case when a punch was made by hand.
  OnAction
  /// Only failures and refusals.
  OnProblem
}

pub fn parse_trigger(raw: String) -> Result(Trigger, String) {
  case raw {
    "always" -> Ok(Always)
    "action" -> Ok(OnAction)
    "problem" -> Ok(OnProblem)
    _ -> Error(raw <> " is not one of always, action, problem")
  }
}

pub fn wanted(trigger: Trigger, record: report.Report) -> Bool {
  case trigger {
    Always -> True
    OnProblem -> is_problem(record)
    OnAction ->
      case record {
        report.Decided(outcome: report.NothingToDo, ..) -> False
        _ -> True
      }
  }
}

pub fn from_report(record: report.Report) -> Notification {
  case record {
    report.Broke(stage:, detail:, ..) ->
      problem(
        "Punch failed",
        report.stage_to_string(stage) <> " failed: " <> detail,
      )

    report.Decided(decision: chosen, outcome:, ..) ->
      case outcome {
        report.Confirmed(at:) ->
          good(
            "Punch registered",
            decision.action_to_string(chosen)
              <> " at "
              <> clock.time_to_string(at),
          )
        report.Withheld ->
          quiet(
            "Dry run",
            decision.action_to_string(chosen)
              <> " was due, and was not registered",
          )
        report.NothingToDo -> quiet("Nothing to do", why(chosen))
        report.Refused -> problem("Punch refused", why(chosen))
        report.Failed(stage:, detail:) ->
          problem(
            "Punch failed",
            report.stage_to_string(stage) <> " failed: " <> detail,
          )
      }
  }
}

/// A rehearsal is worth hearing about either way: "ready" is the reassurance
/// that was asked for, and "not ready" arrives while there is still time to act.
pub fn from_preflight(checked: preflight.Preflight) -> Notification {
  case checked {
    preflight.Ready(day: state.Completed, ..) ->
      quiet("Day already complete", "nothing left to punch today")
    preflight.Ready(day:, registered:, ..) ->
      good(
        "Ready to punch " <> preflight.next_punch(day),
        "signed in, day read, punch button reachable. So far: "
          <> state.registered_to_string(registered),
      )
    preflight.NotReady(stage:, detail:, ..) ->
      problem(
        "Not ready to punch",
        report.stage_to_string(stage) <> " failed: " <> detail,
      )
  }
}

fn is_problem(record: report.Report) -> Bool {
  case record {
    report.Broke(..) -> True
    report.Decided(outcome: report.Failed(..), ..) -> True
    report.Decided(outcome: report.Refused, ..) -> True
    _ -> False
  }
}

/// The reason comes from the decision, so a notification cannot disagree with
/// the rule that produced it any more than the log can.
fn why(chosen: decision.Decision) -> String {
  case chosen {
    decision.Skip(reason) -> decision.skip_reason_to_string(reason)
    decision.Abort(reason) -> decision.abort_reason_to_string(reason)
    decision.Register(..) -> decision.to_string(chosen)
  }
}

fn good(title: String, body: String) -> Notification {
  Notification(
    title: title,
    body: body,
    priority: "default",
    tags: "white_check_mark",
  )
}

/// Low priority arrives without a sound, which is right for a run that had
/// nothing to do.
fn quiet(title: String, body: String) -> Notification {
  Notification(title: title, body: body, priority: "low", tags: "zzz")
}

fn problem(title: String, body: String) -> Notification {
  Notification(title: title, body: body, priority: "high", tags: "warning")
}
