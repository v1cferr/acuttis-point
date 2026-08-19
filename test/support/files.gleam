//// Deleting a file, for tests that need to start from nothing.
////
//// Test support only.

@external(javascript, "./files_ffi.mjs", "remove")
pub fn remove(path: String) -> Nil

/// Whether a file is there. Used to prove a session was kept, or thrown away.
pub fn exists(path: String) -> Bool {
  ffi_exists(path)
}

@external(javascript, "./files_ffi.mjs", "exists")
fn ffi_exists(path: String) -> Bool
