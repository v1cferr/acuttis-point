//// Enough of the filesystem to check what a run left behind.
////
//// Test support only.

/// Whether a file is there, and has something in it. Size matters here: an
/// empty PNG would satisfy "the screenshot exists" while proving nothing.
pub fn has_content(path: String) -> Bool {
  ffi_size(path) > 0
}

pub fn remove(path: String) -> Nil {
  ffi_remove(path)
}

@external(javascript, "./files_ffi.mjs", "size")
fn ffi_size(path: String) -> Int

@external(javascript, "./files_ffi.mjs", "remove")
fn ffi_remove(path: String) -> Nil
