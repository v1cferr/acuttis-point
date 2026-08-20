//// One run, start to finish.
////
//// The order is fixed and narrow: open, sign in, read the day, decide, and
//// only then possibly act. Every failure before the decision produces a
//// `Broke` report, because at that point there is nothing to say about the day.
////
//// A registration is never trusted on its own. The punches are read again
//// afterwards and the new one has to be there, which is what makes the run
//// report a confirmation rather than an assumption.

import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/decision
import acuttis_point/pending
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/javascript/promise.{type Promise}
import gleam/result
import gleam/string

/// A finished run: what happened, and the screenshot of the page it ended on,
/// when one was taken.
pub type Completed {
  Completed(report: report.Report, screenshot: Result(String, Nil))
}

pub fn run(
  settings settings: config.Config,
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
) -> Promise(Completed) {
  use opened <- promise.await(port.open())

  case opened {
    Error(error) ->
      // Nothing was opened, so there is no page to photograph either.
      promise.resolve(Completed(
        report: broke(now, report.StartingBrowser, error),
        screenshot: Error(Nil),
      ))
    Ok(session) -> {
      use record <- promise.await(visit(settings, secrets, now, port, session))
      // Taken while the page still exists: on a failure it is the only witness
      // to an interface that changed under us, and on a success it is the
      // receipt with the new punch on it.
      use shot <- promise.await(capture(settings, now, port, session, record))
      // The browser is closed whatever happened, so a failed run does not
      // leave a Chromium behind for the next timer to trip over.
      use _ <- promise.await(port.close(session))
      promise.resolve(Completed(report: record, screenshot: shot))
    }
  }
}

/// A picture of a run that broke, or of one that registered a punch. Nothing
/// else: a refusal is a decision rather than a malfunction, and a late run
/// refusing its window every day would fill a disk with photographs of a page
/// that was working fine.
///
/// The success case is the whole reason a punch can be proved rather than
/// asserted. By the time it is taken the punches have already been read back, so
/// what it photographs is the receipt with the new row on it — the same thing
/// Gestão de Pessoas would look at, at the moment it appeared.
fn capture(
  settings: config.Config,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
  record: report.Report,
) -> Promise(Result(String, Nil)) {
  case settings.screenshot_dir, worth_photographing(record) {
    Ok(dir), Ok(label) -> {
      let path =
        dir
        <> "/"
        <> clock.date_to_string(now.date)
        <> "-"
        <> string.replace(clock.time_to_string(now.time), each: ":", with: "")
        <> "-"
        <> label
        <> ".png"

      use taken <- promise.await(port.capture(session, path))
      promise.resolve(
        taken
        |> result.replace(path)
        |> result.replace_error(Nil),
      )
    }
    _, _ -> promise.resolve(Error(Nil))
  }
}

/// The filename's middle, in en-US like every other technical name here — the
/// Portuguese belongs in what reaches the phone, not on disk.
fn worth_photographing(record: report.Report) -> Result(String, Nil) {
  case record {
    report.Broke(stage:, ..) -> Ok(slug(report.stage_to_string(stage)))
    report.Decided(outcome: report.Failed(stage:, ..), ..) ->
      Ok(slug(report.stage_to_string(stage)))
    report.Decided(
      decision: decision.Register(punch: target, ..),
      outcome: report.Confirmed(..),
      ..,
    ) -> Ok("registered-" <> slug(punch.to_string(target)))
    _ -> Error(Nil)
  }
}

fn slug(raw: String) -> String {
  raw
  |> string.lowercase
  |> string.replace(each: " ", with: "-")
  |> string.replace(each: "_", with: "-")
}

fn visit(
  settings: config.Config,
  secrets: credentials.Credentials,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
) -> Promise(report.Report) {
  use signed_in <- promise.await(port.sign_in(session, secrets))

  case signed_in {
    Error(error) -> promise.resolve(broke(now, report.Authenticating, error))
    Ok(Nil) -> {
      use read <- promise.await(port.read_punches(session, now.date))

      case read {
        Error(error) ->
          promise.resolve(broke(now, report.ReadingPunches, error))
        Ok(registered) ->
          act(
            settings,
            now,
            port,
            session,
            decision.decide(settings:, now:, registered:),
          )
      }
    }
  }
}

fn act(
  settings: config.Config,
  now: clock.Instant,
  port: browser.Port(session),
  session: session,
  outcome: decision.Outcome,
) -> Promise(report.Report) {
  case outcome.decision {
    decision.Skip(_) ->
      promise.resolve(decided(now, outcome, report.NothingToDo))
    decision.Abort(_) -> promise.resolve(decided(now, outcome, report.Refused))
    decision.Register(punch: target, expected_at:) ->
      case settings.dry_run, settings.ask {
        True, _ -> promise.resolve(decided(now, outcome, report.Withheld))
        // Asking is not acting: the run stops here and the punch waits for a tap
        // or for the deadline, whichever reaches the token first.
        _, True ->
          promise.resolve(offer(settings, now, outcome, target, expected_at))
        _, _ -> register(port, session, now, outcome, target)
      }
  }
}

/// Offer the permission rather than use it.
///
/// The token expires when the window does, which is what keeps a tap honest: the
/// punch it authorises is the one that was due, at a time it could still have
/// happened. The deadline run gets the same token, so the two cannot both spend
/// it.
fn offer(
  settings: config.Config,
  now: clock.Instant,
  outcome: decision.Outcome,
  target: punch.Punch,
  expected_at: clock.TimeOfDay,
) -> report.Report {
  let token = pending.fresh_token()
  let expires_at = clock.add_minutes(expected_at, settings.tolerance_minutes)

  case
    pending.offer(
      path: settings.pending_file,
      token: token,
      punch: target,
      date: now.date,
      expires_at: expires_at,
    )
  {
    Ok(_) ->
      decided(
        now,
        outcome,
        report.Offered(token: token, expires_at: expires_at),
      )
    // A token that could not be written is not an offer, and pretending
    // otherwise would send a button that authorises nothing.
    Error(detail) ->
      decided(
        now,
        outcome,
        report.Failed(stage: report.RegisteringPunch, detail: detail),
      )
  }
}

fn register(
  port: browser.Port(session),
  session: session,
  now: clock.Instant,
  outcome: decision.Outcome,
  target: punch.Punch,
) -> Promise(report.Report) {
  use registered <- promise.await(port.register(session, target))

  case registered {
    Error(error) ->
      promise.resolve(decided(
        now,
        outcome,
        failed(report.RegisteringPunch, error),
      ))
    Ok(Nil) -> confirm(port, session, now, outcome, target)
  }
}

fn confirm(
  port: browser.Port(session),
  session: session,
  now: clock.Instant,
  outcome: decision.Outcome,
  target: punch.Punch,
) -> Promise(report.Report) {
  use read <- promise.await(port.read_punches(session, now.date))

  case read {
    Error(error) ->
      promise.resolve(decided(
        now,
        outcome,
        failed(report.ConfirmingPunch, error),
      ))
    Ok(registered) ->
      case state.registered_at(registered, target) {
        // The day as it stands AFTER the punch, not before. This is the one
        // report anyone checks against Acuttis, so it should show what Acuttis
        // now shows rather than what it showed a moment ago.
        Ok(at) ->
          promise.resolve(report.Decided(
            at: now,
            state: outcome.state,
            decision: outcome.decision,
            registered: registered,
            outcome: report.Confirmed(at: at),
          ))
        Error(Nil) ->
          promise.resolve(decided(
            now,
            outcome,
            report.Failed(
              stage: report.ConfirmingPunch,
              detail: "acuttis does not show "
                <> punch.to_string(target)
                <> " after registering it",
            ),
          ))
      }
  }
}

fn decided(
  now: clock.Instant,
  outcome: decision.Outcome,
  result: report.RunOutcome,
) -> report.Report {
  report.Decided(
    at: now,
    state: outcome.state,
    decision: outcome.decision,
    registered: outcome.registered,
    outcome: result,
  )
}

fn broke(
  now: clock.Instant,
  stage: report.Stage,
  error: browser.BrowserError,
) -> report.Report {
  report.Broke(at: now, stage: stage, detail: browser.error_to_string(error))
}

fn failed(
  stage: report.Stage,
  error: browser.BrowserError,
) -> report.RunOutcome {
  report.Failed(stage: stage, detail: browser.error_to_string(error))
}
