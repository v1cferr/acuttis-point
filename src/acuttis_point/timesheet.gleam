//// Reading the whole timesheet, and saying which days do not add up.
////
//// The reason this exists is a mail folder. Gestão de Pessoas notices a missing
//// punch weeks later, names the date, and asks what time it happened — by which
//// point the honest answer is a reconstruction. Finding the same days the day
//// after they happen turns that into a fact.
////
//// It announces a day once. The days already reported stay wrong in Acuttis
//// until somebody there corrects them, so an audit that spoke up every evening
//// would be telling the truth and teaching me to ignore it. What is worth a
//// notification is a day that has just gone wrong.

import acuttis_point/audit
import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/report
import acuttis_point/system
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/string

pub type Inspection {
  Audited(
    at: clock.Instant,
    audited: audit.Audit,
    /// Whether the receipt ran out, rather than the scrolling running out. False
    /// means the oldest day was left unjudged, because a page boundary can fall
    /// inside a day and half a day reads as a short one.
    exhausted: Bool,
    /// The inconsistent days nobody has been told about yet. Empty is the good
    /// answer, and the common one.
    fresh: List(audit.Day),
  )
  Unreadable(at: clock.Instant, stage: report.Stage, detail: String)
}

pub fn inspect(
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
  announced announced: String,
) -> Promise(Inspection) {
  use opened <- promise.await(port.open())

  case opened {
    Error(error) ->
      promise.resolve(unreadable(now, report.StartingBrowser, error))
    Ok(session) -> {
      use result <- promise.await(read(secrets, now, port, session, announced))
      use _ <- promise.await(port.close(session))
      promise.resolve(result)
    }
  }
}

/// Non-zero when there is a day to write to Gestão de Pessoas about, so the unit
/// shows red and the notification is not the only way to notice.
pub fn exit_code(inspection: Inspection) -> Int {
  case inspection {
    Unreadable(..) -> 1
    Audited(fresh: [], ..) -> 0
    Audited(..) -> 2
  }
}

pub fn to_line(inspection: Inspection) -> String {
  case inspection {
    Unreadable(at:, stage:, detail:) ->
      timestamp(at)
      <> " audit=UNREADABLE stage=\""
      <> report.stage_to_string(stage)
      <> "\" reason=\""
      <> string.replace(detail, each: "\"", with: "'")
      <> "\""
    Audited(at:, audited:, fresh:, exhausted:) ->
      timestamp(at)
      <> " audit=DONE"
      <> case exhausted {
        True -> ""
        False -> " truncated=true"
      }
      <> " days="
      <> count(audited.days)
      <> " inconsistent="
      <> count(audited.inconsistent)
      <> " new="
      <> count(fresh)
      <> " covering="
      <> case audit.covered(audited) {
        Ok(#(oldest, newest)) ->
          clock.date_to_dmy(oldest) <> ".." <> clock.date_to_dmy(newest)
        Error(Nil) -> "nothing"
      }
  }
}

/// Every day that does not add up, one per line, oldest last. This is the part
/// worth pasting into a reply.
pub fn to_text(inspection: Inspection) -> String {
  case inspection {
    Unreadable(..) -> to_line(inspection)
    Audited(audited:, ..) ->
      case audited.inconsistent {
        [] -> "every day on the receipt adds up"
        days ->
          days
          |> list.map(audit.to_line)
          |> string.join("\n")
      }
  }
}

/// The dates just announced, so the next audit stays quiet about them. Written
/// after the notification rather than before: a day announced in a file but
/// never on a phone would be a day silently dropped.
pub fn remember(inspection: Inspection, announced: String) -> Nil {
  case inspection {
    Audited(fresh: [_, ..] as days, ..) -> {
      let lines =
        days
        |> list.map(fn(day) { clock.date_to_string(day.date) })
        |> string.join("\n")
      case system.append_line(announced, lines) {
        Ok(Nil) -> Nil
        // Failing to remember costs a repeated notification, which is a much
        // smaller problem than failing to send one.
        Error(_) -> Nil
      }
    }
    _ -> Nil
  }
}

fn read(
  secrets: credentials.Credentials,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
  announced: String,
) -> Promise(Inspection) {
  use signed_in <- promise.await(port.sign_in(session, secrets))

  case signed_in {
    Error(error) ->
      promise.resolve(unreadable(now, report.Authenticating, error))
    Ok(Nil) -> {
      use rows <- promise.await(port.history(session))

      promise.resolve(case rows {
        Error(error) -> unreadable(now, report.ReadingPunches, error)
        Ok(#(rows, exhausted)) -> {
          let audited =
            audit.audit(rows: rows, today: now.date)
            |> audit.trusting_the_oldest(exhausted)
          Audited(
            at: now,
            audited: audited,
            exhausted: exhausted,
            fresh: unannounced(audited.inconsistent, already(announced)),
          )
        }
      })
    }
  }
}

/// Which of these has not been announced yet. Pure, so what gets said and what
/// stays quiet is decided by a test.
pub fn unannounced(
  inconsistent: List(audit.Day),
  announced: List(String),
) -> List(audit.Day) {
  list.filter(inconsistent, fn(day) {
    !list.contains(announced, clock.date_to_string(day.date))
  })
}

fn already(path: String) -> List(String) {
  path
  |> system.read_or_empty
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
}

fn count(days: List(audit.Day)) -> String {
  days |> list.length |> int.to_string
}

fn timestamp(at: clock.Instant) -> String {
  clock.date_to_string(at.date) <> " " <> clock.time_to_string(at.time)
}

fn unreadable(
  now: clock.Instant,
  stage: report.Stage,
  error: browser.BrowserError,
) -> Inspection {
  Unreadable(at: now, stage: stage, detail: browser.error_to_string(error))
}
