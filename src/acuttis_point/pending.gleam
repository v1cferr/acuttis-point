//// The permission to punch: one token, spendable once.
////
//// This is the part that stops a punch happening twice. On two consecutive days
//// a manual punch landed minutes after an automatic one — 2026-08-19 at 17:31
//// and 17:41, 2026-08-20 at 07:59 and 08:08 — and the second one wrecked the
//// day, because Acuttis reads a stray marking as the next transition in the
//// sequence. Nothing in the schedule could have prevented it: there were simply
//// two actors and no agreement between them.
////
//// So now there is exactly one thing that authorises a punch, and it is a file.
//// A run that wants to punch has to take that file first, and taking it is a
//// rename — atomic, so of two runs racing for it exactly one wins. The tap on
//// the phone and the deadline that covers a missed tap compete for the same
//// token, which is what makes them alternatives rather than additions.
////
//// A failed punch puts the token back, because the deadline should still get its
//// turn. A successful one destroys it.

import acuttis_point/clock
import acuttis_point/punch
import gleam/list
import gleam/result
import gleam/string

pub type Pending {
  Pending(
    token: String,
    punch: punch.Punch,
    date: clock.Date,
    /// After this, the token is refused: a punch authorised at 12:35 and spent
    /// at 15:00 would be a lie about when the day happened.
    expires_at: clock.TimeOfDay,
  )
}

pub type ClaimError {
  /// No token to take. Either nothing was offered, or somebody already spent
  /// it — from here those are the same thing, and the answer to both is to do
  /// nothing.
  NothingPending
  /// A token was offered and this is not it.
  WrongToken
  /// Right token, wrong day: yesterday's authorisation cannot punch today.
  WrongDay(offered: clock.Date, pending: clock.Date)
  /// The window closed while it sat unspent.
  Expired(expired_at: clock.TimeOfDay)
  /// The file is there and says something this program does not understand.
  Unreadable(detail: String)
}

/// Where the claimed token waits while the punch it authorises is attempted.
/// Beside the offer, deliberately: a rename between two directories is not
/// guaranteed atomic, and a rename within one is.
pub fn claim_path(path: String) -> String {
  path <> ".claimed"
}

/// Offer a token. Overwrites whatever was there: an unspent offer from an
/// earlier window is stale by definition, and leaving it would let a stale tap
/// punch the wrong thing.
pub fn offer(
  path path: String,
  token token: String,
  punch target: punch.Punch,
  date date: clock.Date,
  expires_at expires_at: clock.TimeOfDay,
) -> Result(Pending, String) {
  let pending =
    Pending(token: token, punch: target, date: date, expires_at: expires_at)

  case write_file(path, to_text(pending)) {
    "" -> Ok(pending)
    detail -> Error(detail)
  }
}

/// A token nobody has seen before.
pub fn fresh_token() -> String {
  ffi_fresh_token()
}

/// Take the token, if it is there and it is the one being offered.
///
/// `offered` is the token the phone sent, or `Error(Nil)` for the deadline run,
/// which is entitled to whatever is pending without having to know its name.
///
/// The rename happens first and the checks come after, on purpose: winning the
/// race is what has to be atomic. A token taken and then found wanting is put
/// back, so a later legitimate claim still finds it.
pub fn claim(
  path path: String,
  offered offered: Result(String, Nil),
  now now: clock.Instant,
) -> Result(Pending, ClaimError) {
  let claimed = claim_path(path)

  case ffi_claim_file(path, claimed) {
    "missing" -> Error(NothingPending)
    "" -> validate(path, claimed, offered, now)
    detail -> Error(Unreadable(detail))
  }
}

/// Put a claimed token back, after a punch that did not land. The deadline run
/// gets its turn, which is the whole reason there is a deadline run.
pub fn release(path path: String, pending pending: Pending) -> Nil {
  let _ = write_file(path, to_text(pending))
  ffi_remove_file(claim_path(path))
}

/// Spend it. Called once a punch is on record, so nothing can spend it again.
pub fn spend(path path: String) -> Nil {
  ffi_remove_file(claim_path(path))
  ffi_remove_file(path)
}

/// Whether an offer is waiting, without taking it. For reporting only — deciding
/// anything on this would be a race, since the answer can change between the
/// question and the act.
pub fn offered(path: String) -> Result(Pending, ClaimError) {
  case ffi_read_file(path) {
    "" -> Error(NothingPending)
    text -> parse(text)
  }
}

pub fn error_to_string(error: ClaimError) -> String {
  case error {
    NothingPending -> "there is no punch waiting to be authorised"
    WrongToken -> "that is not the token this punch is waiting for"
    WrongDay(offered:, pending:) ->
      "that token is for "
      <> clock.date_to_string(pending)
      <> ", and today is "
      <> clock.date_to_string(offered)
    Expired(expired_at:) ->
      "that token expired at " <> clock.time_to_string(expired_at)
    Unreadable(detail:) -> "the pending punch could not be read: " <> detail
  }
}

fn validate(
  path: String,
  claimed: String,
  offered: Result(String, Nil),
  now: clock.Instant,
) -> Result(Pending, ClaimError) {
  case parse(ffi_read_file(claimed)) {
    Error(error) -> {
      // Unparseable: nothing to put back that would mean anything.
      ffi_remove_file(claimed)
      Error(error)
    }
    Ok(pending) -> {
      let verdict = case offered {
        Ok(token) if token != pending.token -> Error(WrongToken)
        _ ->
          case pending.date == now.date {
            False -> Error(WrongDay(offered: now.date, pending: pending.date))
            True ->
              case
                clock.minutes_since_midnight(now.time)
                > clock.minutes_since_midnight(pending.expires_at)
              {
                True -> Error(Expired(expired_at: pending.expires_at))
                False -> Ok(pending)
              }
          }
      }

      case verdict {
        Ok(_) -> verdict
        Error(_) -> {
          // Refused, so it goes back where it was: the tap that used the wrong
          // token must not cost the deadline its turn.
          release(path, pending)
          verdict
        }
      }
    }
  }
}

/// A handful of `key=value` lines rather than JSON, so reading it needs no
/// dependency and no parser that could disagree with the writer.
fn to_text(pending: Pending) -> String {
  "token="
  <> pending.token
  <> "\npunch="
  <> punch.to_string(pending.punch)
  <> "\ndate="
  <> clock.date_to_string(pending.date)
  <> "\nexpires="
  <> clock.time_to_string(pending.expires_at)
  <> "\n"
}

fn parse(text: String) -> Result(Pending, ClaimError) {
  let fields =
    text
    |> string.split(on: "\n")
    |> list.filter_map(fn(line) {
      case string.split_once(line, on: "=") {
        Ok(#(key, value)) -> Ok(#(string.trim(key), string.trim(value)))
        Error(Nil) -> Error(Nil)
      }
    })

  let field = fn(name) {
    list.key_find(fields, name) |> result.replace_error(missing(name))
  }

  use token <- result.try(field("token"))
  use raw_punch <- result.try(field("punch"))
  use raw_date <- result.try(field("date"))
  use raw_expires <- result.try(field("expires"))

  use target <- result.try(
    punch.from_string(raw_punch)
    |> result.replace_error(Unreadable(raw_punch <> " is not a punch")),
  )
  use date <- result.try(
    clock.parse_date(raw_date)
    |> result.replace_error(Unreadable(raw_date <> " is not a date")),
  )
  use expires_at <- result.try(
    clock.parse_time(raw_expires)
    |> result.replace_error(Unreadable(raw_expires <> " is not a time")),
  )

  case token {
    "" -> Error(Unreadable("the token is empty"))
    _ -> Ok(Pending(token:, punch: target, date:, expires_at:))
  }
}

fn missing(name: String) -> ClaimError {
  Unreadable("no " <> name <> " in the pending punch")
}

fn write_file(path: String, text: String) -> String {
  ffi_write_file(path, text)
}

@external(javascript, "./pending_ffi.mjs", "freshToken")
fn ffi_fresh_token() -> String

@external(javascript, "./pending_ffi.mjs", "writeFile")
fn ffi_write_file(path: String, text: String) -> String

@external(javascript, "./pending_ffi.mjs", "readFile")
fn ffi_read_file(path: String) -> String

@external(javascript, "./pending_ffi.mjs", "claimFile")
fn ffi_claim_file(from: String, to: String) -> String

@external(javascript, "./pending_ffi.mjs", "removeFile")
fn ffi_remove_file(path: String) -> Nil
