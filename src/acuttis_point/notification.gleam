//// Turning a run record into a push notification.
////
//// Shaped for ntfy, which reads the title, priority and tags off request
//// headers and takes the body as the message. Nothing here is ntfy specific
//// beyond those names, so any endpoint accepting a POST works.
////
//// Pure, so what lands on the phone is decided by a test rather than by
//// running the automation and waiting.
////
//// The text is in Brazilian Portuguese, against the rule that governs the rest
//// of this repository, and on purpose: this is the one output whose reader is a
//// person rather than a maintainer, and it is what he checks against Acuttis
//// when Gestão de Pessoas asks about a missing punch. The words live in `ptbr`.
//// The technical `detail` of a failure stays as it came — a Playwright timeout
//// says more in its own words than in a translation of them.

import acuttis_point/audit
import acuttis_point/balance
import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/preflight
import acuttis_point/ptbr
import acuttis_point/report
import acuttis_point/state
import acuttis_point/timesheet
import gleam/int
import gleam/list
import gleam/string

pub type Notification {
  Notification(
    title: String,
    body: String,
    priority: String,
    tags: String,
    /// A button on the notification, for the one message that asks for
    /// something instead of reporting it.
    action: Result(Action, Nil),
  )
}

/// What tapping the button does. The label is what it says; the command is what
/// gets published to the command topic, and the only thing that authorises a
/// punch. Where it is published is not decided here — a notification should not
/// have to know an endpoint.
pub type Action {
  Action(label: String, command: String)
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
        "Ponto NÃO foi batido",
        "Falhou " <> ptbr.stage(stage) <> ": " <> detail,
      )

    report.Decided(decision: chosen, outcome:, registered:, ..) ->
      case outcome {
        // The one message that says a thing was done rather than considered, so
        // it names the punch, the minute, and the day it now adds up to. The
        // screenshot rides along as the attachment.
        // High, not default. This is the message whose only job is to stop the
        // same punch being made again at the totem in the building, and a
        // confirmation nobody notices is how 08:08 happened on 2026-08-20.
        report.Confirmed(at:) ->
          loud(
            "Ponto batido: " <> bare(chosen),
            "bati "
              <> target(chosen)
              <> " às "
              <> clock.time_to_string(at)
              <> ". Hoje: "
              <> ptbr.registered(registered),
          )
        report.Withheld ->
          quiet(
            "Simulação, nada foi registrado",
            target(chosen) <> " era agora, e DRY_RUN está ligado",
          )
        // The one notification that asks rather than tells. High priority
        // because ignoring it has a cost, and the body says what that cost is
        // not: the deadline will punch anyway, so a missed tap is a punch made
        // late rather than a punch forgotten.
        report.Offered(token:, expires_at:, repeated:) ->
          Notification(
            title: case repeated {
              // A reminder says what is still true rather than repeating the
              // question, so a screen full of them reads as one thing pending.
              True -> "AINDA falta bater " <> target(chosen)
              False -> "Bater " <> target(chosen) <> "?"
            },
            body: "Toque para bater agora. Se não tocar, eu bato sozinho às "
              <> clock.time_to_string(expires_at)
              <> ". Hoje: "
              <> ptbr.registered(registered),
            // Urgent on a reminder: the first asking can be missed, and the
            // whole reason for a second one is that it should not be.
            priority: case repeated {
              True -> "urgent"
              False -> "high"
            },
            tags: "alarm_clock",
            action: Ok(Action(label: "Bater agora", command: "punch " <> token)),
          )
        report.NothingToDo -> quiet("Nada a fazer", why(chosen))
        report.Refused -> problem("Ponto NÃO foi batido", why(chosen))
        report.Failed(stage:, detail:) ->
          problem(
            "Ponto NÃO foi batido",
            "Falhou " <> ptbr.stage(stage) <> ": " <> detail,
          )
      }
  }
}

/// A rehearsal is worth hearing about either way: "ready" is the reassurance
/// that was asked for, and "not ready" arrives while there is still time to act.
pub fn from_preflight(checked: preflight.Preflight) -> Notification {
  case checked {
    preflight.Ready(day: state.Completed, ..) ->
      quiet("Dia já está completo", "nada mais para bater hoje")
    preflight.Ready(day: state.Waiting(missing), registered:, ..) ->
      good(
        "Tudo pronto para " <> ptbr.punch_with_article(missing),
        "login ok, marcações lidas, e o botão de ponto aceita o clique. Hoje: "
          <> ptbr.registered(registered),
      )
    preflight.Ready(registered:, ..) ->
      good(
        "Tudo pronto",
        "login ok e botão de ponto responde. Hoje: "
          <> ptbr.registered(registered),
      )
    preflight.NotReady(stage:, detail:, ..) ->
      problem(
        "ATENÇÃO: não vai dar para bater",
        "Falhou " <> ptbr.stage(stage) <> ": " <> detail,
      )
  }
}

/// An audit only speaks up about a day nobody has been told about yet. It names
/// the dates, because the next step is an e-mail that has to name them too.
pub fn from_inspection(inspection: timesheet.Inspection) -> Notification {
  case inspection {
    timesheet.Unreadable(stage:, detail:, ..) ->
      problem(
        "Não consegui conferir o histórico",
        "Falhou " <> ptbr.stage(stage) <> ": " <> detail,
      )
    timesheet.Audited(fresh: [], audited:, month:, ..) ->
      case audited.inconsistent {
        [] ->
          quiet("Histórico conferido", "todos os dias fecham. " <> hours(month))
        old ->
          quiet(
            "Histórico conferido",
            int.to_string(list.length(old))
              <> " dia(s) ainda pendente(s) com a GP, nenhum novo. "
              <> hours(month),
          )
      }
    timesheet.Audited(fresh: days, month:, ..) ->
      problem(
        case days {
          [_] -> "1 dia novo para avisar a GP"
          _ ->
            int.to_string(list.length(days)) <> " dias novos para avisar a GP"
        },
        list.append(
          list.map(days, fn(day) {
            clock.date_to_dmy(day.date)
            <> ": "
            <> ptbr.verdict(day.verdict)
            <> " ("
            <> audit.times_to_string(day.times)
            <> ")"
          }),
          [hours(month)],
        )
          |> string.join("\n"),
      )
  }
}

/// The month's hours, in one clause. Says how many days it is measured over,
/// because a balance over four days and one over twenty mean different things,
/// and names the days it could not measure rather than hiding them in the sum.
fn hours(month: balance.Balance) -> String {
  "Banco do mês: "
  <> balance.signed(balance.difference(month))
  <> " em "
  <> int.to_string(list.length(month.measured))
  <> " dia(s)"
  <> case month.unmeasurable {
    [] -> ""
    days ->
      ", fora " <> int.to_string(list.length(days)) <> " sem par para medir"
  }
}

/// What a decision was about, in the words Gestão de Pessoas uses.
fn target(chosen: decision.Decision) -> String {
  case chosen {
    decision.Register(punch: kind, ..) -> ptbr.punch_with_article(kind)
    decision.Skip(_) | decision.Abort(_) -> "a marcação"
  }
}

/// Without the article, for a title where it would only take up room.
fn bare(chosen: decision.Decision) -> String {
  case chosen {
    decision.Register(punch: kind, ..) -> ptbr.punch_name(kind)
    decision.Skip(_) | decision.Abort(_) -> "marcação"
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
    decision.Skip(reason) -> ptbr.skip_reason(reason)
    decision.Abort(reason) -> ptbr.abort_reason(reason)
    decision.Register(punch: kind, ..) ->
      "era hora de bater " <> ptbr.punch_with_article(kind)
  }
}

/// A good thing that still has to be seen.
fn loud(title: String, body: String) -> Notification {
  Notification(
    title: title,
    body: body,
    priority: "high",
    tags: "white_check_mark",
    action: Error(Nil),
  )
}

fn good(title: String, body: String) -> Notification {
  Notification(
    title: title,
    body: body,
    priority: "default",
    tags: "white_check_mark",
    action: Error(Nil),
  )
}

/// Low priority arrives without a sound, which is right for a run that had
/// nothing to do.
fn quiet(title: String, body: String) -> Notification {
  Notification(
    title: title,
    body: body,
    priority: "low",
    tags: "zzz",
    action: Error(Nil),
  )
}

fn problem(title: String, body: String) -> Notification {
  Notification(
    title: title,
    body: body,
    priority: "high",
    tags: "warning",
    action: Error(Nil),
  )
}
