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
  /// The run got far enough to read the day and take a decision.
  Decided(
    at: clock.Instant,
    state: state.DayState,
    decision: decision.Decision,
    /// What Acuttis showed for today, so the record says which times were read
    /// and not merely what was concluded from them.
    registered: List(state.Registered),
    outcome: RunOutcome,
  )
  /// The run broke before it could read the day, so there is no decision to
  /// report — only where it stopped.
  Broke(at: clock.Instant, stage: Stage, detail: String)
}

pub type RunOutcome {
  /// The punch was registered and Acuttis showed it back.
  Confirmed(at: clock.TimeOfDay)
  /// A punch was due, and dry run mode stopped short of registering it.
  Withheld
  /// A punch was due, and permission to make it was offered rather than taken.
  /// The token is spendable until `expires_at`, by a tap on the phone or by the
  /// deadline run that covers a tap nobody made.
  Offered(token: String, expires_at: clock.TimeOfDay)
  /// The decision was to skip; Acuttis was left alone.
  NothingToDo
  /// The decision was to abort; Acuttis was left alone.
  Refused
  /// The run broke while acting on the decision.
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
}

/// The process exit status. A refusal is deliberately a failure as far as
/// systemd is concerned: it needs to show up red, because it is exactly the
/// case that wants a human.
pub fn exit_code(report: Report) -> Int {
  case report {
    Broke(..) -> 1
    Decided(outcome:, ..) ->
      case outcome {
        Confirmed(_) | Withheld | NothingToDo | Offered(..) -> 0
        Failed(..) -> 1
        Refused -> 2
      }
  }
}

pub fn to_text(report: Report) -> String {
  [
    timestamp(report),
    "Action: " <> action(report),
    "Expected: " <> expected(report),
    "Current state: " <> current_state(report),
    "Punches: " <> punches(report),
    "Result: " <> result(report),
  ]
  |> append_optional("Reason: ", detail_line(report))
  |> append_optional("Acuttis confirmation: ", confirmation(report))
  |> string.join("\n")
}

pub fn to_line(report: Report) -> String {
  [
    timestamp(report),
    "result=" <> result(report),
    "action=" <> action(report),
    "expected=" <> expected(report),
    "state=" <> current_state(report),
    "punches=\"" <> punches(report) <> "\"",
  ]
  |> append_optional("confirmation=", confirmation(report))
  |> append_optional("reason=", quoted(detail_line(report)))
  |> string.join(" ")
}

pub fn result_to_string(outcome: RunOutcome) -> String {
  case outcome {
    Confirmed(_) -> "SUCCESS"
    Withheld -> "DRY_RUN"
    Offered(..) -> "OFFERED"
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
  }
}

fn timestamp(report: Report) -> String {
  clock.date_to_string(report.at.date)
  <> " "
  <> clock.time_to_string(report.at.time)
}

fn result(report: Report) -> String {
  case report {
    Broke(..) -> "FAILED"
    Decided(outcome:, ..) -> result_to_string(outcome)
  }
}

fn action(report: Report) -> String {
  case report {
    Broke(..) -> "NONE"
    Decided(decision: chosen, ..) -> decision.action_to_string(chosen)
  }
}

/// The punch the day is waiting for, which on the happy path is also the one
/// being registered.
fn expected(report: Report) -> String {
  case report {
    Broke(..) -> "UNKNOWN"
    Decided(state: state.Waiting(missing), ..) -> punch.to_string(missing)
    Decided(state: state.Completed, ..) -> "NONE"
    Decided(state: state.Invalid(_), ..) -> "UNKNOWN"
  }
}

/// The times read off the receipt. A day is only ever four punches, so this
/// stays short enough for one line.
fn punches(report: Report) -> String {
  case report {
    // The day was never read.
    Broke(..) -> "unknown"
    Decided(registered:, ..) -> state.registered_to_string(registered)
  }
}

fn current_state(report: Report) -> String {
  case report {
    // The day was never read, so there is no state to report.
    Broke(..) -> "UNKNOWN"
    Decided(state: day, ..) -> state.to_string(day)
  }
}

fn confirmation(report: Report) -> Result(String, Nil) {
  case report {
    Decided(outcome: Confirmed(at:), ..) -> Ok(clock.time_to_string(at))
    _ -> Error(Nil)
  }
}

/// Why the run ended the way it did. Every reason other than a failure comes
/// straight from the decision, so the record can never disagree with the rule.
fn detail_line(report: Report) -> Result(String, Nil) {
  case report {
    Broke(stage:, detail:, ..) ->
      Ok(stage_to_string(stage) <> " failed: " <> detail)
    Decided(outcome:, decision: chosen, ..) ->
      case outcome {
        Confirmed(_) -> Error(Nil)
        Withheld -> Ok("dry run, the punch was decided but not registered")
        Offered(expires_at:, ..) ->
          Ok(
            "waiting for confirmation until "
            <> clock.time_to_string(expires_at),
          )
        Failed(stage:, detail:) ->
          Ok(stage_to_string(stage) <> " failed: " <> detail)
        NothingToDo | Refused ->
          case chosen {
            decision.Skip(reason) -> Ok(decision.skip_reason_to_string(reason))
            decision.Abort(reason) ->
              Ok(decision.abort_reason_to_string(reason))
            decision.Register(..) -> Error(Nil)
          }
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
