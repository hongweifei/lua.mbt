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
/// Runs a file as a chunk.
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
  run_bytes(st, data, "@" + path)
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
/// The message handler the launcher installs, the reference's `msghandler`.  A
/// string error gets a traceback; an error object that is not a string is
/// reported through its own `__tostring` when it has one -- and then *without* a
/// traceback, because the reference returns that result as the whole message --
/// or as `(error object is a <type> value)` with one.
fn script_msghandler(
  st : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let e = if args.length() > 0 { args[0] } else { @core.VNil }
  match e {
    @core.VStr(s) =>
      [
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
      ]
    _ => {
      let h = @vm.metafield(st, e, "__tostring")
      if @vm.is_callable(h) {
        let called = Some(@vm.call_metamethod(st, h, [e], 1, "")) catch {
          @core.LuaRaised(_) => None
          @core.LuaYield(v) => raise @core.LuaYield(v)
        }
        match called {
          Some(res) =>
            match @vm.nth_or_nil(res, 0) {
              @core.VStr(s) => [@core.VStr(s)]
              _ =>
                [@core.VStr(@core.LStr::of_string(error_object_message(st, e)))]
            }
          None =>
            [@core.VStr(@core.LStr::of_string(error_object_message(st, e)))]
        }
      } else {
        [@core.VStr(@core.LStr::of_string(error_object_message(st, e)))]
      }
    }
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
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = if args.length() > 0 { args[0] } else { @core.VNil }
  @vm.call_value(st, f, args[1:].to_owned(), -1)
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
  match @load.compile_source(st, src, name, @core.VTable(st.globals)) {
    @core.LoadError(msg) => (1, msg)
    @core.LoadOk(f) => {
      let (vals, msg) = call_with_handler(st, f, [])
      let _ = vals
      if msg.length() == 0 {
        (0, msg)
      } else {
        (1, msg)
      }
    }
  }
}
