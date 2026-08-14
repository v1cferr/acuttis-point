//// Deleting a file, for tests that need to start from nothing.
////
//// Test support only.

@external(javascript, "./files_ffi.mjs", "remove")
pub fn remove(path: String) -> Nil
