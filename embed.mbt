///|----------------------------------------------------------------
/// The interpreter as a MoonBit object
///
/// One `Lua` is one Lua world: its globals, its libraries, its running
/// coroutines.  Nothing here raises a MoonBit error -- a chunk that fails is an
/// `Err(LuaError)` -- so a host program decides whether a script's failure is
/// fatal.  `state` is the escape hatch to the lower-level interface, and
/// anything the language itself can do stays available through it.

///|----------------------------------------------------------------

///|
/// A Lua state: the globals, the standard libraries and the threads a script
/// makes.  Two states share nothing.
pub struct Lua {
  // Private on purpose: `state` is the way out, so a host cannot leave the
  // handle and the state it drives disagreeing about which is which.
  priv st : @core.LuaState
}

///|
/// The state this handle drives, for the lower-level interface.
pub fn Lua::state(self : Lua) -> @core.LuaState {
  self.st
}

///|
/// A state with every standard library open.  `ignore_env~` is the interpreter's
/// own `-E`: `package.path` and `package.cpath` then come from the built-in
/// defaults rather than from `LUA_PATH` and `LUA_CPATH`.
pub fn Lua::new(ignore_env? : Bool = false) -> Lua {
  { st: @lualib.create_ignoring_env(ignore_env), }
}

///|
/// The globals as a table: `lua.globals().get_str("x")` reads `x`, and writing to
/// it is writing to the script's environment.
pub fn Lua::globals(self : Lua) -> Table {
  self.st.globals
}

///|
/// Runs a chunk and answers with its results, or with the error that escaped.
/// A chunk is a vararg function, so `args~` is what its `...` sees.
///
/// ```mbt check
/// test "a chunk's results" {
///   let lua = Lua::new()
///   let vs = lua.run("return 1 + 2, 'x'").unwrap()
///   assert_eq(vs[0].as_integer(), Some(3L))
///   assert_eq(vs[1].as_text(), Some("x"))
/// }
/// ```
pub fn Lua::run(
  self : Lua,
  source : String,
  name? : String = "=chunk",
  args? : Array[Value] = [],
) -> Result[Array[Value], LuaError] {
  match self.load(source, name~) {
    Err(e) => Err(e)
    Ok(f) => self.call(f, args~)
  }
}

///|
/// Compiles a chunk without running it, giving the value `Lua::call` takes.
/// Nothing about it runs, which is what makes this the check-a-script-first
/// entry point; a chunk that does not compile answers with the message `load`
/// gives.
pub fn Lua::load(
  self : Lua,
  source : String,
  name? : String = "=chunk",
) -> Result[Value, LuaError] {
  match @lualib.try_load(self.st, @core.bytes_of(source), name) {
    Some(f) => Ok(f)
    None => Err(LuaError::of_load(self.st))
  }
}

///|
/// Runs a file as a chunk: the chunk is named after the file, and a UTF-8 byte
/// order mark or a leading `#!` line is dropped the way the language drops them
/// for a file.  `args~` are the chunk's varargs, which is what a script run as
/// `lua file.lua a b` sees in `...`; `dofile` itself passes none, so this loads
/// first and then calls, as the interpreter's own launcher does.
pub fn Lua::run_file(
  self : Lua,
  path : String,
  args? : Array[Value] = [],
) -> Result[Array[Value], LuaError] {
  match self.load_file(path) {
    Err(e) => Err(e)
    Ok(f) => self.call(f, args~)
  }
}

///|
/// Compiles a file as a chunk without running it, as `loadfile` does.  A file
/// that cannot be read answers `Err`, because `loadfile` answers `nil, message`
/// rather than raising and that pair becomes the error here.
pub fn Lua::load_file(self : Lua, path : String) -> Result[Value, LuaError] {
  let loaded = self.call_global("loadfile", args=[Value::text(path)])
  match loaded {
    Err(e) => Err(e)
    Ok(vals) =>
      match vals {
        [v, msg, ..] if v.is_nil() => Err(LuaError::of(self.st, msg))
        [f, ..] => Ok(f)
        _ => Err(LuaError::of(self.st, @core.VNil))
      }
  }
}

///|
/// Calls a value with arguments and answers with its results.  Anything callable
/// works: a function a chunk defined, a host function this layer installed, or a
/// table with a `__call`.
pub fn Lua::call(
  self : Lua,
  f : Value,
  args? : Array[Value] = [],
) -> Result[Array[Value], LuaError] {
  let (ok, vals) = @lualib.pcall_value(self.st, f, args)
  if ok {
    Ok(vals)
  } else {
    Err(
      LuaError::of(
        self.st,
        if vals.length() > 0 {
          vals[0]
        } else {
          @core.VNil
        },
      ),
    )
  }
}

///|
/// Calls a global by name, which is how a script exports an entry point.
///
/// ```mbt check
/// test "calling a function a chunk defined" {
///   let lua = Lua::new()
///   let _ = lua.run("function double(x) return x * 2 end")
///   let vs = lua.call_global("double", args=[Value::VInt(21L)]).unwrap()
///   assert_eq(vs[0].as_integer(), Some(42L))
/// }
/// ```
pub fn Lua::call_global(
  self : Lua,
  name : String,
  args? : Array[Value] = [],
) -> Result[Array[Value], LuaError] {
  self.call(self.get(name), args~)
}

///|
/// Reads a global.  A name the script never set is `Value::VNil`, as in Lua.
pub fn Lua::get(self : Lua, name : String) -> Value {
  @lualib.global_field(self.st, name)
}

///|
/// Writes a global, converting whatever the host has: `set("limit", 3)`,
/// `set("name", "hi")`, `set("items", [1, 2, 3])`, `set("on", true)`.
pub fn[T : ToLua] Lua::set(self : Lua, name : String, v : T) -> Unit {
  @lualib.set_global(self.st, name, v.to_lua())
}

///|
/// Runs a chunk and answers with its first result, or `nil` when it answers with
/// nothing at all.
pub fn Lua::eval(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Value, LuaError] {
  match self.run(source, args~) {
    Err(e) => Err(e)
    Ok(vals) => Ok(if vals.length() > 0 { vals[0] } else { @core.VNil })
  }
}

///|
/// Runs a chunk answering with a number and reads the integer in it: an integer,
/// a float holding one, or a string spelling one -- the rule `math.tointeger`
/// uses, so a config file's `"42"` and its `42` both work.
pub fn Lua::eval_int(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Int64, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) =>
      match v.as_integer() {
        Some(i) => Ok(i)
        None => Err(LuaError::expected(self.st, "number", v))
      }
  }
}

///|
/// Runs a chunk answering with a number, as a float.
pub fn Lua::eval_number(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Double, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) =>
      match v.as_double() {
        Some(d) => Ok(d)
        None => Err(LuaError::expected(self.st, "number", v))
      }
  }
}

///|
/// Runs a chunk answering with a string.  The bytes come back exactly, so a
/// string holding non-UTF-8 data survives the trip.
pub fn Lua::eval_bytes(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Bytes, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) =>
      match v.as_bytes() {
        Some(b) => Ok(b)
        None => Err(LuaError::expected(self.st, "string", v))
      }
  }
}

///|
/// Runs a chunk answering with text.
pub fn Lua::eval_text(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[String, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) =>
      match v.as_text() {
        Some(s) => Ok(s)
        None => Err(LuaError::expected(self.st, "string", v))
      }
  }
}

///|
/// Runs a chunk and answers with the truthiness of its first result, which is
/// Lua's: only `nil` and `false` are not true, so `0` and `""` are.
pub fn Lua::eval_bool(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Bool, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) => Ok(v.is_truthy())
  }
}

///|
/// The text of a value as Lua's `tostring` gives it, honouring a `__tostring`
/// and reporting the reference's "(error object is a table value)" when the
/// metamethod is missing or fails.
pub fn Lua::show(self : Lua, v : Value) -> String {
  @core.text_of(@lualib.error_text(self.st, v))
}
