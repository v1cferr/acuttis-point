import acuttis_point/authorised
import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/decision
import acuttis_point/pending
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/runner
import acuttis_point/state
import gleam/dict
import gleam/javascript/promise.{type Promise}
import gleam/list
import support/files
import support/spy

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn moment(time: String) -> clock.Instant {
  let assert Ok(date) = clock.parse_date("2026-08-21")
  clock.Instant(date: date, time: at(time))
}

fn settings(file: String) -> config.Config {
  let assert Ok(loaded) =
    config.from_env(
      dict.from_list([
        #("ENTRY_TIME", "08:00"),
        #("LUNCH_START", "12:00"),
        #("LUNCH_END", "14:00"),
        #("EXIT_TIME", "17:30"),
        #("PENDING_FILE", file),
      ]),
    )
  loaded
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

/// A port that answers with `day`, and either takes the punch or refuses it.
fn fake(
  day: List(state.Registered),
  register: Result(Nil, browser.BrowserError),
) -> #(browser.Port(Nil), spy.Cell(List(String))) {
  let cell = spy.new([])
  let record = fn(name: String) {
    spy.set(cell, list.append(spy.get(cell), [name]))
  }
  let answered = spy.new(day)

  let port =
    browser.Port(
      open: fn() {
        record("open")
        promise.resolve(Ok(Nil))
      },
      sign_in: fn(_, _) {
        record("sign_in")
        promise.resolve(Ok(Nil))
      },
      read_punches: fn(_, _) {
        record("read_punches")
        promise.resolve(Ok(spy.get(answered)))
      },
      register: fn(_, target) {
        record("register")
        case register {
          // A registered punch shows up on the next read, the way Acuttis does.
          Ok(Nil) -> {
            spy.set(
              answered,
              list.append(spy.get(answered), [
                state.Registered(punch: target, at: at("12:04")),
              ]),
            )
            promise.resolve(Ok(Nil))
          }
          Error(error) -> promise.resolve(Error(error))
        }
      },
      describe: fn(_) { promise.resolve(Ok([])) },
      verify: fn(_) { promise.resolve(Ok(Nil)) },
      capture: fn(_, _) { promise.resolve(Ok(Nil)) },
      close: fn(_) {
        record("close")
        promise.resolve(Nil)
      },
    )

  #(port, cell)
}

/// The day with the entry already on it, so the punch due at noon is the lunch
/// one. An empty day would make the model want the entry instead, and refuse it
/// as hours late.
fn after_arriving() -> List(state.Registered) {
  [state.Registered(punch: punch.Entry, at: at("07:58"))]
}

fn clean(name: String) -> String {
  let file = "build/authorised-" <> name
  files.remove(file)
  files.remove(pending.claim_path(file))
  file
}

fn offer(file: String, token: String) -> Nil {
  let assert Ok(date) = clock.parse_date("2026-08-21")
  let assert Ok(_) =
    pending.offer(
      path: file,
      token: token,
      punch: punch.LunchStart,
      date: date,
      expires_at: at("12:10"),
    )
  Nil
}

fn outcome(done: authorised.Authorised) -> report.RunOutcome {
  let assert authorised.Ran(finished:) = done
  let assert report.Decided(outcome: result, ..) = finished.report
  result
}

// The point of the whole design: the tap punches, and the deadline that follows
// finds nothing to do. Two actors, one punch.
pub fn a_tap_punches_and_the_deadline_then_finds_nothing_test() {
  let file = clean("race")
  offer(file, "tok3n")
  let #(port, calls) = fake(after_arriving(), Ok(Nil))

  use tapped <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:04"),
    port: port,
    offered: Ok("tok3n"),
  ))
  assert outcome(tapped) == report.Confirmed(at: at("12:04"))
  assert list.contains(spy.get(calls), "register")

  let #(idle, idle_calls) = fake(after_arriving(), Ok(Nil))
  use deadline <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:09"),
    port: idle,
    offered: Error(Nil),
  ))

  assert deadline
    == authorised.Declined(at: moment("12:09"), reason: pending.NothingPending)
  assert authorised.exit_code(deadline) == 0
  // And it never even opened a browser: a declined claim touches nothing.
  assert spy.get(idle_calls) == []
  promise.resolve(Nil)
}

// The safety net. Nobody tapped, so the deadline spends the token itself.
pub fn the_deadline_punches_when_nobody_tapped_test() {
  let file = clean("deadline")
  offer(file, "tok3n")
  let #(port, calls) = fake(after_arriving(), Ok(Nil))

  use done <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:09"),
    port: port,
    offered: Error(Nil),
  ))

  assert outcome(done) == report.Confirmed(at: at("12:04"))
  assert list.contains(spy.get(calls), "register")
  promise.resolve(Nil)
}

// A punch that did not land must not cost the deadline its turn.
pub fn a_failed_punch_gives_the_token_back_test() {
  let file = clean("failed")
  offer(file, "tok3n")
  let #(broken, _) =
    fake(
      after_arriving(),
      Error(browser.PunchUnavailable("element is not visible")),
    )

  use failed <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:04"),
    port: broken,
    offered: Ok("tok3n"),
  ))
  let assert report.Failed(..) = outcome(failed)

  // Still spendable, and the deadline gets there.
  let #(working, calls) = fake(after_arriving(), Ok(Nil))
  use retried <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:09"),
    port: working,
    offered: Error(Nil),
  ))
  assert outcome(retried) == report.Confirmed(at: at("12:04"))
  assert list.contains(spy.get(calls), "register")
  promise.resolve(Nil)
}

// The token is permission, not instruction. If the punch is already on record —
// because it was made by hand, which is how the double punches happened — the
// run registers nothing and the token is spent anyway, since it has nothing left
// to authorise.
pub fn a_punch_already_on_record_is_not_made_twice_test() {
  let file = clean("already")
  offer(file, "tok3n")
  let already = [
    state.Registered(punch: punch.Entry, at: at("07:58")),
    state.Registered(punch: punch.LunchStart, at: at("12:01")),
  ]
  let #(port, calls) = fake(already, Ok(Nil))

  use done <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:04"),
    port: port,
    offered: Ok("tok3n"),
  ))

  assert outcome(done) == report.NothingToDo
  assert !list.contains(spy.get(calls), "register")
  assert pending.offered(file) == Error(pending.NothingPending)
  promise.resolve(Nil)
}

// A tap quoting the wrong token opens nothing at all.
pub fn a_wrong_token_never_reaches_the_browser_test() {
  let file = clean("wrong")
  offer(file, "tok3n")
  let #(port, calls) = fake(after_arriving(), Ok(Nil))

  use done <- promise.await(authorised.run(
    settings: settings(file),
    secrets: secrets(),
    now: moment("12:04"),
    port: port,
    offered: Ok("guess"),
  ))

  assert done
    == authorised.Declined(at: moment("12:04"), reason: pending.WrongToken)
  assert authorised.exit_code(done) == 1
  assert spy.get(calls) == []
  promise.resolve(Nil)
}

// Asking is not acting, and a claimed token must never re-offer itself.
pub fn a_claiming_run_never_offers_again_test() {
  let file = clean("noask")
  offer(file, "tok3n")
  let asking = config.Config(..settings(file), ask: True)
  let #(port, _) = fake(after_arriving(), Ok(Nil))

  use done <- promise.await(authorised.run(
    settings: asking,
    secrets: secrets(),
    now: moment("12:04"),
    port: port,
    offered: Ok("tok3n"),
  ))

  assert outcome(done) == report.Confirmed(at: at("12:04"))
  promise.resolve(Nil)
}

// And the ask path itself: it decides, offers, and touches nothing.
pub fn asking_offers_a_token_and_registers_nothing_test() {
  let file = clean("ask")
  files.remove(file)
  let asking = config.Config(..settings(file), ask: True)
  let #(port, calls) = fake(after_arriving(), Ok(Nil))

  use finished <- promise.await(runner.run(
    settings: asking,
    secrets: secrets(),
    now: moment("12:04"),
    port: port,
  ))

  let assert report.Decided(
    outcome: report.Offered(token:, expires_at:),
    decision: chosen,
    ..,
  ) = finished.report
  assert chosen
    == decision.Register(punch: punch.LunchStart, expected_at: at("12:00"))
  // The window's end, so a tap can only spend it while the punch is still
  // honest: 12:00 plus the ten minute tolerance.
  assert expires_at == at("12:10")
  assert !list.contains(spy.get(calls), "register")

  // And what was written down is what the button will quote.
  let assert Ok(waiting) = pending.offered(file)
  assert waiting.token == token
  assert waiting.punch == punch.LunchStart
  promise.resolve(Nil)
}
