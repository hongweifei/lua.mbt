// Loading chunks and modules.

///|
/// Loads a chunk from a string or from a function that returns its pieces.
pub fn base_load(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
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
  let source = if is_reader {
    match read_chunk(state, chunk) {
      Ok(text) => text
      Err(msg) => return [@core.VNil, msg]
    }
  } else {
    chunk_to_source(state, chunk, args.length() >= 1)
  }
  // `checkmode` looks at what the chunk actually is before deciding whether
  // the requested mode refuses it.
  let kind = if @chunk.is_binary_chunk(source) { "binary" } else { "text" }
  if !mode.contains(if kind == "binary" { "b" } else { "t" }) {
    return [
      @core.VNil,
      @core.VStr(
        @core.LStr::of_string(
          "attempt to load a " + kind + " chunk (mode is '" + mode + "')",
        ),
      ),
    ]
  }
  match compile_source(state, source, name, env) {
    @core.LoadOk(f) => [f]
    @core.LoadError(msg) => [@core.VNil, @core.VStr(@core.LStr::of_bytes(msg))]
  }
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
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
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
    read_stdin_all()
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
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let r = base_loadfile(state, [], args)
  match r[0] {
    @core.VNil => @core.raise_fresh(state, r[1])
    f => @vm.call_value(state, f, [], -1)
  }
}

///|
/// Reads standard input to the end.
pub fn read_stdin_all() -> Bytes {
  let buf = Buffer::Buffer(size_hint=4096)
  let inp = @host.lua_mbt_stdin()
  if inp == 0L {
    return Bytes::new(0)
  }
  let chunk = Bytes::new(65536)
  while true {
    let n = @host.lua_mbt_fread(inp, chunk, 65536)
    if n <= 0 {
      break
    }
    buf.write_bytes(chunk.view(end=n))
  }
  buf.to_bytes()
}

///|
/// `require`, implemented over the searchers in `package.searchers`.  Each
/// searcher receives the module name and returns either a loader function, which
/// `require` then calls, or a string describing why it could not find the module.
pub fn base_require(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "require")
  let loaded = package_table(state, "loaded")
  // "Already loaded" is about *truth*, not about presence: a module whose
  // loader returned `false` (or that set `package.loaded[name] = false`) is
  // loaded again on the next `require` (`lua_toboolean` in `ll_require`).
  match loaded.get(@core.VStr(name)) {
    @core.VNil | @core.VBool(false) => ()
    v => return [v]
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
        return [result, extra]
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
/// Collects the text of a chunk from a reader function.  A reader that raises,
/// or that returns something which is not a string, does not propagate the
/// error: `load` hands back `nil` with the message instead, like `load_aux`.
/// What a reader raises is that message, so it must not be taken for a piece of
/// the chunk -- a reader that always fails would then loop forever.
fn read_chunk(
  state : @core.LuaState,
  chunk : @core.Value,
) -> Result[Bytes, @core.Value] {
  let buf = Buffer::Buffer()
  while true {
    let next = Ok(@vm.call_value(state, chunk, [], 1)) catch {
      @core.LuaRaised(e) => Err(reported_error(state, e))
      @core.LuaYield(_) =>
        Err(
          @core.VStr(
            @core.LStr::of_string(@vm.yield_error(state, state.current_thread)),
          ),
        )
    }
    let piece = match next {
      Err(e) => return Err(e)
      Ok(values) => if values.length() > 0 { values[0] } else { @core.VNil }
    }
    match piece {
      @core.VStr(s) =>
        if s.length() > 0 {
          buf.write_bytes(s.data().view())
        } else {
          return Ok(buf.to_bytes())
        }
      @core.VNil => return Ok(buf.to_bytes())
      _ =>
        return Err(
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
    }
  } nobreak {
    Err(@core.VNil)
  }
}
