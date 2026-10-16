import acuttis_point/audit
import acuttis_point/clock
import acuttis_point/mirror

fn on(raw: String) -> clock.Date {
  let assert Ok(date) = clock.parse_date(raw)
  date
}

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn day(date: String, times: List(String)) -> audit.Day {
  audit.Day(date: on(date), times: list_map(times, at), verdict: audit.Complete)
}

/// Newest first, the way the receipt reads and the way `audit` returns them.
fn receipt() -> audit.Audit {
  let days = [
    day("2026-10-16", ["08:30", "12:31"]),
    day("2026-10-15", ["08:30", "12:31", "13:59"]),
    day("2026-07-30", ["14:04", "17:54"]),
  ]
  audit.Audit(days: days, inconsistent: [])
}

/// A page boundary can fall inside a day, and the oldest one is where it falls.
/// Half a day written down is worse than a day missing: the half looks whole,
/// and it looks exactly like the short day that means somebody forgot to punch.
pub fn the_oldest_day_is_dropped_when_the_receipt_was_not_exhausted_test() {
  let kept = mirror.worth_copying(audited: receipt(), exhausted: False)
  let assert Ok(summary) = mirror.summarise(kept)

  assert summary.days == 2
  assert summary.oldest == on("2026-10-15")
  assert summary.newest == on("2026-10-16")
}

/// When the receipt itself ran out, the oldest day is a whole day.
pub fn every_day_is_kept_when_the_receipt_ran_out_test() {
  let kept = mirror.worth_copying(audited: receipt(), exhausted: True)
  let assert Ok(summary) = mirror.summarise(kept)

  assert summary.days == 3
  assert summary.markings == 7
  assert summary.oldest == on("2026-07-30")
  assert summary.newest == on("2026-10-16")
}

pub fn an_empty_receipt_copies_nothing_test() {
  let empty = audit.Audit(days: [], inconsistent: [])
  assert mirror.worth_copying(audited: empty, exhausted: False) == []
  assert mirror.summarise([]) == Error(Nil)
  assert mirror.record(path: "gleam.toml/nope.db", days: [], at: moment())
    == mirror.NothingToCopy
}

/// A copy is a copy: it must not be able to take a run down with it.
pub fn a_mirror_that_cannot_be_written_is_reported_not_raised_test() {
  let assert mirror.Failed(_) =
    mirror.record(
      path: "gleam.toml/nope.db",
      days: [day("2026-10-16", ["08:30"])],
      at: moment(),
    )
}

pub fn the_line_says_what_was_kept_test() {
  let kept = mirror.worth_copying(audited: receipt(), exhausted: True)
  let assert Ok(summary) = mirror.summarise(kept)

  assert mirror.to_line(mirror.Copied(summary))
    == "mirror=ok days=3 markings=7 covering=2026-07-30..2026-10-16"
  assert mirror.to_line(mirror.NothingToCopy) == "mirror=skipped"
}

fn moment() -> clock.Instant {
  clock.Instant(date: on("2026-10-16"), time: at("18:40"))
}

fn list_map(items: List(a), run: fn(a) -> b) -> List(b) {
  case items {
    [] -> []
    [first, ..rest] -> [run(first), ..list_map(rest, run)]
  }
}
