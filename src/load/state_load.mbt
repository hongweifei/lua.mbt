// Loading chunks: turning source text into a callable closure, and running it.

///|
/// The name a chunk is displayed under, following the convention that a leading
/// `=` marks a literal name and a leading `@` a file name.
pub fn chunk_id(name : String) -> String {
  @core.chunk_id_of(@core.bytes_of(name))
}

///|
/// Parses and compiles a chunk, returning the closure or the diagnostic.
/// `env` becomes the chunk's `_ENV` upvalue.
pub fn compile_source(
  st : @core.LuaState,
  src : Bytes,
  name : String,
  env : @core.Value,
) -> @core.LoadOutcome {
  if @chunk.is_binary_chunk(src) {
    return @chunk.undump(st, src, env, name)
  }
  let display = chunk_id(name)
  let parsed = Ok(@compiler.parse_chunk(src, display)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(_) =>
      Err(
        @core.VStr(
          @core.LStr::of_string(@vm.yield_error(st, st.current_thread)),
        ),
      )
  }
  match parsed {
    Err(e) => @core.LoadError(message_of_error(st, e))
    Ok(body) => {
      // The prototype keeps the original chunk name (with any '@' or '='
      // prefix); the display form is only for error messages.
      let compiled = Ok(
        @compiler.compile_chunk(body, @core.LStr::of_string(name)),
      ) catch {
        @core.LuaRaised(e) => Err(e)
        @core.LuaYield(_) =>
          Err(
            @core.VStr(
              @core.LStr::of_string(@vm.yield_error(st, st.current_thread)),
            ),
          )
      }
      match compiled {
        Err(e) => @core.LoadError(message_of_error(st, e))
        Ok(proto) => {
          let upvals : Array[@core.LUpval] = [@core.LUpval::new_closed(env)]
          let cl : @core.LClosure = {
            proto,
            upvals,
            id: @core.next_object_id(),
            mark_epoch: 0,
          }
          @core.LoadOk(@core.VFunc(cl))
        }
      }
    }
  }
}

///|
/// The bytes of an error, with position information when the error is a string
/// that does not carry any yet.
pub fn message_of_error(st : @core.LuaState, e : @core.Value) -> Bytes {
  match e {
    @core.VStr(s) => s.data()
    _ => {
      let r = Ok(@vm.to_string(st, e)) catch {
        @core.LuaRaised(_) => Err(e)
        @core.LuaYield(_) => Err(e)
      }
      match r {
        Ok(b) => b
        Err(v) =>
          @core.bytes_of("(error object is a " + v.type_name() + " value)")
      }
    }
  }
}

///|
/// Loads and runs a chunk in the global environment.
pub fn do_string(
  st : @core.LuaState,
  src : Bytes,
  name : String,
) -> Array[@core.Value] raise @core.LuaRaised {
  match compile_source(st, src, name, @core.VTable(st.globals)) {
    @core.LoadError(msg) =>
      @core.raise_fresh(st, @core.VStr(@core.LStr::of_bytes(msg)))
    @core.LoadOk(f) => @vm.call_value(st, f, [], -1)
  }
}

///|
/// Calls a value, catching errors, and returns whether the call succeeded.
pub fn pcall_here(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
) -> (Bool, Array[@core.Value]) {
  let thread = st.current_thread
  let saved_frames = thread.frames.length()
  let saved_stack = thread.stack.length()
  let saved_thread = st.current_thread
  // A protected call from the host installs no message handler, which is
  // `lua_pcall`'s `errfunc` of 0: an error comes back as it was raised, without
  // the traceback an enclosing `xpcall` (or the launcher) would have added.
  let saved_errfunc = thread.errfunc
  thread.errfunc = @core.VNil
  // As `f_call` does: entering a protected call from the host is a C-call
  // boundary, so nothing below it may yield.
  thread.ny = thread.ny + 1
  let r = Ok(@vm.call_value(st, f, args, -1)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(_) =>
      Err(
        @core.VStr(
          @core.LStr::of_string(@vm.yield_error(st, st.current_thread)),
        ),
      )
  }
  thread.ny = thread.ny - 1
  thread.errfunc = saved_errfunc
  // Whatever happened, the caller's stack must look exactly as before.
  thread.frames.truncate(saved_frames)
  thread.stack.truncate(saved_stack)
  st.current_thread = saved_thread
  match r {
    Ok(vals) => (true, vals)
    Err(e) => (false, [e])
  }
}

///|----------------------------------------------------------------
/// Positions

///|----------------------------------------------------------------

///|----------------------------------------------------------------
/// Packages

///|----------------------------------------------------------------

///|
/// The `package` table, created on first use.
pub fn package_self(st : @core.LuaState) -> @core.LTable {
  match st.registry.get_str("package") {
    @core.VTable(t) => t
    _ => {
      let t = @core.LTable::new()
      let _ = st.registry.set_str("package", @core.VTable(t))
      t
    }
  }
}

///|
/// A sub-table of `package`, created on first use.
pub fn package_table(st : @core.LuaState, name : String) -> @core.LTable {
  let pkg = package_self(st)
  match pkg.get_str(name) {
    @core.VTable(t) => t
    _ => {
      let t = @core.LTable::new()
      pkg.set_str(name, @core.VTable(t))
      t
    }
  }
}
