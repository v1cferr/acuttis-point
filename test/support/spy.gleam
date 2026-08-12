//// A mutable cell, so a fake port can record what it was asked to do.
////
//// Test support only. Nothing in `src` needs mutation.

pub type Cell(value)

@external(javascript, "./spy_ffi.mjs", "newCell")
pub fn new(value: value) -> Cell(value)

@external(javascript, "./spy_ffi.mjs", "getCell")
pub fn get(cell: Cell(value)) -> value

@external(javascript, "./spy_ffi.mjs", "setCell")
pub fn set(cell: Cell(value), value: value) -> Nil
