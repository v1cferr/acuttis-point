//// The one rule that decides whether to punch.
////
//// Everything the automation knows folds into this function: the schedule, the
//// current moment and what Acuttis already has on record. It has no effects of
//// its own, so every branch below is reachable from a test.
////
//// The bias is towards doing nothing. A punch is only registered inside the
//// window that follows its scheduled time; before the window opens the run is
//// a no-op, and once the window has closed it aborts rather than register a
//// time that no longer reflects reality.

import acuttis_point/clock
import acuttis_point/config
import acuttis_point/punch
import acuttis_point/state
import gleam/int
import gleam/list

pub type Decision {
  /// Register this punch now. `expected_at` is the scheduled time it answers.
  Register(punch: punch.Punch, expected_at: clock.TimeOfDay)
  /// The day is fine as it stands; leave Acuttis alone.
  Skip(SkipReason)
  /// Something does not add up. Leave Acuttis alone and ask for a human.
  Abort(AbortReason)
}

pub type SkipReason {
  NotAWorkDay(clock.Weekday)
  NonWorkingDate(clock.Date)
  DayAlreadyComplete
  /// The punch due in the window that is open right now is already on record.
  AlreadyRegistered(punch: punch.Punch, at: clock.TimeOfDay)
  TooEarly(next: punch.Punch, opens_at: clock.TimeOfDay)
}

pub type AbortReason {
  /// The punch was due too long ago to still be registered honestly.
  WindowClosed(
    punch: punch.Punch,
    expected_at: clock.TimeOfDay,
    minutes_late: Int,
  )
  InconsistentState(state.Inconsistency)
}

/// The decision together with the state it was taken from, since a run record
/// reports both.
pub type Outcome {
  Outcome(state: state.DayState, decision: Decision)
}

pub fn decide(
  settings settings: config.Config,
  now now: clock.Instant,
  registered registered: List(state.Registered),
) -> Outcome {
  let current = state.from_punches(registered)
  Outcome(state: current, decision: choose(settings, now, registered, current))
}

/// The `Action` field of a run record: the punch this run is about, if any.
pub fn action_to_string(decision: Decision) -> String {
  case decision {
    Register(punch: target, ..) -> punch.to_string(target)
    Skip(_) -> "NONE"
    Abort(_) -> "NONE"
  }
}

pub fn to_string(decision: Decision) -> String {
  case decision {
    Register(punch: target, expected_at:) ->
      "REGISTER "
      <> punch.to_string(target)
      <> " scheduled for "
      <> clock.time_to_string(expected_at)
    Skip(reason) -> "SKIP " <> skip_reason_to_string(reason)
    Abort(reason) -> "ABORT " <> abort_reason_to_string(reason)
  }
}

pub fn skip_reason_to_string(reason: SkipReason) -> String {
  case reason {
    NotAWorkDay(day) ->
      clock.weekday_to_string(day) <> " is not a configured work day"
    NonWorkingDate(date) ->
      clock.date_to_string(date) <> " is configured as a day without expedient"
    DayAlreadyComplete -> "every punch of the day is already registered"
    AlreadyRegistered(punch: target, at:) ->
      punch.to_string(target)
      <> " is already registered at "
      <> clock.time_to_string(at)
    TooEarly(next:, opens_at:) ->
      punch.to_string(next)
      <> " is not due until "
      <> clock.time_to_string(opens_at)
  }
}

pub fn abort_reason_to_string(reason: AbortReason) -> String {
  case reason {
    WindowClosed(punch: target, expected_at:, minutes_late:) ->
      punch.to_string(target)
      <> " was due at "
      <> clock.time_to_string(expected_at)
      <> ", "
      <> int.to_string(minutes_late)
      <> " minutes ago; refusing to backdate it"
    InconsistentState(inconsistency) ->
      "acuttis shows an impossible day: "
      <> state.inconsistency_to_string(inconsistency)
  }
}

/// The calendar comes first: on a day the automation does not own, nothing
/// about the punches matters, not even an odd looking one.
fn choose(
  settings: config.Config,
  now: clock.Instant,
  registered: List(state.Registered),
  current: state.DayState,
) -> Decision {
  let today = clock.weekday(now.date)
  case list.contains(settings.work_days, today) {
    False -> Skip(NotAWorkDay(today))
    True ->
      case list.contains(settings.skip_dates, now.date) {
        True -> Skip(NonWorkingDate(now.date))
        False ->
          case current {
            state.Invalid(inconsistency) ->
              Abort(InconsistentState(inconsistency))
            state.Completed -> Skip(DayAlreadyComplete)
            state.Waiting(missing) ->
              consider(settings, now, registered, missing)
          }
      }
  }
}

fn consider(
  settings: config.Config,
  now: clock.Instant,
  registered: List(state.Registered),
  missing: punch.Punch,
) -> Decision {
  let expected_at = config.scheduled_time(settings.schedule, missing)
  let minutes_late = clock.minutes_between(from: expected_at, to: now.time)

  case minutes_late > settings.tolerance_minutes {
    True -> Abort(WindowClosed(punch: missing, expected_at:, minutes_late:))
    False ->
      case minutes_late >= 0 {
        True -> Register(punch: missing, expected_at: expected_at)
        False -> not_due_yet(settings, now, registered, missing, expected_at)
      }
  }
}

/// The next punch is not due yet. When the one before it was registered inside
/// the window that is open right now, this run has nothing left to add — which
/// is what turns a second run in the same window into a no-op instead of a
/// duplicate punch.
fn not_due_yet(
  settings: config.Config,
  now: clock.Instant,
  registered: List(state.Registered),
  missing: punch.Punch,
  expected_at: clock.TimeOfDay,
) -> Decision {
  let too_early = Skip(TooEarly(next: missing, opens_at: expected_at))

  case punch.previous(missing) {
    Error(Nil) -> too_early
    Ok(earlier) ->
      case
        state.registered_at(registered, earlier),
        in_window(settings, now, earlier)
      {
        Ok(at), True -> Skip(AlreadyRegistered(punch: earlier, at: at))
        _, _ -> too_early
      }
  }
}

fn in_window(
  settings: config.Config,
  now: clock.Instant,
  target: punch.Punch,
) -> Bool {
  let offset =
    clock.minutes_between(
      from: config.scheduled_time(settings.schedule, target),
      to: now.time,
    )
  offset >= 0 && offset <= settings.tolerance_minutes
}
