import acuttis_point/clock
import acuttis_point/holiday
import acuttis_point/question

fn on(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

const asked_file = "2026-09-07=bkq3m9x2tp
2026-10-12=h7n4rrqwzz
"

pub fn a_day_is_asked_about_once_test() {
  assert question.asked(asked_file, on: on("2026-09-07"))
  assert question.asked(asked_file, on: on("2026-10-12"))
  assert !question.asked(asked_file, on: on("2026-12-25"))
  assert !question.asked("", on: on("2026-09-07"))
}

pub fn an_answer_opens_the_day_it_was_asked_about_test() {
  assert question.answer(
      contents: asked_file,
      token: "bkq3m9x2tp",
      today: on("2026-09-07"),
    )
    == question.Accepted(on("2026-09-07"))
}

/// The topic is not the authorisation. Anyone who learns it can publish to it,
/// so an answer nobody was asked for changes nothing.
pub fn an_answer_to_no_question_is_refused_test() {
  assert question.answer(
      contents: "",
      token: "bkq3m9x2tp",
      today: on("2026-09-07"),
    )
    == question.Refused(question.NothingAsked)

  assert question.answer(
      contents: asked_file,
      token: "notatoken1",
      today: on("2026-09-07"),
    )
    == question.Refused(question.WrongToken)
}

/// Yesterday's answer does not open today: the question was about a date, and
/// so is the answer to it.
pub fn an_answer_from_another_day_is_refused_test() {
  assert question.answer(
      contents: asked_file,
      token: "bkq3m9x2tp",
      today: on("2026-10-12"),
    )
    == question.Refused(question.StaleAnswer(asked_on: on("2026-09-07")))
}

pub fn a_question_round_trips_through_its_file_test() {
  let one = question.Question(date: on("2026-12-25"), token: "abcdef1234")
  assert question.parse(question.to_line(one)) == [one]
}

pub fn unreadable_lines_are_dropped_test() {
  assert question.parse("not a question\n2026-13-01=x\n2026-09-07=\n") == []
}

// --- What an answer does to the calendar --------------------------------------

pub fn a_day_with_expedient_beats_every_rule_test() {
  let calendar =
    holiday.Calendar(
      national: True,
      annual: [#(11, 4, "Aniversário de São Carlos")],
      local: [],
      declared: [on("2026-12-28")],
      bridges: True,
      with_expedient: [],
    )

  // Independence, its own municipal holiday, an emenda and a declared day off:
  // all off, until somebody says they were at work.
  let off = [
    on("2026-09-07"),
    on("2026-11-04"),
    on("2026-06-05"),
    on("2026-12-28"),
  ]
  list_each(off, fn(date) {
    assert holiday.observance(calendar:, on: date) != Error(Nil)
    let answered = holiday.Calendar(..calendar, with_expedient: [date])
    assert holiday.observance(calendar: answered, on: date) == Error(Nil)
  })
}

pub fn the_answered_days_are_read_from_their_file_test() {
  assert holiday.parse_dates(
      "# written by an answer\n\n2026-09-07\n2026-11-04\n",
    )
    == [on("2026-09-07"), on("2026-11-04")]
}

fn list_each(items: List(a), run: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      run(first)
      list_each(rest, run)
    }
  }
}
