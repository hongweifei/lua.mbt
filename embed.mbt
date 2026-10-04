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
/// Reads a global as the type the host asked for.  The type comes from an
/// annotation, since a call site cannot name it:
///
/// ```mbt check
/// test "reading a global as a MoonBit type" {
///   let lua = Lua::new()
///   let missing : Result[String, LuaError] = lua.get_as("非")
///   assert_true(missing is Err(_))
///   lua.set("问候", "你好")
///   let got : Result[String, LuaError] = lua.get_as("问候")
///   assert_eq(got.unwrap(), "你好")
/// }
/// ```
pub fn[T : FromLua] Lua::get_as(
  self : Lua,
  name : String,
) -> Result[T, LuaError] {
  self.value_as(self.get(name))
}

///|
/// The kind of conversion `FromLua` does, with a failure reported as a
/// `LuaError` naming what was asked for ("number expected, got string", the
/// wording the libraries use in an argument error).
///
/// ```mbt check
/// test "reading one value" {
///   let lua = Lua::new()
///   let items : Result[Array[Int64], LuaError] = lua.value_as(
///     lua.eval("return {7, 8, 9}").unwrap(),
///   )
///   assert_eq(items.unwrap(), [7L, 8L, 9L])
///   let wrong : Result[Array[Int64], LuaError] = lua.value_as(
///     lua.eval("return {7, 'x'}").unwrap(),
///   )
///   // A failure inside a table names the *entry*, not the table that held it.
///   assert_eq(wrong.unwrap_err().message, "number expected, got string")
/// }
/// ```
pub fn[T : FromLua] Lua::value_as(self : Lua, v : Value) -> Result[T, LuaError] {
  match T::from_lua(v) {
    Some(x) => Ok(x)
    None => {
      let (wanted, got) = T::expected_and_got(v)
      Err(LuaError::expected(self.st, wanted, got))
    }
  }
}

///|
/// Converts a whole result list, each value to the same type -- a chunk that
/// answers `return "a", "b", "c"`.  This reads the *list of results*, not a Lua
/// table; `Array[T]` in `FromLua` is the one that reads a table as a sequence.
pub fn[T : FromLua] Lua::values_as(
  self : Lua,
  vs : Array[Value],
) -> Result[Array[T], LuaError] {
  let out : Array[T] = []
  for v in vs {
    match self.value_as(v) {
      Ok(x) => out.push(x)
      Err(e) => return Err(e)
    }
  }
  Ok(out)
}

///|
/// Runs a chunk and reads its first result as the type the host asked for.
/// Shorthands for the common ones are `eval_int`, `eval_number`, `eval_text`,
/// `eval_bytes` and `eval_bool`, which need no annotation.
///
/// ```mbt check
/// test "a chunk's first result, typed" {
///   let lua = Lua::new()
///   let rows : Result[Array[Int64], LuaError] = lua.eval_as("return {1, 2, 3}")
///   assert_eq(rows.unwrap(), [1L, 2L, 3L])
///   let not_a_number : Result[Int64, LuaError] = lua.eval_as("return nil")
///   assert_eq(not_a_number.unwrap_err().message, "number expected, got nil")
///   // `{}` is an empty table, not a missing value.
///   let empty_table : Result[Int64, LuaError] = lua.eval_as("return {}")
///   assert_eq(empty_table.unwrap_err().message, "number expected, got table")
/// }
/// ```
pub fn[T : FromLua] Lua::eval_as(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[T, LuaError] {
  match self.eval(source, args~) {
    Err(e) => Err(e)
    Ok(v) => self.value_as(v)
  }
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
/// uses, so a config file's `"42"` and its `42` both work.  A name for
/// `eval_as[Int64]`, which a call site cannot write.
pub fn Lua::eval_int(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Int64, LuaError] {
  let read : Result[Int64, LuaError] = self.eval_as(source, args~)
  read
}

///|
/// Runs a chunk answering with a number, as a float.
pub fn Lua::eval_number(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Double, LuaError] {
  let read : Result[Double, LuaError] = self.eval_as(source, args~)
  read
}

///|
/// Runs a chunk answering with a string.  The bytes come back exactly, so a
/// string holding non-UTF-8 data survives the trip.
pub fn Lua::eval_bytes(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[Bytes, LuaError] {
  let read : Result[Bytes, LuaError] = self.eval_as(source, args~)
  read
}

///|
/// Runs a chunk answering with text.
pub fn Lua::eval_text(
  self : Lua,
  source : String,
  args? : Array[Value] = [],
) -> Result[String, LuaError] {
  let read : Result[String, LuaError] = self.eval_as(source, args~)
  read
}

///|
/// Runs a chunk and answers with the truthiness of its first result, which is
/// Lua's: only `nil` and `false` are not true, so `0` and `""` are.  Reading a
/// `boolean` *value* is the strict one (`Bool::from_lua`); this is the question
/// Lua itself asks of a condition.
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

///|
/// Loads a module the way `require` does, and answers with what it returned --
/// the table a module file ends with, or the value a loader handed back.  The
/// name goes through the searchers, so `package.path`, `package.preload` and
/// `package.loaded` all apply, and a second call gets the cached module.
///
/// ```mbt check
/// test "require from the host" {
///   let lua = Lua::new()
///   lua.preload("配置", fn(args) {
///     let _ = args
///     let t = new_table()
///     t.set_str("上限", Value::VInt(42L))
///     Ok([t.as_value()])
///   })
///   let m = lua.require("配置").unwrap()
///   assert_eq(m.type_name(), "table")
///   // The loader ran once: `require` caches, so the two handles are one table.
///   assert_true(m.raw_equal(lua.require("配置").unwrap()))
/// }
/// ```
pub fn Lua::require(self : Lua, name : String) -> Result[Value, LuaError] {
  match self.call_global("require", args=[Value::text(name)]) {
    Err(e) => Err(e)
    Ok([v, ..]) => Ok(v)
    // `require` answers with at least one value -- a loader that returns nothing
    // gets the reference's dummy `true` -- so nothing reaches this arm.
    Ok([]) => Ok(@core.VNil)
  }
}

///|
/// Registers a host function as a module, so a script's `require("名字")` finds
/// it: the function runs as the loader and answers with the module's value.  This
/// is `package.preload` under the name -- which also means a script can overwrite
/// it, and `package.loaded` keeps the usual cache.
///
/// ```mbt check
/// test "a MoonBit module a script can require" {
///   let lua = Lua::new()
///   lua.preload("配置", fn(args) {
///     let _ = args
///     let t = new_table()
///     t.set_str("上限", Value::VInt(42L))
///     Ok([t.as_value()])
///   })
///   assert_eq(lua.eval_int("return require('配置').上限").unwrap(), 42L)
/// }
/// ```
pub fn Lua::preload(self : Lua, name : String, f : HostFunction) -> Unit {
  let pkg : Table? = read_lua(self.globals().get_str("package"))
  let preload : Table? = match pkg {
    Some(p) => read_lua(p.get_str("preload"))
    None => None
  }
  match preload {
    Some(t) => t.set_str(name, host_function(name, f))
    // `Lua::new` opens the `package` library, so there is nowhere to install the
    // loader only on a state built without it.
    None => ()
  }
}

///|
/// Installs a MoonBit function as a **native module**, which is the thing the
/// reference's `require` finds in a shared library: `require("名字")` runs the
/// loader with `(name, ":native:")` and caches what it answers in
/// `package.loaded`.  Unlike `Lua::preload` the loader is in no Lua-visible
/// table, so a script can neither list what the host installed nor clear it.
/// This build opens no shared library it can enter, so this is how a script gets
/// a module written below Lua.
///
/// ```mbt check
/// test "a module the host compiled in" {
///   let lua = Lua::new()
///   let seen : Array[Value] = []
///   lua.register_module("conf", fn(args) {
///     for v in args {
///       seen.push(v)
///     }
///     let t = new_table()
///     t.set_str("limit", Value::VInt(42L))
///     Ok([t.as_value()])
///   })
///   assert_eq(lua.eval_int("return require('conf').limit").unwrap(), 42L)
///   // `require` hands the loader the name and where the loader came from.
///   assert_eq(seen.length(), 2)
///   assert_eq(seen[0].as_text(), Some("conf"))
///   assert_eq(seen[1].as_text(), Some(":native:"))
///   // The loader ran once: `require` caches, so the two handles are one table.
///   let m = lua.require("conf").unwrap()
///   assert_true(m.raw_equal(lua.require("conf").unwrap()))
///   // A script cannot see the loader, and so cannot clear it.
///   assert_true(lua.eval_bool("return package.preload.conf == nil").unwrap())
///   // It is found by the searcher that owns the native slot, not a new one.
///   assert_eq(lua.eval_int("return #package.searchers").unwrap(), 3L)
/// }
/// ```
pub fn Lua::register_module(
  self : Lua,
  name : String,
  f : HostFunction,
) -> Unit {
  self.st.native_mods.set_str(name, host_function(name, f))
}
