import acuttis_point/acuttis
import acuttis_point/clock
import acuttis_point/punch
import acuttis_point/state

fn at(raw: String) -> clock.TimeOfDay {
  let assert Ok(time) = clock.parse_time(raw)
  time
}

pub fn punch_rows_map_onto_the_sequence_in_order_test() {
  assert acuttis.read_punches(["07:55", "12:01"])
    == Ok([
      state.Registered(punch: punch.Entry, at: at("07:55")),
      state.Registered(punch: punch.LunchStart, at: at("12:01")),
    ])
}

pub fn an_empty_list_is_a_day_not_started_test() {
  assert acuttis.read_punches([]) == Ok([])
}

pub fn a_time_is_found_amid_the_rest_of_the_row_test() {
  assert acuttis.read_punches([
      "Entrada 07:55",
      "schedule 12:01 Saída para almoço",
      "12/08/2026 13:02",
    ])
    == Ok([
      state.Registered(punch: punch.Entry, at: at("07:55")),
      state.Registered(punch: punch.LunchStart, at: at("12:01")),
      state.Registered(punch: punch.LunchEnd, at: at("13:02")),
    ])
}

pub fn the_first_time_in_a_row_wins_test() {
  assert acuttis.read_punches(["08:03 (registrado 08:04)"])
    == Ok([state.Registered(punch: punch.Entry, at: at("08:03"))])
}

pub fn a_row_without_a_time_is_an_error_test() {
  assert acuttis.read_punches(["Entrada", "12:01"])
    == Error(acuttis.NoTimeIn("Entrada"))
}

pub fn a_loose_looking_number_is_not_a_time_test() {
  // Two digits, a colon and two digits, or nothing. Anything looser would read
  // an id or a duration as a punch.
  assert acuttis.read_punches(["8:034"]) == Error(acuttis.NoTimeIn("8:034"))
  assert acuttis.read_punches(["1:2:3"]) == Error(acuttis.NoTimeIn("1:2:3"))
  assert acuttis.read_punches(["25:00"]) == Error(acuttis.NoTimeIn("25:00"))
  assert acuttis.read_punches(["0803"]) == Error(acuttis.NoTimeIn("0803"))
}

pub fn a_seconds_suffix_still_reads_as_the_time_test() {
  assert acuttis.read_punches(["07:55:41"])
    == Ok([state.Registered(punch: punch.Entry, at: at("07:55"))])
}

pub fn more_rows_than_a_day_has_is_an_error_test() {
  assert acuttis.read_punches([
      "07:55",
      "12:01",
      "13:02",
      "17:31",
      "18:00",
    ])
    == Error(acuttis.MorePunchesThanADayHas(5))
}

pub fn error_to_string_shows_what_could_not_be_read_test() {
  assert acuttis.error_to_string(acuttis.NoTimeIn("Entrada"))
    == "no time found in \"Entrada\""
  assert acuttis.error_to_string(acuttis.MorePunchesThanADayHas(5))
    == "acuttis shows 5 punches, more than a day has"
}
