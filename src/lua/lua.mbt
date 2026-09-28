// The public entry points of the interpreter.

///|
pub fn create() -> @core.LuaState {
  create_ignoring_env(false)
}

///|
/// Creates a state with the standard libraries.  When `ignore_env` is set the
/// package library ignores `LUA_PATH`, `LUA_CPATH` and the other variables it
/// would otherwise read, which is what the interpreter's `-E` asks for.  The
/// flag has to be in place before the libraries are opened, so it is a
/// parameter here rather than a setting afterwards.
pub fn create_ignoring_env(ignore_env : Bool) -> @core.LuaState {
  let state = @core.lua_state_new()
  if ignore_env {
    state.registry.set_str("LUA_NOENV", @core.VBool(true))
  }
  open_libraries(state)
  state
}

///|
/// Runs a chunk held in memory.  `name` follows the same convention as `load`:
/// a leading `@` marks a file name and `=` a literal name.
pub fn run_string(
  st : @core.LuaState,
  src : String,
  name : String,
) -> (Bool, Array[@core.Value]) {
  run_bytes(st, @core.bytes_of(src), name)
}

///|
pub fn run_bytes(
  st : @core.LuaState,
  src : Bytes,
  name : String,
) -> (Bool, Array[@core.Value]) {
  match @load.compile_source(st, src, name, @core.VTable(st.globals)) {
    @core.LoadError(msg) => (false, [@core.VStr(@core.LStr::of_bytes(msg))])
    @core.LoadOk(f) => @load.pcall_here(st, f, [])
  }
}

///|
/// Runs a file as a chunk.  The prefix a file may carry -- a UTF-8 byte order
/// mark, a first line starting with `#` -- is dropped here too, because that is
/// what `loadfile` and the launcher do with a file; a chunk given as a string
/// keeps them and fails, as it does in the reference.
pub fn run_file(
  st : @core.LuaState,
  path : String,
) -> (Bool, Array[@core.Value]) {
  let data = match @core.read_whole_file(@core.bytes_of(path)) {
    Ok(d) => d
    Err(e) =>
      return (
        false,
        [
          @core.VStr(
            @core.LStr::of_bytes(
              @core.bytes_concat([
                @core.bytes_of("cannot open "),
                @core.bytes_of(path),
                @core.bytes_of(": "),
                e,
              ]),
            ),
          ),
        ],
      )
  }
  run_bytes(st, @load.strip_chunk_prefix(data), "@" + path)
}

///|
/// The message for an error object that is neither a string nor something with
/// a usable `__tostring`, which the reference spells
/// `(error object is a <type> value)`.
fn error_object_message(st : @core.LuaState, e : @core.Value) -> String {
  @debuglib.traceback_body(
    st,
    st.current_thread,
    "(error object is a " + e.type_name() + " value)",
    1,
  )
}

///|
/// The text a value's own `__tostring` answers with, or `None` when it has no
/// metamethod, the metamethod fails, or it answers with something that is not a
/// string -- which is exactly when `luaL_callmeta` reports nothing and the
/// reference falls back to naming the value's type.
fn to_string_of(
  st : @core.LuaState,
  e : @core.Value,
) -> Bytes? raise @core.LuaRaised {
  let h = @vm.metafield(st, e, "__tostring")
  if @vm.is_callable(h) {
    let called = Some(@vm.call_metamethod(st, h, [e], 1, "")) catch {
      @core.LuaRaised(_) => None
      @core.LuaYield(v) => raise @core.LuaYield(v)
    }
    match called {
      Some(res) =>
        match @vm.nth_or_nil(res, 0) {
          @core.VStr(s) => Some(s.data())
          _ => None
        }
      None => None
    }
  } else {
    None
  }
}

///|
/// How an error object is reported: a string answers with itself, anything else
/// through its own `__tostring`, and failing that with the reference's
/// "(error object is a <type> value)".  This is the text the launcher's message
/// handler produces; the traceback it adds around one is not part of it.
pub fn error_message(st : @core.LuaState, e : @core.Value) -> Bytes {
  match e {
    @core.VStr(s) => s.data()
    _ => {
      // A metamethod that fails -- or tries to yield, which it cannot do from
      // here -- leaves nothing, which is what the fallback is for.  Swallowing
      // it here is also why this answers with bytes rather than raising: a host
      // formatting an error should not have to guard the formatter.
      let rendered = to_string_of(st, e) catch {
        @core.LuaRaised(_) => None
        @core.LuaYield(_) => None
      }
      match rendered {
        Some(b) => b
        None =>
          @core.bytes_of("(error object is a " + e.type_name() + " value)")
      }
    }
  }
}

///|
/// The message handler the launcher installs, the reference's `msghandler`.  A
/// string error gets a traceback; an error object that is not a string is
/// reported through its own `__tostring` when it has one -- and then *without* a
/// traceback, because the reference returns that result as the whole message --
/// or as `(error object is a <type> value)` with one.
fn script_msghandler(
  st : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let e = if args.length() > 0 { args[0] } else { @core.VNil }
  match e {
    @core.VStr(s) =>
      @core.Many([
        @core.VStr(
          @core.LStr::of_string(
            @debuglib.traceback_body(
              st,
              st.current_thread,
              @core.text_of(s.data()),
              1,
            ),
          ),
        ),
      ])
    _ =>
      @core.One(
        @core.VStr(
          @core.LStr::of_bytes(
            match to_string_of(st, e) {
              Some(b) => b
              None => @core.bytes_of(error_object_message(st, e))
            },
          ),
        ),
      )
  }
}

///|
/// The body of the frame the launcher calls Lua from.  This is the reference's
/// `pmain`: the chunk (or the `-e`/`-l` call) runs one frame above it, so
/// `debug.getinfo` finds a C frame at the bottom of the stack and a traceback
/// ends with `[C]: in ?`, exactly as the reference's does.
fn pmain_body(
  st : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let f = if args.length() > 0 { args[0] } else { @core.VNil }
  @core.Many(@vm.call_value(st, f, args[1:].to_owned(), -1))
}

///|
/// Calls a value with the launcher's message handler installed, one frame above
/// a host frame.  The handler runs where the error is raised, so the message it
/// builds still has the frames of the failing call: that is what makes an
/// uncaught error print a traceback.  Returns the results, or the message to
/// report when the call failed.
pub fn call_with_handler(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
) -> (Array[@core.Value]?, Bytes) {
  let thread = st.current_thread
  let saved_frames = thread.frames.length()
  let saved_stack = thread.stack.length()
  let saved_errfunc = thread.errfunc
  thread.errfunc = @core.VBuiltin(
    @core.LBuiltin::make("msghandler", 1, script_msghandler),
  )
  let call_args : Array[@core.Value] = [f]
  for a in args {
    call_args.push(a)
  }
  let pmain = @core.VBuiltin(
    @core.make_builtin("pmain", @core.BK_NORMAL, -1, pmain_body, []),
  )
  let r = Ok(@vm.call_value(st, pmain, call_args, -1)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(_) =>
      Err(@core.VStr(@core.LStr::of_string(@vm.yield_error(st, thread))))
  }
  thread.errfunc = saved_errfunc
  match r {
    Ok(vals) => (Some(vals), Bytes::new(0))
    Err(e) => {
      thread.frames.truncate(saved_frames)
      thread.stack.truncate(saved_stack)
      (None, @load.message_of_error(st, e))
    }
  }
}

///|
/// Runs a chunk the way the launcher does: with the message handler installed,
/// and reporting nothing.  Returns the exit status and, on failure, the message
/// to report -- which carries a traceback.
pub fn run_protected_reporting(
  st : @core.LuaState,
  src : Bytes,
  name : String,
) -> (Int, Bytes) {
  run_protected_with_args(st, src, name, [])
}

///|
/// `run_protected_reporting` for a chunk that takes arguments, which is how the
/// launcher hands a script the words that followed its name: they arrive as the
/// chunk's varargs.
pub fn run_protected_with_args(
  st : @core.LuaState,
  src : Bytes,
  name : String,
  args : Array[@core.Value],
) -> (Int, Bytes) {
  match @load.compile_source(st, src, name, @core.VTable(st.globals)) {
    @core.LoadError(msg) => (1, msg)
    @core.LoadOk(f) => {
      let (vals, msg) = call_with_handler(st, f, args)
      let _ = vals
      if msg.length() == 0 {
        (0, msg)
      } else {
        (1, msg)
      }
    }
  }
}
