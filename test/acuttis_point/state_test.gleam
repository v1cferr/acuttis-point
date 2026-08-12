import acuttis_point/clock
import acuttis_point/punch
import acuttis_point/state

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

fn registered(entries: List(#(punch.Punch, String))) -> List(state.Registered) {
  case entries {
    [] -> []
    [#(kind, time), ..rest] -> [
      state.Registered(punch: kind, at: at(time)),
      ..registered(rest)
    ]
  }
}

pub fn empty_day_waits_for_entry_test() {
  assert state.from_punches([]) == state.Waiting(punch.Entry)
}

pub fn partial_day_waits_for_the_next_punch_test() {
  assert state.from_punches(registered([#(punch.Entry, "07:55")]))
    == state.Waiting(punch.LunchStart)

  assert state.from_punches(
      registered([#(punch.Entry, "07:55"), #(punch.LunchStart, "12:00")]),
    )
    == state.Waiting(punch.LunchEnd)

  assert state.from_punches(
      registered([
        #(punch.Entry, "07:55"),
        #(punch.LunchStart, "12:00"),
        #(punch.LunchEnd, "13:02"),
      ]),
    )
    == state.Waiting(punch.Exit)
}

pub fn full_day_is_completed_test() {
  assert state.from_punches(
      registered([
        #(punch.Entry, "07:55"),
        #(punch.LunchStart, "12:00"),
        #(punch.LunchEnd, "13:02"),
        #(punch.Exit, "17:31"),
      ]),
    )
    == state.Completed
}

pub fn punches_out_of_order_are_invalid_test() {
  assert state.from_punches(registered([#(punch.LunchStart, "12:00")]))
    == state.Invalid(state.OutOfOrder(
      expected: punch.Entry,
      found: punch.LunchStart,
    ))
}

pub fn a_fifth_punch_is_invalid_test() {
  assert state.from_punches(
      registered([
        #(punch.Entry, "07:55"),
        #(punch.LunchStart, "12:00"),
        #(punch.LunchEnd, "13:02"),
        #(punch.Exit, "17:31"),
        #(punch.Entry, "18:00"),
      ]),
    )
    == state.Invalid(state.ExtraPunch(punch.Entry))
}

pub fn timestamps_going_backwards_are_invalid_test() {
  assert state.from_punches(
      registered([#(punch.Entry, "12:00"), #(punch.LunchStart, "11:00")]),
    )
    == state.Invalid(state.TimeWentBackwards(
      punch: punch.LunchStart,
      at: at("11:00"),
      previous: at("12:00"),
    ))
}

pub fn punches_sharing_a_minute_are_allowed_test() {
  assert state.from_punches(
      registered([#(punch.Entry, "12:00"), #(punch.LunchStart, "12:00")]),
    )
    == state.Waiting(punch.LunchEnd)
}

pub fn is_registered_splits_at_the_waiting_punch_test() {
  let current = state.Waiting(punch.LunchEnd)
  assert state.is_registered(current, punch.Entry)
  assert state.is_registered(current, punch.LunchStart)
  assert !state.is_registered(current, punch.LunchEnd)
  assert !state.is_registered(current, punch.Exit)
  assert state.is_registered(state.Completed, punch.Exit)
}

pub fn to_string_describes_the_state_test() {
  assert state.to_string(state.Waiting(punch.LunchStart))
    == "WAITING(LUNCH_START)"
  assert state.to_string(state.Completed) == "COMPLETED"
  assert state.to_string(
      state.Invalid(state.OutOfOrder(
        expected: punch.Entry,
        found: punch.LunchStart,
      )),
    )
    == "INVALID(expected ENTRY but found LUNCH_START)"
}

pub fn registered_to_string_lists_punches_test() {
  assert state.registered_to_string([]) == "none"
  assert state.registered_to_string(
      registered([#(punch.Entry, "07:55"), #(punch.LunchStart, "12:00")]),
    )
    == "ENTRY@07:55, LUNCH_START@12:00"
}
