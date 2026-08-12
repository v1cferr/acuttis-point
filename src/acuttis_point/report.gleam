//// What a run leaves behind.
////
//// Two renderings of the same record: `to_text` is the block from the ticket,
//// meant for a log file a human reads, and `to_line` is the one-line form that
//// stays readable in the systemd journal.
////
//// Nothing here can carry a secret. The only free text is `Failed.detail`,
//// which the adapters fill with browser and network messages.

import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/punch
import acuttis_point/state
import gleam/list
import gleam/string

pub type Report {
  Report(
    at: clock.Instant,
    state: state.DayState,
    decision: decision.Decision,
    outcome: RunOutcome,
  )
}

pub type RunOutcome {
  /// The punch was registered and Acuttis showed it back.
  Confirmed(at: clock.TimeOfDay)
  /// A punch was due, and dry run mode stopped short of registering it.
  Withheld
  /// The decision was to skip; Acuttis was left alone.
  NothingToDo
  /// The decision was to abort; Acuttis was left alone.
  Refused
  /// The run broke partway through.
  Failed(stage: Stage, detail: String)
}

/// Where a run can break. Coarse on purpose: it says which step to look at,
/// and `detail` carries the specifics.
pub type Stage {
  ReadingConfiguration
  StartingBrowser
  Authenticating
  ReadingPunches
  RegisteringPunch
  ConfirmingPunch
  ClosingBrowser
}

/// The process exit status. A refusal is deliberately a failure as far as
/// systemd is concerned: it needs to show up red, because it is exactly the
/// case that wants a human.
pub fn exit_code(report: Report) -> Int {
  case report.outcome {
    Confirmed(_) | Withheld | NothingToDo -> 0
    Failed(..) -> 1
    Refused -> 2
  }
}

pub fn to_text(report: Report) -> String {
  [
    timestamp(report),
    "Action: " <> decision.action_to_string(report.decision),
    "Expected: " <> expected_to_string(report.state),
    "Current state: " <> state.to_string(report.state),
    "Result: " <> result_to_string(report.outcome),
  ]
  |> append_optional("Reason: ", detail_line(report))
  |> append_optional("Acuttis confirmation: ", confirmation(report))
  |> string.join("\n")
}

pub fn to_line(report: Report) -> String {
  [
    timestamp(report),
    "result=" <> result_to_string(report.outcome),
    "action=" <> decision.action_to_string(report.decision),
    "expected=" <> expected_to_string(report.state),
    "state=" <> state.to_string(report.state),
  ]
  |> append_optional("confirmation=", confirmation(report))
  |> append_optional("reason=", quoted(detail_line(report)))
  |> string.join(" ")
}

pub fn result_to_string(outcome: RunOutcome) -> String {
  case outcome {
    Confirmed(_) -> "SUCCESS"
    Withheld -> "DRY_RUN"
    NothingToDo -> "SKIPPED"
    Refused -> "ABORTED"
    Failed(..) -> "FAILED"
  }
}

pub fn stage_to_string(stage: Stage) -> String {
  case stage {
    ReadingConfiguration -> "reading configuration"
    StartingBrowser -> "starting the browser"
    Authenticating -> "authenticating"
    ReadingPunches -> "reading the registered punches"
    RegisteringPunch -> "registering the punch"
    ConfirmingPunch -> "confirming the punch"
    ClosingBrowser -> "closing the browser"
  }
}

fn timestamp(report: Report) -> String {
  clock.date_to_string(report.at.date)
  <> " "
  <> clock.time_to_string(report.at.time)
}

/// The punch the day is waiting for, which on the happy path is also the one
/// being registered.
fn expected_to_string(day: state.DayState) -> String {
  case day {
    state.Waiting(missing) -> punch.to_string(missing)
    state.Completed -> "NONE"
    state.Invalid(_) -> "UNKNOWN"
  }
}

fn confirmation(report: Report) -> Result(String, Nil) {
  case report.outcome {
    Confirmed(at:) -> Ok(clock.time_to_string(at))
    _ -> Error(Nil)
  }
}

/// Why the run ended the way it did. Every reason other than a failure comes
/// straight from the decision, so the record can never disagree with the rule.
fn detail_line(report: Report) -> Result(String, Nil) {
  case report.outcome {
    Confirmed(_) -> Error(Nil)
    Withheld -> Ok("dry run, the punch was decided but not registered")
    Failed(stage:, detail:) ->
      Ok(stage_to_string(stage) <> " failed: " <> detail)
    NothingToDo | Refused ->
      case report.decision {
        decision.Skip(reason) -> Ok(decision.skip_reason_to_string(reason))
        decision.Abort(reason) -> Ok(decision.abort_reason_to_string(reason))
        decision.Register(..) -> Error(Nil)
      }
  }
}

fn append_optional(
  lines: List(String),
  label: String,
  value: Result(String, Nil),
) -> List(String) {
  case value {
    Ok(value) -> list.append(lines, [label <> value])
    Error(Nil) -> lines
  }
}

/// One-line output keeps a free-text reason inside quotes, so a message with
/// spaces cannot be mistaken for further fields.
fn quoted(value: Result(String, Nil)) -> Result(String, Nil) {
  case value {
    Error(Nil) -> Error(Nil)
    Ok(value) ->
      Ok("\"" <> string.replace(value, each: "\"", with: "'") <> "\"")
  }
}
