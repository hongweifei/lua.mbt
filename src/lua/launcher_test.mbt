// Checks for the command line and environment layer: the shape of the messages
// the interpreter reports on its way out, and where the package library takes
// its paths from.  The launcher itself lives in `cmd/main`, so what is checked
// here is the part of it the library exposes.

///|
/// The value of `package[field]` in a state.
fn package_field(st : @core.LuaState, field : String) -> String raise {
  match st.globals.get_str("package") {
    @core.VTable(pkg) =>
      match pkg.get_str(field) {
        @core.VStr(s) => @core.text_of(s.data())
        _ => fail("package." + field + " is not a string")
      }
    _ => fail("package is not a table")
  }
}

///|
/// Puts an environment variable back the way it was.
fn restore_env(name : String, saved : Bytes?) -> Unit {
  match saved {
    Some(v) => ignore(@host.lua_mbt_setenv(@core.bytes_of(name), v, 1))
    None => ignore(@host.lua_mbt_unsetenv(@core.bytes_of(name)))
  }
}

///|
/// The message the interpreter reports for a chunk that fails, which is what
/// the launcher prints after the program name.
fn reported_message(src : String) -> String raise {
  let state = create()
  let (status, msg) = run_protected_reporting(
    state,
    @core.bytes_of(src),
    "=test",
  )
  assert_eq(status, 1)
  @core.text_of(msg)
}

///|
/// An error object that is not a string is reported the way the reference's
/// `msghandler` reports it, and every traceback the launcher builds ends with
/// the line that stands for the call it made.
test "an error object is reported like the reference" {
  let text = reported_message("error({})")
  assert_true(
    text.has_prefix("(error object is a table value)\nstack traceback:"),
  )
  assert_true(text.has_suffix("\n\t[C]: in ?"))
}

///|
/// An error object with a `__tostring` is reported through it -- and without a
/// traceback, because the reference returns that result as the whole message.
test "an error object with __tostring is reported through it" {
  let text = reported_message(
    "error(setmetatable({}, {__tostring = function() return 'OBJ' end}))",
  )
  assert_eq(text, "OBJ")
}

///|
/// A string error keeps its message and gains a traceback, whose last line is
/// the host call the reference's own `pmain` stands for.
test "a string error gets a traceback ending at the host" {
  let text = reported_message("error('boom')")
  assert_true(text.has_prefix("test:1: boom\nstack traceback:"))
  assert_true(
    text.has_suffix(
      "\n\t[C]: in function 'error'\n\ttest:1: in main chunk\n\t[C]: in ?",
    ),
  )
}

///|
/// The package library takes its paths from the environment, the reference's
/// `setpath`: the versioned name wins over the plain one, a `;;` is where the
/// default templates go, and a state built with `-E` ignores both.
test "package paths come from the environment" {
  let path5 = @oslib.os_env("LUA_PATH_5_4")
  let path = @oslib.os_env("LUA_PATH")
  defer {
    restore_env("LUA_PATH_5_4", path5)
    restore_env("LUA_PATH", path)
  }
  ignore(@host.lua_mbt_unsetenv(b"LUA_PATH_5_4"))
  ignore(@host.lua_mbt_setenv(b"LUA_PATH", b"one", 1))
  assert_eq(package_field(create(), "path"), "one")
  ignore(@host.lua_mbt_setenv(b"LUA_PATH_5_4", b"two", 1))
  assert_eq(package_field(create(), "path"), "two")
  // A `;;` stands for the default templates, and what surrounds it stays.
  ignore(@host.lua_mbt_setenv(b"LUA_PATH_5_4", b"a;;b", 1))
  let inserted = package_field(create(), "path")
  assert_true(inserted.has_prefix("a;"))
  assert_true(inserted.has_suffix(";b"))
  assert_true(inserted.length() > "a;;b".length())
  // Without a `;;` the value is the whole path.
  ignore(@host.lua_mbt_setenv(b"LUA_PATH_5_4", b"a;b", 1))
  assert_eq(package_field(create(), "path"), "a;b")
  // `-E` ignores the environment entirely.
  assert_true(package_field(create_ignoring_env(true), "path") != "a;b")
}

///|
/// A failure inside a wrapped coroutine is re-raised where the wrapper was
/// called, with that call's position in front of the coroutine's own message --
/// which is what `auxwrap`'s `luaL_where(L, 1)` adds.
test "a wrapped coroutine failure names the call that resumed it" {
  let text = reported_message(
    "local f = coroutine.wrap(function () error('x') end); f()",
  )
  assert_true(text.has_prefix("test:1: test:1: x\nstack traceback:"))
}

///|
/// `package.config` reports the host's directory separator first, which is what
/// a searcher turns a module name's dots into.
test "package.config names the host directory separator" {
  let state = create()
  assert_true(package_field(state, "config").has_prefix(dirsep() + "\n"))
}
