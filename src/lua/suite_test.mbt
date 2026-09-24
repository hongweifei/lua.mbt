// Runs the Lua test suites in `tests/` through the interpreter.

///|
///Runs the Lua test suites in `tests/` through the interpreter.
pub fn run_suite(path : String) -> Unit raise Failure {
  let data = match @core.read_whole_file(@core.bytes_of(path)) {
    Ok(d) => d
    Err(e) => fail("cannot read " + path + ": " + @core.text_of(e))
  }
  let state = create()
  let (ok, vals) = run_bytes(state, data, "@" + path)
  if !ok {
    let message = if vals.length() > 0 {
      error_text(state, vals[0])
    } else {
      @core.bytes_of("unknown error")
    }
    fail(path + ": " + @core.text_of(message))
  }
}

///|
test "language suite" {
  run_suite("tests/language.lua")
}

///|
test "standard library suite" {
  run_suite("tests/stdlib.lua")
}

///|
test "module loading suite" {
  run_suite("tests/require_test.lua")
}

///|
test "runnable examples" {
  run_suite("tests/examples.lua")
}
