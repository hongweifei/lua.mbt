// Error creation, protected calls and the collector interface.

///|
/// Raises an error.  A string message is prefixed with the position of the
/// frame `level` steps up the stack.
pub fn base_error(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // `error()` with no argument raises nil; only a string message is prefixed
  // with the caller's position.
  if args.length() == 0 {
    @core.raise_fresh(state, @core.VNil)
  }
  let v = args[0]
  let level = @core.opt_int(state, args, 2, "error", 1L)
  @core.raise_fresh(state, @core.with_position(state, v, level.to_int()))
}

///|
pub fn base_assert(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 {
    @core.arg_error(state, 1, "assert", "value expected")
  }
  if args[0].is_truthy() {
    return args
  }
  if args.length() >= 2 {
    // `assert` hands its message to `error`, whose default level is 1 because
    // the condition has already been dropped: a string message gets the
    // caller's position, anything else is passed on as it is.
    @core.raise_fresh(state, @core.with_position(state, args[1], 1))
  }
  @core.runtime_error(state, "assertion failed!")
}

///|
/// The body of `pcall`.  The interpreter loop normally handles `pcall` without
/// entering this function, because the protection has to survive a yield; this
/// body is what runs when `pcall` is invoked through a metamethod or any other
/// host level call.
pub fn base_pcall(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() < 1 {
    @core.arg_error(state, 1, "pcall", "value expected")
  }
  let rest : Array[@core.Value] = []
  let mut i = 1
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  let r = Ok(@vm.call_value(state, args[0], rest, -1)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  match r {
    Ok(vals) => {
      let out : Array[@core.Value] = [@core.VBool(true)]
      for v in vals {
        out.push(v)
      }
      out
    }
    Err(e) => [@core.VBool(false), e]
  }
}

///|
/// The body of `xpcall`.
pub fn base_xpcall(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // The handler is checked before anything runs (`luaL_checktype(L, 2,
  // LUA_TFUNCTION)` in `luaB_xpcall`), so a missing or wrong one is reported
  // even when the protected function would have failed first.
  let handler = @core.check_function(state, args, 2, "xpcall")
  let rest : Array[@core.Value] = []
  let mut i = 2
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  let r = Ok(@vm.call_value(state, args[0], rest, -1)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  match r {
    Ok(vals) => {
      let out : Array[@core.Value] = [@core.VBool(true)]
      for v in vals {
        out.push(v)
      }
      out
    }
    Err(e) => {
      let hv = @vm.call_value(state, handler, [e], 1)
      [@core.VBool(false), if hv.length() > 0 { hv[0] } else { @core.VNil }]
    }
  }
}

///|
/// Reports on, and influences, the collector.  Because the host runtime owns
/// memory management this describes the interpreter's own allocation counter and
/// its configuration; cyclic garbage is reclaimed when the process exits.
pub fn base_collectgarbage(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // Inside a `__gc` handler no option does anything: the answer is nil, which
  // is what `luaL_pushfail` gives for a call the collector cannot serve.
  if state.gc_finalizing {
    return [@core.VNil]
  }
  let opt = @core.check_option(
    state,
    args,
    1,
    "collectgarbage",
    [
      "collect", "stop", "restart", "count", "step", "isrunning", "incremental",
      "generational", "setpause", "setstepmul",
    ],
    "collect",
  )
  match opt {
    "collect" => {
      @vm.collect_and_retune(state)
      [@core.VInt(0L)]
    }
    "stop" => {
      state.gc_running = false
      [@core.VInt(0L)]
    }
    "restart" => {
      state.gc_running = true
      [@core.VInt(0L)]
    }
    "count" => [@core.VNum(@core.live_size(state).to_double() / 1024.0)]
    // A step is charged `size` kilobytes of work, and a cycle is finished
    // once that much has been asked for -- the reference's debt.  A step with
    // no size does a basic step, which always finishes one here, because a
    // collection is atomic.
    "step" => {
      let size = @core.opt_int(state, args, 2, "collectgarbage", 0L).to_int()
      // A step is charged `size` kilobytes of work, and a cycle is finished once
      // one cycle's worth has been asked for.  The size comes from the program,
      // so the charge is capped rather than allowed to overflow: a wrapped one
      // would be negative and the cycle would never finish.
      //
      // `setstepmul` scales the charge, which is what it does in the reference
      // (`incstep` multiplies the debt by it): a larger multiplier finishes a
      // cycle in fewer calls, a smaller one in more.  The cap stays last, so a
      // multiplier cannot ask for more than one cycle -- `dosteps(20000)` still
      // finishes in a single call -- and the default (100) leaves the arithmetic
      // exactly as it was.
      let mul = if state.gc_stepmul < 0 { 0 } else { state.gc_stepmul }
      let mut kb = size.to_int64() * 1024L * mul.to_int64() / 100L
      if kb > @core.GC_STEP.to_int64() {
        kb = @core.GC_STEP.to_int64()
      }
      state.gc_debt = state.gc_debt + kb.to_int()
      if size <= 0 || state.gc_debt >= @core.GC_STEP {
        @vm.collect_and_retune(state)
        [@core.VBool(true)]
      } else {
        [@core.VBool(false)]
      }
    }
    "isrunning" => [@core.VBool(state.gc_running)]
    "incremental" => {
      let prev = state.gc_mode
      state.gc_mode = "incremental"
      [@core.VStr(@core.LStr::of_string(prev))]
    }
    "generational" => {
      let prev = state.gc_mode
      state.gc_mode = "generational"
      [@core.VStr(@core.LStr::of_string(prev))]
    }
    "setpause" => {
      let old = state.gc_pause
      state.gc_pause = @core.opt_int(state, args, 2, "collectgarbage", 200L).to_int()
      [@core.VInt(old.to_int64())]
    }
    "setstepmul" => {
      let old = state.gc_stepmul
      // The reference keeps its gc parameters divided by `GCPARAM_ADJ` and hands
      // them back multiplied, so what a program sets comes back rounded down to a
      // multiple of four -- `setstepmul(50)` reports 48 next time.
      let asked = @core.opt_int(state, args, 2, "collectgarbage", 100L).to_int()
      state.gc_stepmul = asked / @core.GCPARAM_ADJ * @core.GCPARAM_ADJ
      [@core.VInt(old.to_int64())]
    }
    _ => [@core.VInt(0L)]
  }
}

///|
/// Emits a warning, honouring the `@on`/`@off` control messages.
pub fn base_warn(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // At least one argument is required, and every argument must be a string:
  // `luaL_checkstring(L, 1)` runs before the loop, so `warn()` is an argument
  // error rather than a warning about nothing.
  let _ = @core.check_str(state, args, 1, "warn")
  let mut i = 1
  let parts : Array[Bytes] = []
  while i <= args.length() {
    parts.push(@core.check_str(state, args, i, "warn").data())
    i = i + 1
  }
  let msg = @core.bytes_concat(parts)
  if msg.length() > 0 && @core.ubyte_at(msg, 0) == 64 {
    let cmd = @core.bytes_slice(msg, 1, msg.length() - 1)
    if cmd == @core.bytes_of("on") {
      state.warn_enabled = true
    } else if cmd == @core.bytes_of("off") {
      state.warn_enabled = false
    }
    return []
  }
  if state.warn_enabled {
    @core.write_stderr(
      @core.bytes_concat([
        @core.bytes_of("Lua warning: "),
        msg,
        @core.bytes_of("\n"),
      ]),
    )
  }
  []
}
