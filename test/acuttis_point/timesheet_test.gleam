import acuttis_point/audit
import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/credentials
import acuttis_point/notification
import acuttis_point/report
import acuttis_point/timesheet
import gleam/dict
import gleam/javascript/promise
import gleam/list
import gleam/string
import support/files

const receipt = [
  "20/08/2026 Qui - 07:59location_onLocalização desconhecida",
  "20/08/2026 Qui - 08:08location_onLocalização desconhecida",
  "11/08/2026 Ter - 17:37location_onLocalização desconhecida",
  "11/08/2026 Ter - 13:43location_onLocalização desconhecida",
  "11/08/2026 Ter - 08:01location_onLocalização desconhecida",
  "05/08/2026 Qua - 17:38location_onLocalização desconhecida",
  "05/08/2026 Qua - 12:55location_onLocalização desconhecida",
  "05/08/2026 Qua - 08:06location_onLocalização desconhecida",
]

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-20")
  let assert Ok(parsed) = clock.parse_time(time)
  clock.Instant(date: date, time: parsed)
}

fn secrets() -> credentials.Credentials {
  let assert Ok(loaded) =
    credentials.from_env(
      dict.from_list([
        #("ACUTTIS_USERNAME", "victor@example.test"),
        #("ACUTTIS_PASSWORD", "s3cret"),
      ]),
    )
  loaded
}

fn port(
  rows: Result(#(List(String), Bool), browser.BrowserError),
) -> browser.Port(Nil) {
  browser.Port(
    open: fn() { promise.resolve(Ok(Nil)) },
    sign_in: fn(_, _) { promise.resolve(Ok(Nil)) },
    read_punches: fn(_, _) { promise.resolve(Ok([])) },
    // An audit must never be able to punch, and the only way to be sure of that
    // is for the operation to be unavailable to it.
    register: fn(_, _) { panic as "an audit must not register anything" },
    history: fn(_) { promise.resolve(rows) },
    describe: fn(_) { promise.resolve(Ok([])) },
    verify: fn(_) { promise.resolve(Ok(Nil)) },
    capture: fn(_, _) { promise.resolve(Ok(Nil)) },
    close: fn(_) { promise.resolve(Nil) },
  )
}

fn clean(name: String) -> String {
  let file = "build/announced-" <> name
  files.remove(file)
  file
}

pub fn a_day_that_does_not_add_up_is_announced_once_test() {
  let announced = clean("once")

  use first <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(Ok(#(receipt, True))),
    announced: announced,
    daily_minutes: 503,
  ))

  let assert timesheet.Audited(audited:, fresh:, ..) = first
  // 05/08 is the oldest day here, so it is not judged: 11/08 is the only finding.
  assert list.length(audited.inconsistent) == 1
  assert list.length(fresh) == 1
  // Red, because a day needing an e-mail should not be a green unit.
  assert timesheet.exit_code(first) == 2

  timesheet.remember(first, announced)

  // Same receipt, second evening. The days are still wrong in Acuttis — nobody
  // there has fixed them — and saying so again would only teach me to ignore it.
  use again <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(Ok(#(receipt, True))),
    announced: announced,
    daily_minutes: 503,
  ))

  let assert timesheet.Audited(audited: still, fresh: [], ..) = again
  assert list.length(still.inconsistent) == 1
  assert timesheet.exit_code(again) == 0
  promise.resolve(Nil)
}

// Today is not judged, so an audit that runs before the day is over does not
// invent a problem out of a day still in progress.
pub fn today_is_never_announced_test() {
  let announced = clean("today")

  use midday <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("12:30"),
    port: port(
      Ok(#(
        [
          "20/08/2026 Qui - 07:59location_onLocalização desconhecida",
          "20/08/2026 Qui - 08:08location_onLocalização desconhecida",
        ],
        True,
      )),
    ),
    announced: announced,
    daily_minutes: 503,
  ))

  assert timesheet.exit_code(midday) == 0
  let assert timesheet.Audited(fresh: [], ..) = midday
  promise.resolve(Nil)
}

pub fn the_notification_names_the_dates_test() {
  let announced = clean("names")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(Ok(#(receipt, True))),
    announced: announced,
    daily_minutes: 503,
  ))

  let message = notification.from_inspection(inspected)
  assert message.title == "1 dia novo para avisar a GP"
  assert message.priority == "high"
  // The date and what is wrong with it, in the words the reply will use.
  assert string.contains(message.body, "11/08/2026: faltando 1 marcação(ões)")
  // And the month's hours ride along, since that is the other thing worth
  // knowing at the end of a day.
  assert string.contains(message.body, "Banco do mês:")

  // And the log carries the line worth pasting. 05/08 is the boundary day here,
  // so it is not among the findings.
  assert string.contains(
    timesheet.to_text(inspected),
    "11/08/2026 MISSING(3/4) 08:01 13:43 17:37",
  )
  promise.resolve(Nil)
}

pub fn a_clean_history_says_so_quietly_test() {
  let announced = clean("clean")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(
      Ok(#(
        [
          "19/08/2026 Qua - 08:00location_on",
          "19/08/2026 Qua - 12:00location_on",
          "19/08/2026 Qua - 13:00location_on",
          "19/08/2026 Qua - 17:30location_on",
        ],
        True,
      )),
    ),
    announced: announced,
    daily_minutes: 503,
  ))

  assert timesheet.exit_code(inspected) == 0
  let message = notification.from_inspection(inspected)
  assert message.title == "Histórico conferido"
  assert message.priority == "low"
  // And the month's hours, which is the other thing worth knowing when the news
  // is that there is no news.
  assert message.body == "todos os dias fecham. Banco do mês: +0h07 em 1 dia(s)"
  promise.resolve(Nil)
}

pub fn a_receipt_that_cannot_be_read_is_not_a_clean_history_test() {
  let announced = clean("broken")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(Error(browser.InterfaceChanged("#mark_modal"))),
    announced: announced,
    daily_minutes: 503,
  ))

  let assert timesheet.Unreadable(stage:, ..) = inspected
  assert stage == report.ReadingPunches
  assert timesheet.exit_code(inspected) == 1
  assert notification.from_inspection(inspected).priority == "high"
  promise.resolve(Nil)
}

pub fn already_announced_dates_are_filtered_test() {
  let audited = audit.audit(rows: receipt, today: moment("18:35").date)
  assert list.length(timesheet.unannounced(audited.inconsistent, [])) == 2
  assert list.length(
      timesheet.unannounced(audited.inconsistent, ["2026-08-05"]),
    )
    == 1
  assert timesheet.unannounced(audited.inconsistent, [
      "2026-08-05",
      "2026-08-11",
    ])
    == []
}

// The oldest day the receipt shows is never judged, read to the end or not. The
// receipt stops about three months back, which is far more likely to be as far as
// Acuttis serves than anyone's first day — and half a day looks like a short day.
// An e-mail about a day that was fine is worse than no e-mail: it teaches its
// reader to distrust the next one.
pub fn the_oldest_day_is_never_judged_test() {
  let announced = clean("truncated")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    // The oldest day here has three markings, which would otherwise be reported.
    // Exhausted or not makes no difference.
    port: port(Ok(#(receipt, True))),
    announced: announced,
    daily_minutes: 503,
  ))

  let assert timesheet.Audited(audited:, fresh:, ..) = inspected
  // 11/08 stays; 05/08, the oldest, is left out of the findings.
  assert list.length(audited.inconsistent) == 1
  assert list.length(fresh) == 1
  let assert [only] = fresh
  assert clock.date_to_dmy(only.date) == "11/08/2026"

  // And the line names the day it did not judge, rather than leaving that
  // implicit.
  assert string.contains(timesheet.to_line(inspected), "unjudged=05/08/2026")
  promise.resolve(Nil)
}
