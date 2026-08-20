import acuttis_point/clock
import acuttis_point/pending
import acuttis_point/punch
import gleam/list
import gleam/set
import gleam/string
import support/files

const path = "build/pending-test"

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn day(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

fn moment(date: String, time: String) -> clock.Instant {
  clock.Instant(date: day(date), time: at(time))
}

fn clean(name: String) -> String {
  let full = path <> "-" <> name
  files.remove(full)
  files.remove(pending.claim_path(full))
  full
}

fn offer(file: String, expires: String) -> pending.Pending {
  let assert Ok(offered) =
    pending.offer(
      path: file,
      token: "tok3n",
      punch: punch.LunchStart,
      date: day("2026-08-20"),
      expires_at: at(expires),
    )
  pending.offered_token(offered)
}

// The whole point. Two actors want the same punch; exactly one gets it.
pub fn a_token_can_only_be_spent_once_test() {
  let file = clean("once")
  let offered = offer(file, "12:45")

  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:36"),
    )
    == Ok(offered)

  // The deadline run comes along later and finds nothing, which is exactly what
  // it should find once the tap has been honoured.
  assert pending.claim(
      path: file,
      offered: Error(Nil),
      now: moment("2026-08-20", "12:44"),
    )
    == Error(pending.NothingPending)
}

// The deadline run is entitled to whatever is pending without knowing its name:
// nobody types a token into a timer.
pub fn the_deadline_claims_without_a_token_test() {
  let file = clean("deadline")
  let offered = offer(file, "12:45")

  assert pending.claim(
      path: file,
      offered: Error(Nil),
      now: moment("2026-08-20", "12:44"),
    )
    == Ok(offered)
}

// A wrong token must not cost the deadline its turn, so the offer survives it.
pub fn a_wrong_token_is_refused_and_the_offer_survives_test() {
  let file = clean("wrong")
  let offered = offer(file, "12:45")

  assert pending.claim(
      path: file,
      offered: Ok("nope"),
      now: moment("2026-08-20", "12:36"),
    )
    == Error(pending.WrongToken)

  // Still there, still spendable.
  assert pending.offered(file) == Ok(offered)
  assert pending.claim(
      path: file,
      offered: Error(Nil),
      now: moment("2026-08-20", "12:44"),
    )
    == Ok(offered)
}

// A punch authorised at 12:35 and spent at 15:00 would be a lie about when the
// day happened, and the tolerance window exists to prevent exactly that.
pub fn an_expired_token_is_refused_test() {
  let file = clean("expired")
  let _ = offer(file, "12:45")

  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:46"),
    )
    == Error(pending.Expired(expired_at: at("12:45")))
}

pub fn a_token_from_another_day_is_refused_test() {
  let file = clean("yesterday")
  let _ = offer(file, "12:45")

  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-21", "12:36"),
    )
    == Error(pending.WrongDay(
      offered: day("2026-08-21"),
      pending: day("2026-08-20"),
    ))
}

// A punch that did not land leaves the authorisation intact, because the
// deadline should still get its turn at it.
pub fn a_released_token_can_be_claimed_again_test() {
  let file = clean("released")
  let offered = offer(file, "12:45")

  let assert Ok(claimed) =
    pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:36"),
    )
  pending.release(path: file, pending: claimed)

  assert pending.claim(
      path: file,
      offered: Error(Nil),
      now: moment("2026-08-20", "12:44"),
    )
    == Ok(offered)
}

pub fn a_spent_token_leaves_nothing_behind_test() {
  let file = clean("spent")
  let _ = offer(file, "12:45")
  let assert Ok(_) =
    pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:36"),
    )
  pending.spend(file)

  assert !files.has_content(file)
  assert !files.has_content(pending.claim_path(file))
  assert pending.offered(file) == Error(pending.NothingPending)
}

// A file that says something unexpected is not a file to act on.
pub fn a_file_that_makes_no_sense_authorises_nothing_test() {
  let file = clean("garbage")
  let assert Ok(_) =
    pending.offer(
      path: file,
      token: "tok3n",
      punch: punch.Exit,
      date: day("2026-08-20"),
      expires_at: at("17:40"),
    )
  // Something else wrote over it.
  files.write(file, "punch=BRUNCH\ndate=2026-08-20\ntoken=x\nexpires=17:40\n")

  let assert Error(pending.Unreadable(detail)) =
    pending.claim(
      path: file,
      offered: Error(Nil),
      now: moment("2026-08-20", "17:35"),
    )
  assert detail == "BRUNCH is not a punch"
}

pub fn nothing_pending_claims_nothing_test() {
  let file = clean("empty")
  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:36"),
    )
    == Error(pending.NothingPending)
}

// A guessable token is not a token: anyone who can reach the command topic
// could spend one.
pub fn tokens_do_not_repeat_test() {
  let tokens = list.map(list.repeat(Nil, 200), fn(_) { pending.fresh_token() })
  assert set.size(set.from_list(tokens)) == 200
  let assert Ok(first) = list.first(tokens)
  assert string.length(first) >= 10
}

// A reminder has to hand out the token that is already on the table. Minting a
// new one would silently break the button on the notification already sitting on
// the phone, which is the notification most likely to be the one tapped.
pub fn asking_again_about_the_same_punch_keeps_the_same_token_test() {
  let file = clean("again")
  let first = offer(file, "12:45")

  let assert Ok(second) =
    pending.offer(
      path: file,
      token: "a-different-one",
      punch: punch.LunchStart,
      date: day("2026-08-20"),
      expires_at: at("12:45"),
    )

  let assert pending.Standing(held) = second
  assert held == first
  assert held.token == "tok3n"

  // And the old button still works.
  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "12:40"),
    )
    == Ok(first)
}

// A different punch, or another day, is not the same offer. Keeping it would let
// a notification from this morning punch this afternoon.
pub fn a_different_punch_replaces_the_offer_test() {
  let file = clean("replaced")
  let _ = offer(file, "12:45")

  let assert Ok(pending.Minted(fresh)) =
    pending.offer(
      path: file,
      token: "newtoken",
      punch: punch.Exit,
      date: day("2026-08-20"),
      expires_at: at("17:40"),
    )
  assert fresh.punch == punch.Exit
  assert fresh.token == "newtoken"

  // The old token is gone with the offer it belonged to.
  assert pending.claim(
      path: file,
      offered: Ok("tok3n"),
      now: moment("2026-08-20", "17:35"),
    )
    == Error(pending.WrongToken)
}
