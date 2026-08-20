//// A local stand-in for Acuttis, for driving the real Playwright adapter.
////
//// Test support only.

import gleam/int
import gleam/javascript/array.{type Array}
import gleam/javascript/promise.{type Promise}

pub const username = "victor@example.test"

pub const password = "s3cret"

/// Start the fixture with the punches it already holds, and the time a new
/// punch will land at. Returns the base url it is listening on.
pub fn start(
  registered registered: List(String),
  lands_at lands_at: String,
) -> Promise(String) {
  ffi_start(array.from_list(registered), lands_at)
  |> promise.map(fn(port) { "http://127.0.0.1:" <> int.to_string(port) })
}

/// The punches the fixture holds now, which is how a test proves that a dry run
/// changed nothing.
pub fn punches() -> List(String) {
  array.to_list(ffi_punches())
}

pub fn stop() -> Promise(Nil) {
  ffi_stop()
}

/// A url pointing at a port nothing is listening on.
pub fn unreachable() -> String {
  "http://127.0.0.1:9"
}

/// Leave the trigger visible and stop the modal from opening, the way a session
/// kept across an Acuttis frontend change did on 2026-08-19.
pub fn break_punch_modal() -> Nil {
  ffi_break_punch_modal()
}

@external(javascript, "./fixture_ffi.mjs", "breakPunchModal")
fn ffi_break_punch_modal() -> Nil

@external(javascript, "./fixture_ffi.mjs", "start")
fn ffi_start(registered: Array(String), lands_at: String) -> Promise(Int)

@external(javascript, "./fixture_ffi.mjs", "punches")
fn ffi_punches() -> Array(String)

@external(javascript, "./fixture_ffi.mjs", "stop")
fn ffi_stop() -> Promise(Nil)
