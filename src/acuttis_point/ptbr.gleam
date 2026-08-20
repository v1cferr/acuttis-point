//// The words the notifications use, in Brazilian Portuguese.
////
//// Everything else in this repository is en-US, deliberately, because the code
//// is public and meant to be read. These strings are not code: they are what
//// arrives on a phone in São Paulo, and they are the only record their reader
//// checks against Acuttis. So they are here, in one place, apart from the
//// domain that produces them.
////
//// The punch names are the ones Gestão de Pessoas uses in its own e-mails —
//// "retorno do almoço", "saída para o almoço" — so a notification and the
//// message asking about a missing punch describe the same thing the same way.

import acuttis_point/clock
import acuttis_point/decision
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/int
import gleam/list
import gleam/string

pub fn punch_name(target: punch.Punch) -> String {
  case target {
    punch.Entry -> "entrada"
    punch.LunchStart -> "saída para o almoço"
    punch.LunchEnd -> "retorno do almoço"
    punch.Exit -> "saída"
  }
}

/// A clause rather than a noun, so it composes without having to agree with the
/// gender of whatever word comes before it: "Falhou ao ler as marcações".
pub fn stage(step: report.Stage) -> String {
  case step {
    report.ReadingConfiguration -> "ao ler a configuração"
    report.StartingBrowser -> "ao abrir o navegador"
    report.Authenticating -> "ao fazer login no Acuttis"
    report.ReadingPunches -> "ao ler as marcações"
    report.RegisteringPunch -> "ao registrar o ponto"
    report.ConfirmingPunch -> "ao confirmar o ponto"
  }
}

pub fn weekday(day: clock.Weekday) -> String {
  case day {
    clock.Monday -> "segunda"
    clock.Tuesday -> "terça"
    clock.Wednesday -> "quarta"
    clock.Thursday -> "quinta"
    clock.Friday -> "sexta"
    clock.Saturday -> "sábado"
    clock.Sunday -> "domingo"
  }
}

/// The punches already on record, as a phone-sized line.
pub fn registered(marks: List(state.Registered)) -> String {
  case marks {
    [] -> "nenhuma marcação hoje"
    _ ->
      marks
      |> list.map(fn(mark) {
        punch_name(mark.punch) <> " " <> clock.time_to_string(mark.at)
      })
      |> string.join(", ")
  }
}

pub fn skip_reason(reason: decision.SkipReason) -> String {
  case reason {
    decision.NotAWorkDay(day) -> "hoje é " <> weekday(day) <> ", não é dia útil"
    decision.NonWorkingDate(date) ->
      clock.date_to_dmy(date) <> " está na lista de dias sem expediente"
    decision.DayAlreadyComplete -> "o dia já está completo"
    decision.AlreadyRegistered(punch: target, at:) ->
      "a "
      <> punch_name(target)
      <> " já está registrada às "
      <> clock.time_to_string(at)
    decision.TooEarly(next: target, opens_at:) ->
      "a "
      <> punch_name(target)
      <> " só abre às "
      <> clock.time_to_string(opens_at)
  }
}

pub fn abort_reason(reason: decision.AbortReason) -> String {
  case reason {
    decision.WindowClosed(punch: target, expected_at:, minutes_late:) ->
      "a "
      <> punch_name(target)
      <> " era às "
      <> clock.time_to_string(expected_at)
      <> " e já passou "
      <> int.to_string(minutes_late)
      <> " min, tarde para registrar sem mentir a hora"
    decision.InconsistentState(_) ->
      "as marcações de hoje não fazem sentido na ordem em que estão"
  }
}
