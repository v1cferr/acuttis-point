import acuttis_point/punch
import gleam/list

pub fn sequence_is_the_full_day_in_order_test() {
  assert punch.sequence
    == [punch.Entry, punch.LunchStart, punch.LunchEnd, punch.Exit]
}

pub fn position_follows_the_sequence_test() {
  let positions = list.map(punch.sequence, punch.position)
  assert positions == [0, 1, 2, 3]
}

pub fn next_walks_the_sequence_and_stops_at_exit_test() {
  assert punch.next(punch.Entry) == Ok(punch.LunchStart)
  assert punch.next(punch.LunchStart) == Ok(punch.LunchEnd)
  assert punch.next(punch.LunchEnd) == Ok(punch.Exit)
  assert punch.next(punch.Exit) == Error(Nil)
}

pub fn to_string_uses_log_identifiers_test() {
  let names = list.map(punch.sequence, punch.to_string)
  assert names == ["ENTRY", "LUNCH_START", "LUNCH_END", "EXIT"]
}
