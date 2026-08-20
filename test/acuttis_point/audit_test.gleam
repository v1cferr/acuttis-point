import acuttis_point/audit
import acuttis_point/clock
import gleam/list

fn day(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

/// Real rows, copied from the receipt on 2026-08-20, including the trailing
/// address text each one carries. Real because the point of this test is the
/// answer it gives about a real timesheet, and because a parser tested only on
/// tidy input is tested on the wrong thing.
const receipt = [
  "19/08/2026 Qua - 17:41location_onLocalização desconhecida",
  "19/08/2026 Qua - 17:31location_onLocalização desconhecida",
  "19/08/2026 Qua - 13:52location_onLocalização desconhecida",
  "19/08/2026 Qua - 12:51location_onLocalização desconhecida",
  "19/08/2026 Qua - 08:11location_onLocalização desconhecida",
  "18/08/2026 Ter - 17:43location_onLocalização desconhecida",
  "18/08/2026 Ter - 13:51location_onLocalização desconhecida",
  "18/08/2026 Ter - 12:51location_onLocalização desconhecida",
  "18/08/2026 Ter - 08:17location_onLocalização desconhecida",
  "11/08/2026 Ter - 17:37location_onLocalização desconhecida",
  "11/08/2026 Ter - 13:43location_onLocalização desconhecida",
  "11/08/2026 Ter - 08:01location_onLocalização desconhecida",
  "07/08/2026 Sex - 17:33location_onLocalização desconhecida",
  "07/08/2026 Sex - 13:10location_onLocalização desconhecida",
  "07/08/2026 Sex - 08:09location_onLocalização desconhecida",
  "05/08/2026 Qua - 17:38location_onLocalização desconhecida",
  "05/08/2026 Qua - 12:55location_onLocalização desconhecida",
  "05/08/2026 Qua - 08:06location_onLocalização desconhecida",
  "29/07/2026 Qua - 17:33location_onLocalização desconhecida",
  "29/07/2026 Qua - 08:02location_onLocalização desconhecida",
]

fn dates(days: List(audit.Day)) -> List(String) {
  list.map(days, fn(one) { clock.date_to_dmy(one.date) })
}

// The three days Gestão de Pessoas wrote about are exactly the three this finds
// with a marking missing, which is the whole claim being made here.
pub fn the_days_gestao_de_pessoas_asked_about_are_the_ones_missing_a_punch_test() {
  let found = audit.audit(rows: receipt, today: day("2026-08-20"))

  assert dates(found.inconsistent)
    == ["19/08/2026", "11/08/2026", "07/08/2026", "05/08/2026", "29/07/2026"]

  // Their e-mail named 05/08, 07/08 and 11/08 — each three markings instead of
  // four. 29/07 has two, and nobody has asked about it yet.
  let assert [nineteen, eleven, seven, five, twenty_ninth] = found.inconsistent
  assert eleven.verdict == audit.Missing(found: 3)
  assert seven.verdict == audit.Missing(found: 3)
  assert five.verdict == audit.Missing(found: 3)
  assert twenty_ninth.verdict == audit.Missing(found: 2)

  // And the one the automation itself caused: a hand and a timer both punching
  // the exit, ten minutes apart.
  assert nineteen.verdict == audit.Extra(found: 5)
  assert audit.times_to_string(nineteen.times)
    == "08:11 12:51 13:52 17:31 17:41"
}

pub fn a_full_day_is_not_reported_test() {
  let found = audit.audit(rows: receipt, today: day("2026-08-20"))
  let assert Ok(complete) =
    list.find(found.days, fn(one) {
      clock.date_to_dmy(one.date) == "18/08/2026"
    })

  assert complete.verdict == audit.Complete
  assert !audit.is_inconsistent(complete)
  assert audit.times_to_string(complete.times) == "08:17 12:51 13:51 17:43"
}

// Today is allowed to be unfinished. Reporting it would mean an alarm every
// morning, about a day that has hours left to run.
pub fn today_is_not_inconsistent_for_being_unfinished_test() {
  let rows = [
    "20/08/2026 Qui - 07:59location_onLocalização desconhecida",
    "20/08/2026 Qui - 17:40location_onLocalização desconhecida",
  ]
  let found = audit.audit(rows: rows, today: day("2026-08-20"))

  let assert [today] = found.days
  assert today.verdict == audit.InProgress(found: 2)
  assert found.inconsistent == []

  // The same two markings, judged tomorrow: nine hours and forty minutes with no
  // break recorded, so a pair is missing.
  let closed = audit.audit(rows: rows, today: day("2026-08-21"))
  let assert [yesterday] = closed.inconsistent
  assert yesterday.verdict == audit.Missing(found: 2)
}

// The correction that nearly went out. A day of three or four hours has no break
// to record, so two markings are the whole of it — and an audit that called those
// days incomplete would have sent Gestão de Pessoas a list of days that were
// right. Real rows, from June.
pub fn a_short_day_needs_no_break_test() {
  let short = [
    "16/06/2026 Ter - 15:35location_onLocalização desconhecida",
    "16/06/2026 Ter - 12:35location_onLocalização desconhecida",
    "29/06/2026 Seg - 11:34location_onLocalização desconhecida",
    "29/06/2026 Seg - 07:54location_onLocalização desconhecida",
  ]
  let found = audit.audit(rows: short, today: day("2026-08-20"))

  assert found.inconsistent == []
  assert list.all(found.days, fn(one) { one.verdict == audit.Complete })

  // And the threshold is where the law puts it, not where four markings would:
  // six hours and one minute with two markings is a break unrecorded.
  let long = [
    "08/07/2026 Qua - 07:59location_onLocalização desconhecida",
    "08/07/2026 Qua - 14:00location_onLocalização desconhecida",
  ]
  let assert [one] =
    audit.audit(rows: long, today: day("2026-08-20")).inconsistent
  assert one.verdict == audit.Missing(found: 2)
}

// A row that is not a punch is dropped, not fatal. Refusing to report anything
// because of one unexpected element would be the wrong trade.
pub fn rows_that_are_not_punches_are_ignored_test() {
  let found =
    audit.audit(
      rows: [
        "Últimas marcações de ponto",
        "05/08/2026 Qua - 08:06location_on",
        "sem data nem hora",
        "05/08/2026 Qua",
      ],
      today: day("2026-08-20"),
    )

  let assert [one] = found.days
  assert one.verdict == audit.Missing(found: 1)
  assert audit.times_to_string(one.times) == "08:06"
}

pub fn the_line_can_be_pasted_into_a_reply_test() {
  let found = audit.audit(rows: receipt, today: day("2026-08-20"))
  let assert Ok(five) =
    list.find(found.inconsistent, fn(one) {
      clock.date_to_dmy(one.date) == "05/08/2026"
    })

  assert audit.to_line(five) == "05/08/2026 MISSING(3/4) 08:06 12:55 17:38"
}

pub fn an_empty_receipt_reports_nothing_test() {
  let found = audit.audit(rows: [], today: day("2026-08-20"))
  assert found.days == []
  assert found.inconsistent == []
}
