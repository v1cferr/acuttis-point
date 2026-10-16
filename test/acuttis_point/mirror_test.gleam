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

/// Acuttis drops rows rather than days, so its retention cuts inside a day as
/// readily as between two. On 2026-10-16 the mirror stored 03/08 as
/// `13:53 17:44` while FAI's folha for that Monday read
/// `08:04 12:43 13:53 17:44`: an afternoon wearing a whole day's clothes, and
/// one that no later receipt would ever correct.
pub fn the_oldest_day_is_always_dropped_test() {
  let kept = mirror.worth_copying(audited: receipt())
  let assert Ok(summary) = mirror.summarise(kept)

  assert summary.days == 2
  assert summary.markings == 5
  assert summary.oldest == on("2026-10-15")
  assert summary.newest == on("2026-10-16")
}

/// Which costs nothing once it runs daily: a day is the oldest for one reading
/// only, and the reading before that had it in the middle, written down whole.
pub fn a_day_dropped_today_was_kept_yesterday_test() {
  let yesterday =
    audit.Audit(
      days: [
        day("2026-10-15", ["08:30", "12:31", "13:59", "17:30"]),
        day("2026-10-14", ["08:00"]),
      ],
      inconsistent: [],
    )
  let kept = mirror.worth_copying(audited: yesterday)
  let assert Ok(summary) = mirror.summarise(kept)

  assert summary.days == 1
  assert summary.newest == on("2026-10-15")
  assert summary.markings == 4
}

pub fn an_empty_receipt_copies_nothing_test() {
  let empty = audit.Audit(days: [], inconsistent: [])
  assert mirror.worth_copying(audited: empty) == []
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
  let kept = mirror.worth_copying(audited: receipt())
  let assert Ok(summary) = mirror.summarise(kept)

  assert mirror.to_line(mirror.Copied(summary))
    == "mirror=ok days=2 markings=5 covering=2026-10-15..2026-10-16"
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
