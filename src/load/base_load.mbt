// Loading chunks and modules.

///|
/// Loads a chunk from a string or from a function that returns its pieces.
pub fn base_load(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let chunk = if args.length() >= 1 { args[0] } else { @core.VNil }
  // `lua_tolstring` decides the kind: a string or a number is source text, a
  // function is a reader, and anything else is refused as a function -- which
  // is why `load(1)` compiles "1" (and fails on the syntax) while `load({})`
  // is an argument error.
  let is_reader = match chunk {
    @core.VFunc(_) | @core.VBuiltin(_) => true
    _ => false
  }
  // Without an explicit chunk name, a string chunk is named after its own
  // source and a reader-function chunk is named "=(load)".
  let name = if args.length() >= 2 && !args[1].is_nil() {
    @core.text_of(@core.check_str(state, args, 2, "load").data())
  } else if is_reader {
    "=(load)"
  } else {
    @core.text_of(chunk_to_source(state, chunk, args.length() >= 1))
  }
  let mode = if args.length() >= 3 && !args[2].is_nil() {
    @core.text_of(@core.check_str(state, args, 3, "load").data())
  } else {
    "bt"
  }
  let env = if args.length() >= 4 {
    args[3]
  } else {
    @core.VTable(state.globals)
  }
  if is_reader {
    return @core.Many(load_from_reader(state, chunk, name, mode, env))
  }
  let source = chunk_to_source(state, chunk, args.length() >= 1)
  // `checkmode` looks at what the chunk actually is before deciding whether
  // the requested mode refuses it.
  @core.Many(
    finish_compiled(
      state,
      source,
      @chunk.is_binary_chunk(source),
      name,
      mode,
      env,
    ),
  )
}

///|
/// The text of a chunk given as a string or a number, or the argument error
/// `luaL_checktype(L, 1, LUA_TFUNCTION)` raises for anything else.
fn chunk_to_source(
  state : @core.LuaState,
  chunk : @core.Value,
  present : Bool,
) -> Bytes raise @core.LuaRaised {
  match chunk {
    @core.VStr(s) => s.data()
    @core.VInt(i) => @core.int64_to_bytes(i)
    @core.VNum(d) => @core.double_to_g14(d)
    _ =>
      @core.arg_error(
        state,
        1,
        "load",
        "function expected, got " +
        (if present { @core.type_error_name(state, chunk) } else { "no value" }),
      )
  }
}

///|
/// Loads a chunk from a file.
pub fn base_loadfile(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  @core.Many(do_loadfile(state, args))
}

///|
/// The work of `loadfile`, which `dofile` also runs.  It answers with a list
/// rather than a `BuiltinResult`: both callers hand the same values on.
fn do_loadfile(
  state : @core.LuaState,
  args : ArrayView[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let env = if args.length() >= 3 {
    args[2]
  } else {
    @core.VTable(state.globals)
  }
  let name = if args.length() >= 1 && !args[0].is_nil() {
    @core.text_of(@core.check_str(state, args, 1, "loadfile").data())
  } else {
    ""
  }
  let data = if name == "" {
    @core.read_stdin_all()
  } else {
    match @core.read_whole_file(@core.bytes_of(name)) {
      Ok(d) => d
      Err(e) =>
        return [
          @core.VNil,
          @core.VStr(
            @core.LStr::of_bytes(
              @core.bytes_concat([
                @core.bytes_of("cannot open "),
                @core.bytes_of(name),
                @core.bytes_of(": "),
                e,
              ]),
            ),
          ),
        ]
    }
  }
  // The reference names a file's chunk `@name` and standard input `=stdin`
  // (`luaL_loadfilex`); the distinction is visible in `debug.getinfo`'s source
  // and in how a long name is shortened.
  let chunk_name = if name == "" { "=stdin" } else { "@" + name }
  match compile_source(state, data, chunk_name, env) {
    @core.LoadOk(f) => [f]
    @core.LoadError(msg) => [@core.VNil, @core.VStr(@core.LStr::of_bytes(msg))]
  }
}

///|
/// Runs a file as a chunk.
pub fn base_dofile(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let r = do_loadfile(state, args)
  match r[0] {
    @core.VNil => @core.raise_fresh(state, r[1])
    f => @core.Many(@vm.call_value(state, f, [], -1))
  }
}

///|
/// `require`, implemented over the searchers in `package.searchers`.  Each
/// searcher receives the module name and returns either a loader function, which
/// `require` then calls, or a string describing why it could not find the module.
pub fn base_require(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "require")
  let loaded = package_table(state, "loaded")
  // "Already loaded" is about *truth*, not about presence: a module whose
  // loader returned `false` (or that set `package.loaded[name] = false`) is
  // loaded again on the next `require` (`lua_toboolean` in `ll_require`).
  match loaded.get(@core.VStr(name)) {
    @core.VNil | @core.VBool(false) => ()
    v => return @core.One(v)
  }
  // `package.searchers` has to be a table; anything else is reported before a
  // search starts (`findloader`).
  let searchers = match package_self(state).get_str("searchers") {
    @core.VTable(t) => t
    _ => @core.runtime_error(state, "'package.searchers' must be a table")
  }
  let mut i = 1L
  let messages : Array[Bytes] = []
  while true {
    let searcher = searchers.get(@core.VInt(i))
    if searcher.is_nil() {
      break
    }
    let res = @vm.call_value(state, searcher, [@core.VStr(name)], 2)
    let first = if res.length() > 0 { res[0] } else { @core.VNil }
    let extra = if res.length() > 1 { res[1] } else { @core.VNil }
    match first {
      @core.VFunc(_) | @core.VBuiltin(_) => {
        let r = @vm.call_value(state, first, [@core.VStr(name), extra], 1)
        let val = if r.length() > 0 { r[0] } else { @core.VNil }
        // A loader that returns nothing may still have set the module itself
        // (`package.loaded[...] = value`), and that value is what `require`
        // answers; only when it set nothing does `require` stand for `true`.
        // Either way the loader data comes back as the second result, which is
        // what the searcher handed over (a file name, or ":preload:").
        let mut result = val
        if result.is_nil() {
          let existing = loaded.get(@core.VStr(name))
          if existing.is_nil() {
            let _ = loaded.set(@core.VStr(name), @core.VBool(true))
            result = @core.VBool(true)
          } else {
            result = existing
          }
        } else {
          let _ = loaded.set(@core.VStr(name), val)
        }
        return @core.Two(result, extra)
      }
      @core.VStr(msg) => messages.push(msg.data())
      _ => ()
    }
    i = i + 1L
  }
  let parts : Array[Bytes] = [
    @core.bytes_of("module '"),
    name.data(),
    @core.bytes_of("' not found:"),
  ]
  // Each searcher's complaint starts its own line: the prefix belongs to the
  // joining, not to the searcher (the reference's `findloader` adds it before
  // every searcher's message).
  for m in messages {
    parts.push(@core.bytes_of("\n\t"))
    parts.push(m)
  }
  @core.raise_fresh(
    state,
    @core.VStr(@core.LStr::of_bytes(@core.bytes_concat(parts))),
  )
}

///|----------------------------------------------------------------
/// Library installation

///|----------------------------------------------------------------

///|
/// The error value a message handler returns for `v`, which is what
/// `luaG_errormsg` does at the point of the raise -- before anyone catches it.
/// `load` catches its reader's failures itself, so without this the handler
/// installed by a launcher would never see them and the message would be
/// missing the traceback the reference appends.
fn reported_error(state : @core.LuaState, v : @core.Value) -> @core.Value {
  state.current_thread.fresh_error = true
  @vm.handle_at_raise_point(state, state.current_thread, v)
}

///|
/// A reader function as a stream of pieces: `next` answers with the piece that
/// came back, or `None` once the reader is spent, and `failure` with the failure
/// that ended it -- a reader that raised, or one that answered with something
/// which is not a string.  A failure is kept rather than raised because the
/// caller reports it *after* the parse: it has to outrank the syntax error the
/// missing bytes would otherwise cause.
priv struct ReaderSource {
  next : () -> Bytes?
  failure : () -> @core.Value?
}

///|
/// Wraps a reader.  A reader that raises, or that answers with something which
/// is not a string, does not propagate the error: `load` hands back `nil` with
/// the message instead, like `load_aux`.
fn reader_source(state : @core.LuaState, reader : @core.Value) -> ReaderSource {
  let mut ended = false
  let mut failure : @core.Value? = None
  let next = () => {
    if ended {
      return None
    }
    let answer = Ok(@vm.call_value(state, reader, [], 1)) catch {
      @core.LuaRaised(e) => Err(reported_error(state, e))
      @core.LuaYield(_) =>
        Err(
          @core.VStr(
            @core.LStr::of_string(@vm.yield_error(state, state.current_thread)),
          ),
        )
    }
    match answer {
      Err(e) => {
        failure = Some(e)
        ended = true
        None
      }
      Ok(values) => {
        let v = if values.length() > 0 { values[0] } else { @core.VNil }
        match v {
          @core.VStr(s) =>
            if s.length() > 0 {
              Some(s.data())
            } else {
              ended = true
              None
            }
          // `lua_isstring` accepts a number, and the piece is what
          // `lua_tolstring` writes out -- so a reader may hand over numerals.
          @core.VInt(_) | @core.VNum(_) => Some(@core.number_to_bytes(v))
          @core.VNil => {
            ended = true
            None
          }
          _ => {
            failure = Some(
              reported_error(
                state,
                @core.VStr(
                  @core.LStr::of_string(
                    // `generic_reader` raises this through `luaL_error`, so it carries
                    // `luaL_where(L, 1)` -- the position of whoever called `load`.
                    @core.current_position(state) +
                    "reader function must return a string",
                  ),
                ),
              ),
            )
            ended = true
            None
          }
        }
      }
    }
  }
  { next, failure: () => failure, }
}

///|
/// The stream handed to the lexer, with the piece that was pulled to look at its
/// first byte put back in front of it.  Nothing can have failed by then -- the
/// piece arrived -- so the feed starts clean.
fn feed_from(source : ReaderSource, first : Bytes) -> @compiler.SourceFeed {
  let mut pending : Bytes? = Some(first)
  let next = () => {
    match pending {
      Some(p) => {
        pending = None
        Some(p)
      }
      None => (source.next)()
    }
  }
  { next, failure: source.failure, }
}

///|
/// The mode check and the compilation, for the paths that end up with the
/// chunk's bytes in hand: a string chunk, and a precompiled one that had to be
/// read whole before it could be undumped.
fn finish_compiled(
  state : @core.LuaState,
  source : Bytes,
  binary : Bool,
  name : String,
  mode : String,
  env : @core.Value,
) -> Array[@core.Value] {
  match mode_refusal(mode, binary) {
    Some(msg) => [@core.VNil, @core.VStr(@core.LStr::of_string(msg))]
    None => compile_chunk_value(state, source, name, env)
  }
}

///|
/// `checkmode`: whether the requested mode refuses a chunk of this kind, which
/// is decided by what the chunk *is* rather than by what it looked like.  It is
/// asked as soon as the first byte is known, so a refusal does not read the
/// rest of a chunk it is going to reject.
fn mode_refusal(mode : String, binary : Bool) -> String? {
  let kind = if binary { "binary" } else { "text" }
  if mode.contains(if binary { "b" } else { "t" }) {
    None
  } else {
    Some("attempt to load a " + kind + " chunk (mode is '" + mode + "')")
  }
}

///|
/// The compilation itself, as the values `load` hands back.
fn compile_chunk_value(
  state : @core.LuaState,
  source : Bytes,
  name : String,
  env : @core.Value,
) -> Array[@core.Value] {
  match compile_source(state, source, name, env) {
    @core.LoadOk(f) => [f]
    @core.LoadError(msg) => [@core.VNil, @core.VStr(@core.LStr::of_bytes(msg))]
  }
}

///|
/// `load` with a reader function.  The chunk is read as the parser asks for it,
/// so a reader with side effects is left where the parser stopped and a reader
/// that never ends fails on the syntax error its extra input causes -- which is
/// what the reference does, reading its reader through `luaZ_fill` the same way.
///
/// A precompiled chunk is the exception: it has to be read whole before it can
/// be undumped, and the first byte is what says so.
fn load_from_reader(
  state : @core.LuaState,
  reader : @core.Value,
  name : String,
  mode : String,
  env : @core.Value,
) -> Array[@core.Value] {
  let source = reader_source(state, reader)
  let first = match (source.next)() {
    Some(p) => p
    None => {
      match (source.failure)() {
        Some(e) => return [@core.VNil, e]
        None => ()
      }
      // Nothing at all is an empty chunk, which compiles like any other.
      return finish_compiled(state, Bytes::new(0), false, name, mode, env)
    }
  }
  // The first byte says which kind this is, and the mode is checked against it
  // before anything else is read -- which is `f_parser`'s order.
  let binary = @chunk.is_binary_chunk(first)
  match mode_refusal(mode, binary) {
    Some(msg) => return [@core.VNil, @core.VStr(@core.LStr::of_string(msg))]
    None => ()
  }
  if binary {
    let buf = Buffer::Buffer(size_hint=first.length() + 64)
    buf.write_bytes(first.view())
    while true {
      match (source.next)() {
        Some(p) => buf.write_bytes(p.view())
        None => break
      }
    }
    match (source.failure)() {
      Some(e) => return [@core.VNil, e]
      None => ()
    }
    return compile_chunk_value(state, buf.to_bytes(), name, env)
  }
  let parsed = Ok(
    @compiler.parse_chunk_fed(feed_from(source, first), chunk_id(name)),
  ) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(_) =>
      Err(
        @core.VStr(
          @core.LStr::of_string(@vm.yield_error(state, state.current_thread)),
        ),
      )
  }
  // A failure the reader itself reported is the failure to hand back, whatever
  // the parser made of the bytes it did get.
  match (source.failure)() {
    Some(e) => [@core.VNil, e]
    None =>
      match parsed {
        Err(e) =>
          [
            @core.VNil,
            @core.VStr(@core.LStr::of_bytes(message_of_error(state, e))),
          ]
        Ok(body) => {
          let compiled = Ok(
            @compiler.compile_chunk(body, @core.LStr::of_string(name)),
          ) catch {
            @core.LuaRaised(e) => Err(e)
            @core.LuaYield(_) =>
              Err(
                @core.VStr(
                  @core.LStr::of_string(
                    @vm.yield_error(state, state.current_thread),
                  ),
                ),
              )
          }
          match compiled {
            Err(e) =>
              [
                @core.VNil,
                @core.VStr(@core.LStr::of_bytes(message_of_error(state, e))),
              ]
            Ok(proto) => [closure_of(state, proto, env)]
          }
        }
      }
  }
}
