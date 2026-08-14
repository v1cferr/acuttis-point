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
import acuttis_point/punch
import acuttis_point/report
import acuttis_point/state
import gleam/javascript/promise.{type Promise}

pub fn run(
  settings settings: config.Config,
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
) -> Promise(report.Report) {
  use opened <- promise.await(port.open())

  case opened {
    Error(error) -> promise.resolve(broke(now, report.StartingBrowser, error))
    Ok(session) -> {
      use result <- promise.await(visit(settings, secrets, now, port, session))
      // The browser is closed whatever happened, so a failed run does not
      // leave a Chromium behind for the next timer to trip over.
      use _ <- promise.await(port.close(session))
      promise.resolve(result)
    }
  }
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
    decision.Register(punch: target, ..) ->
      case settings.dry_run {
        True -> promise.resolve(decided(now, outcome, report.Withheld))
        False -> register(port, session, now, outcome, target)
      }
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

  let result = case read {
    Error(error) -> failed(report.ConfirmingPunch, error)
    Ok(registered) ->
      case state.registered_at(registered, target) {
        Ok(at) -> report.Confirmed(at: at)
        Error(Nil) ->
          report.Failed(
            stage: report.ConfirmingPunch,
            detail: "acuttis does not show "
              <> punch.to_string(target)
              <> " after registering it",
          )
      }
  }

  promise.resolve(decided(now, outcome, result))
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
