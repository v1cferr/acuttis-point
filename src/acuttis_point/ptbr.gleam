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

import acuttis_point/audit
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

/// With its article, because three of these are feminine and one is not, and a
/// sentence built from a bare noun produced "Tudo pronto para a retorno do
/// almoço" on the first day this ran.
///
/// Everything composed from it below uses verbs that do not inflect for gender —
/// "consta", "era", "abre" — rather than participles that would need a second
/// agreement to get right. Generated Portuguese is much safer that way.
pub fn punch_with_article(target: punch.Punch) -> String {
  case target {
    punch.Entry -> "a entrada"
    punch.LunchStart -> "a saída para o almoço"
    punch.LunchEnd -> "o retorno do almoço"
    punch.Exit -> "a saída"
  }
}

/// A clause rather than a noun, so it composes without having to agree with the
/// gender of whatever word comes before it: "Falhou ao ler as marcações".
/// What is wrong with a day, for the message that asks Gestão de Pessoas to fix
/// it. "Faltando" and "sobrando" are what the correction is about, so they are
/// the words to use.
pub fn verdict(result: audit.Verdict) -> String {
  case result {
    audit.Complete -> "completo"
    audit.Missing(found:) ->
      "faltando "
      <> int.to_string(audit.punches_per_day - found)
      <> " marcação(ões)"
    audit.Extra(found:) ->
      "sobrando "
      <> int.to_string(found - audit.punches_per_day)
      <> " marcação(ões)"
    audit.InProgress(found:) ->
      "em andamento, " <> int.to_string(found) <> " de 4"
  }
}

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
      punch_with_article(target) <> " já consta às " <> clock.time_to_string(at)
    decision.TooEarly(next: target, opens_at:) ->
      punch_with_article(target)
      <> " só abre às "
      <> clock.time_to_string(opens_at)
  }
}

pub fn abort_reason(reason: decision.AbortReason) -> String {
  case reason {
    decision.WindowClosed(punch: target, expected_at:, minutes_late:) ->
      punch_with_article(target)
      <> " era às "
      <> clock.time_to_string(expected_at)
      <> " e já passou "
      <> int.to_string(minutes_late)
      <> " min, tarde para registrar sem mentir a hora"
    decision.InconsistentState(_) ->
      "as marcações de hoje não fazem sentido na ordem em que estão"
  }
}
