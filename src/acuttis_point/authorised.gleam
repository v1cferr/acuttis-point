//// A punch that somebody asked for.
////
//// Two things can ask: a tap on the notification, which arrives carrying the
//// token it was given, and the deadline run, which is entitled to whatever is
//// pending without knowing its name. They race for the same token and exactly
//// one wins, so a tap and a deadline can never both punch — which is the whole
//// reason any of this exists.
////
//// Claiming does not decide anything. Once the token is taken the ordinary run
//// happens, with the ordinary rules: it reads the day itself, and if the punch
//// is already there it registers nothing. The token is the permission; the day
//// model is still the judge.

import acuttis_point/browser
import acuttis_point/clock
import acuttis_point/config
import acuttis_point/credentials
import acuttis_point/pending
import acuttis_point/report
import acuttis_point/runner
import gleam/javascript/promise.{type Promise}

pub type Authorised {
  /// The token was taken and the run happened. Whatever it decided is in here.
  Ran(finished: runner.Completed)
  /// The token was not taken, and nothing touched Acuttis.
  Declined(at: clock.Instant, reason: pending.ClaimError)
}

pub fn run(
  settings settings: config.Config,
  secrets secrets: credentials.Credentials,
  now now: clock.Instant,
  port port: browser.Port(session),
  offered offered: Result(String, Nil),
) -> Promise(Authorised) {
  case pending.claim(path: settings.pending_file, offered:, now:) {
    Error(reason) -> promise.resolve(Declined(at: now, reason: reason))
    Ok(claimed) -> {
      // Asking is over; this run acts. A claimed token must never come back
      // through the asking path, or it would offer itself a second time.
      let acting = config.Config(..settings, ask: False)

      use finished <- promise.await(runner.run(
        settings: acting,
        secrets: secrets,
        now: now,
        port: port,
      ))

      settle(settings, claimed, finished.report)
      promise.resolve(Ran(finished: finished))
    }
  }
}

/// Zero when there was nothing to do about it. A token that could not be spent
/// for a reason worth looking at exits non-zero, so the unit shows red.
pub fn exit_code(authorised: Authorised) -> Int {
  case authorised {
    Ran(finished:) -> report.exit_code(finished.report)
    // Nothing pending is the normal answer to a second tap, and to a deadline
    // arriving after the tap was honoured. It is not a problem.
    Declined(reason: pending.NothingPending, ..) -> 0
    Declined(..) -> 1
  }
}

pub fn to_line(authorised: Authorised) -> String {
  case authorised {
    Ran(finished:) -> report.to_line(finished.report)
    Declined(at:, reason:) ->
      clock.date_to_string(at.date)
      <> " "
      <> clock.time_to_string(at.time)
      <> " result=DECLINED action=NONE reason=\""
      <> pending.error_to_string(reason)
      <> "\""
  }
}

/// Spend the token, or put it back.
///
/// Spent when the punch is on record — including when it was already there,
/// since a token whose punch exists has nothing left to authorise. Put back
/// only when the punch genuinely did not happen, because the deadline run
/// deserves its turn at a failure the tap ran into.
fn settle(
  settings: config.Config,
  claimed: pending.Pending,
  record: report.Report,
) -> Nil {
  case record {
    report.Decided(outcome: report.Confirmed(..), ..)
    | report.Decided(outcome: report.NothingToDo, ..) ->
      pending.spend(settings.pending_file)
    _ -> pending.release(path: settings.pending_file, pending: claimed)
  }
}
