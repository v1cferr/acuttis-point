//// The calendar's fallback: a day it called off, and the way to say otherwise.
////
//// Every rule in `holiday` is a claim about what FAI does, and a claim can be
//// wrong — an emenda nobody took, a municipal holiday the foundation worked
//// through, a date moved by decree. Being wrong that way is silent, which is
//// what makes it worse than the failure it replaced: four punches nobody made,
//// nobody was told about, and Gestão de Pessoas finds weeks later.
////
//// So a day without expedient is not silent any more. It asks, once, and the
//// answer is a tap. Doing nothing means the calendar was right, which is the
//// answer on almost every holiday and the reason the question has one button
//// instead of two — on Christmas morning the right amount of interaction is
//// none.
////
//// The token is what keeps the topic from being the authorisation. Anyone who
//// learns the command topic can publish to it; only the phone that received
//// the notification knows the token minted for that day. Without one, a
//// stranger posting `working 2026-12-25` would have the deadline punch on
//// Christmas.

import acuttis_point/clock
import gleam/list
import gleam/result
import gleam/string

pub type Question {
  Question(date: clock.Date, token: String)
}

/// What this run did with an answer it was carrying.
pub type Answered {
  /// It was not carrying one.
  NotAnswering
  /// Taken: the day has expedient after all, whatever the calendar said.
  Accepted(date: clock.Date)
  Refused(AnswerError)
}

pub type AnswerError {
  /// Nothing has been asked, so there is nothing this could be the answer to.
  NothingAsked
  /// An answer arrived and matches no question on record.
  WrongToken
  /// The right token for another day. Yesterday's answer does not open today:
  /// the question was about a date, and so is the answer.
  StaleAnswer(asked_on: clock.Date)
}

/// Whether the question about this day has already gone out. Asked once, or a
/// holiday would buzz at every window of a day nobody is working.
pub fn asked(contents: String, on date: clock.Date) -> Bool {
  parse(contents)
  |> list.any(fn(question) { question.date == date })
}

/// Take an answer, against the questions on record.
pub fn answer(
  contents contents: String,
  token token: String,
  today today: clock.Date,
) -> Answered {
  let questions = parse(contents)

  case questions, list.find(questions, fn(one) { one.token == token }) {
    [], _ -> Refused(NothingAsked)
    _, Error(Nil) -> Refused(WrongToken)
    _, Ok(question) ->
      case question.date == today {
        True -> Accepted(question.date)
        False -> Refused(StaleAnswer(asked_on: question.date))
      }
  }
}

pub fn to_line(question: Question) -> String {
  clock.date_to_string(question.date) <> "=" <> question.token
}

/// One `YYYY-MM-DD=token` per line. A line that makes no sense is dropped: this
/// file decides whether to ask again, and the worst an unreadable line can cost
/// is one more question.
pub fn parse(contents: String) -> List(Question) {
  contents
  |> string.split(on: "\n")
  |> list.map(string.trim)
  |> list.filter_map(fn(line) {
    use #(date, token) <- result.try(string.split_once(line, on: "="))
    use date <- result.try(
      clock.parse_date(date)
      |> result.replace_error(Nil),
    )
    case string.trim(token) {
      "" -> Error(Nil)
      token -> Ok(Question(date: date, token: token))
    }
  })
}

pub fn error_to_string(error: AnswerError) -> String {
  case error {
    NothingAsked -> "nothing has been asked about the calendar"
    WrongToken -> "that answers no question on record"
    StaleAnswer(asked_on:) ->
      "that answers the question from "
      <> clock.date_to_string(asked_on)
      <> ", not today's"
  }
}
