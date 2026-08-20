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
  ))

  let assert timesheet.Audited(audited:, fresh:, ..) = first
  assert list.length(audited.inconsistent) == 2
  assert list.length(fresh) == 2
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
  ))

  let assert timesheet.Audited(audited: still, fresh: [], ..) = again
  assert list.length(still.inconsistent) == 2
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
  ))

  let message = notification.from_inspection(inspected)
  assert message.title == "2 dias novos para avisar a GP"
  assert message.priority == "high"
  // The dates and what is wrong with each, in the words the reply will use.
  assert string.contains(message.body, "11/08/2026: faltando 1 marcação(ões)")
  assert string.contains(message.body, "05/08/2026: faltando 1 marcação(ões)")

  // And the log carries the lines worth pasting.
  assert string.contains(
    timesheet.to_text(inspected),
    "05/08/2026 MISSING(3/4) 08:06 12:55 17:38",
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
  ))

  assert timesheet.exit_code(inspected) == 0
  let message = notification.from_inspection(inspected)
  assert message.title == "Histórico conferido"
  assert message.priority == "low"
  assert message.body == "todos os dias fecham com 4 marcações"
  promise.resolve(Nil)
}

pub fn a_receipt_that_cannot_be_read_is_not_a_clean_history_test() {
  let announced = clean("broken")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    port: port(Error(browser.InterfaceChanged("#mark_modal"))),
    announced: announced,
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

// A receipt that was not read to the end leaves its oldest day alone. Half a day
// looks like a short day, and an e-mail about a day that was fine is worse than
// no e-mail: it is the reader learning to distrust the next one.
pub fn a_truncated_read_does_not_judge_the_oldest_day_test() {
  let announced = clean("truncated")

  use inspected <- promise.await(timesheet.inspect(
    secrets: secrets(),
    now: moment("18:35"),
    // The oldest day here has three markings, which would normally be reported.
    port: port(Ok(#(receipt, False))),
    announced: announced,
  ))

  let assert timesheet.Audited(audited:, fresh:, ..) = inspected
  // 11/08 stays; 05/08, the oldest, is left out of the findings.
  assert list.length(audited.inconsistent) == 1
  assert list.length(fresh) == 1
  let assert [only] = fresh
  assert clock.date_to_dmy(only.date) == "11/08/2026"

  // And the line says the read was short, rather than passing for a full audit.
  assert string.contains(timesheet.to_line(inspected), "truncated=true")
  promise.resolve(Nil)
}
