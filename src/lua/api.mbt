// Convenience layer used by the command line interface and by embedders.

///|
pub fn error_text(st : @core.LuaState, v : @core.Value) -> Bytes {
  @load.message_of_error(st, v)
}

///|
pub fn set_warnings_enabled(st : @core.LuaState, enabled : Bool) -> Unit {
  st.warn_enabled = enabled
}

///|
/// Defines the global `arg` table.
pub fn set_global_arg(st : @core.LuaState, t : @core.LTable) -> Unit {
  st.globals.set_str("arg", @core.VTable(t))
}

///|
pub fn global_field(st : @core.LuaState, name : String) -> @core.Value {
  st.globals.get_str(name)
}

///|
pub fn set_global(st : @core.LuaState, name : String, v : @core.Value) -> Unit {
  let _ = st.globals.set_str(name, v)
}

///|
/// Compiles a chunk without running it.  A failure is recorded for
/// `last_load_error` instead of being raised.
pub fn try_load(
  st : @core.LuaState,
  src : Bytes,
  name : String,
) -> @core.Value? {
  match @load.compile_source(st, src, name, @core.VTable(st.globals)) {
    @core.LoadOk(f) => {
      st.last_error = Bytes::new(0)
      Some(f)
    }
    @core.LoadError(msg) => {
      st.last_error = msg
      None
    }
  }
}

///|
/// The diagnostic of the most recent failed load.
pub fn last_load_error(st : @core.LuaState) -> Bytes? {
  if st.last_error.length() == 0 {
    None
  } else {
    Some(st.last_error)
  }
}

///|
/// Calls a value, returning whether it succeeded.
pub fn pcall_value(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
) -> (Bool, Array[@core.Value]) {
  @load.pcall_here(st, f, args)
}

///|
/// Calls a value and prints its results the way the interactive interpreter
/// does, by handing them to the global `print` as `l_print` does.  Returns the
/// message to report when the call failed, which carries a traceback.
pub fn call_printed(st : @core.LuaState, f : @core.Value) -> Bytes? {
  let (vals, msg) = call_with_handler(st, f, [])
  match vals {
    None => Some(msg)
    Some(vs) =>
      if vs.length() == 0 {
        None
      } else {
        let (ok, res) = pcall_value(st, global_field(st, "print"), vs)
        if ok {
          None
        } else {
          let e = if res.length() > 0 { res[0] } else { @core.VNil }
          Some(
            @core.bytes_of(
              "error calling 'print' (" + @core.text_of(error_text(st, e)) + ")",
            ),
          )
        }
      }
  }
}

///|
/// A stream reading standard input, for the interactive interpreter.
pub fn stdin_stream() -> @core.LFile {
  {
    handle: @host.lua_mbt_stdin(),
    closed: false,
    standard: true,
    popened: false,
    name: "stdin",
  }
}

///|
/// Whether standard input is a terminal, which decides whether the interpreter
/// reads it as a file or starts the read-eval-print loop.
pub fn stdin_is_tty() -> Bool {
  @host.lua_mbt_stdin_is_tty() != 0
}

///|
/// Whether a byte string ends with a suffix.
pub fn bytes_ends_with(b : Bytes, suffix : Bytes) -> Bool {
  if suffix.length() > b.length() {
    return false
  }
  @core.bytes_slice(b, b.length() - suffix.length(), suffix.length()) == suffix
}

///|
/// Constructors for the value type, for code outside the interpreter package.
pub fn value_nil() -> @core.Value {
  @core.VNil
}

///|
pub fn value_bool(b : Bool) -> @core.Value {
  @core.VBool(b)
}

///|
pub fn value_int(i : Int64) -> @core.Value {
  @core.VInt(i)
}

///|
pub fn value_number(d : Double) -> @core.Value {
  @core.VNum(d)
}

///|
pub fn value_string(s : String) -> @core.Value {
  @core.VStr(@core.LStr::of_string(s))
}

///|
pub fn value_bytes(b : Bytes) -> @core.Value {
  @core.VStr(@core.LStr::of_bytes(b))
}

///|
/// Whether a value is nil, for code outside the interpreter package.
pub fn value_is_nil(v : @core.Value) -> Bool {
  match v {
    @core.VNil => true
    _ => false
  }
}
