//// The punches that make up a working day.

/// A single timekeeping event, as Acuttis models it.
pub type Punch {
  Entry
  LunchStart
  LunchEnd
  Exit
}

/// The order the punches of one day have to be registered in.
pub const sequence: List(Punch) = [Entry, LunchStart, LunchEnd, Exit]

/// Stable identifier used in logs and in the `Action:` field of a run record.
pub fn to_string(punch: Punch) -> String {
  case punch {
    Entry -> "ENTRY"
    LunchStart -> "LUNCH_START"
    LunchEnd -> "LUNCH_END"
    Exit -> "EXIT"
  }
}

/// Position in `sequence`, counting from zero.
/// The inverse of `to_string`, for reading a punch back off disk. Anything else
/// is refused rather than guessed at: a file that says something unexpected is
/// not a file to act on.
pub fn from_string(raw: String) -> Result(Punch, Nil) {
  case raw {
    "ENTRY" -> Ok(Entry)
    "LUNCH_START" -> Ok(LunchStart)
    "LUNCH_END" -> Ok(LunchEnd)
    "EXIT" -> Ok(Exit)
    _ -> Error(Nil)
  }
}

pub fn position(punch: Punch) -> Int {
  case punch {
    Entry -> 0
    LunchStart -> 1
    LunchEnd -> 2
    Exit -> 3
  }
}

/// The punch expected after `punch`, or `Error(Nil)` once the day is complete.
pub fn next(punch: Punch) -> Result(Punch, Nil) {
  case punch {
    Entry -> Ok(LunchStart)
    LunchStart -> Ok(LunchEnd)
    LunchEnd -> Ok(Exit)
    Exit -> Error(Nil)
  }
}

/// The punch expected before `punch`, or `Error(Nil)` for the first one.
pub fn previous(punch: Punch) -> Result(Punch, Nil) {
  case punch {
    Entry -> Error(Nil)
    LunchStart -> Ok(Entry)
    LunchEnd -> Ok(LunchStart)
    Exit -> Ok(LunchEnd)
  }
}
