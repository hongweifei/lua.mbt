// The coroutine library.

///|
pub fn resume_thread(
  state : @core.LuaState,
  co : @core.LThread,
  args : Array[@core.Value],
) -> (Bool, Array[@core.Value]) {
  // The reference counts a resume as a level of C calls, so coroutine nesting
  // without bound reports an overflow instead of exhausting the host stack.
  if state.native_depth >= @core.MAX_NATIVE_DEPTH {
    return (false, [@core.VStr(@core.LStr::of_string("C stack overflow"))])
  }
  if co.started {
    if co.status == @core.THREAD_DEAD {
      return (
        false,
        [@core.VStr(@core.LStr::of_string("cannot resume dead coroutine"))],
      )
    }
    if co.status == @core.THREAD_RUNNING || co.status == @core.THREAD_NORMAL {
      return (
        false,
        [
          @core.VStr(
            @core.LStr::of_string("cannot resume non-suspended coroutine"),
          ),
        ],
      )
    }
  }
  let prev = state.current_thread
  if !co.started {
    match co.func {
      @core.VFunc(_) | @core.VBuiltin(_) => ()
      v => {
        let name = @core.type_error_name(state, v)
        return (
          false,
          [
            @core.VStr(
              @core.LStr::of_string("cannot resume a coroutine with a " + name),
            ),
          ],
        )
      }
    }
    co.started = true
    let func_slot = co.stack.length()
    co.stack.push(co.func)
    for a in args {
      co.stack.push(a)
    }
    let r = try {
      @vm.push_frame(
        state,
        co,
        func_slot,
        args.length(),
        0,
        -1,
        @core.src_none,
        0,
      )
      // The body is called like any other function, so its call event fires
      // before its first instruction runs.
      if (co.hook_mask & @core.HOOK_CALL) != 0 && !co.hook_running {
        @vm.hook_call_event(state, co, args.length(), false)
      }
      Ok(())
    } catch {
      @core.LuaRaised(e) => Err(e)
      @core.LuaYield(_) =>
        Err(@core.VStr(@core.LStr::of_string(@vm.yield_error(state, co))))
    }
    match r {
      Ok(_) => ()
      Err(e) => {
        co.status = @core.THREAD_DEAD
        co.dead_error = e
        return (false, [e])
      }
    }
  } else {
    // Continuing after a yield: the values become the results of the
    // `coroutine.yield` frame the thread stopped in, which the interpreter
    // finishes when it re-enters that frame.
    co.resume_vals = Some(args)
    // That call is now finished, which reports its return event.
    let hr = try {
      if (co.hook_mask & @core.HOOK_RETURN) != 0 && !co.hook_running {
        @vm.hook_return_event(state, co, 1, args.length())
      }
      Ok(())
    } catch {
      @core.LuaRaised(e) => Err(e)
      @core.LuaYield(_) =>
        Err(@core.VStr(@core.LStr::of_string(@vm.yield_error(state, co))))
    }
    match hr {
      Ok(_) => ()
      Err(e) => {
        co.status = @core.THREAD_DEAD
        co.dead_error = e
        return (false, [e])
      }
    }
  }
  state.current_thread = co
  co.status = @core.THREAD_RUNNING
  prev.status = @core.THREAD_NORMAL
  state.native_depth = state.native_depth + 1
  let r = Ok(@vm.run_protected(state, co, 0)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => Ok(@core.RYield(v))
  }
  state.native_depth = state.native_depth - 1
  state.current_thread = prev
  prev.status = @core.THREAD_RUNNING
  match r {
    Ok(@core.RFinished(vals)) => {
      co.status = @core.THREAD_DEAD
      (true, vals)
    }
    Ok(@core.RYield(vals)) => {
      co.status = @core.THREAD_SUSPENDED
      (true, vals)
    }
    Err(e) => {
      // A coroutine that dies from an error keeps the frames it had when the
      // error surfaced: `debug.getinfo` and `debug.traceback` can still look at
      // them, and the `__close` handlers they hold run when the coroutine is
      // closed.
      co.status = @core.THREAD_DEAD
      co.dead_error = e
      (false, [e])
    }
  }
}

///|
/// Runs the pending `__close` handlers of a thread and releases everything it
/// holds.
pub fn close_thread(
  st : @core.LuaState,
  co : @core.LThread,
  err : @core.Value,
) -> Unit raise @core.LuaRaised {
  // The handlers run in the closing coroutine's context, so that a nested
  // `coroutine.close` of the same thread sees it as running.
  let prev = st.current_thread
  let prev_status = co.status
  st.current_thread = co
  co.status = @core.THREAD_RUNNING
  // The unwinding that left the thread where it stopped also threw its message
  // handler away, as `luaE_resetthread` says when it zeroes the field: an
  // `xpcall` the coroutine was suspended inside does not handle the errors its
  // closing raises.
  co.errfunc = @core.VNil
  co.in_errfunc = false
  let r : Result[Unit, @core.Value] = {
    let mut i = co.frames.length()
    let mut cur = err
    let mut errored = false
    while i > 0 {
      i = i - 1
      // A handler that fails leaves the rest of its frame's to-be-closed
      // variables pending, and they are closed in the next pass with the
      // reported error, the way `luaD_closeprotected` keeps going.
      while co.frames[i].tbc.length() > 0 {
        let step = try {
          @vm.close_frame(st, co, i, cur, "")
          Ok(())
        } catch {
          @core.LuaRaised(e) => Err(e)
          @core.LuaYield(v) => raise @core.LuaYield(v)
        }
        match step {
          Ok(_) => ()
          Err(e) => {
            cur = e
            errored = true
          }
        }
      }
    }
    if errored {
      Err(cur)
    } else {
      Ok(())
    }
  }
  st.current_thread = prev
  co.status = prev_status
  co.frames.truncate(0)
  co.stack.truncate(0)
  co.open_upvals.truncate(0)
  match r {
    Ok(_) => ()
    Err(e) => raise @core.LuaRaised(e)
  }
}

///|
pub fn co_create(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = @core.check_function(state, args, 1, "create")
  let co = @core.LThread::new()
  co.func = f
  co.status = @core.THREAD_SUSPENDED
  [@core.VThread(co)]
}

///|
pub fn co_resume(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let co = @core.check_thread(state, args, 1, "resume")
  let rest : Array[@core.Value] = []
  let mut i = 1
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  let (ok, vals) = resume_thread(state, co, rest)
  let out : Array[@core.Value] = [@core.VBool(ok)]
  for x in vals {
    out.push(x)
  }
  out
}

///|
pub fn co_status(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let co = @core.check_thread(state, args, 1, "status")
  if co.id == state.current_thread.id {
    return [@core.VStr(@core.LStr::of_string("running"))]
  }
  let s = match co.status {
    @core.THREAD_RUNNING | @core.THREAD_NORMAL => "normal"
    @core.THREAD_SUSPENDED => "suspended"
    @core.THREAD_DEAD => "dead"
    _ => "suspended"
  }
  [@core.VStr(@core.LStr::of_string(s))]
}

///|
pub fn co_running(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let _ = args
  let th = state.current_thread
  let is_main = th.id == state.main_thread.id
  [@core.VThread(th), @core.VBool(is_main)]
}

///|
pub fn co_isyieldable(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // No argument asks about the running thread; an explicit one has to be a
  // thread (`lua_isnone`, not `lua_isnoneornil`).
  let th = if args.length() < 1 {
    state.current_thread
  } else {
    @core.check_thread(state, args, 1, "isyieldable")
  }
  // As in `yieldable(L)`: the thread can yield exactly when no host-level
  // call (a C-call boundary: `pcall`, `gsub`'s callback, ...) is active.
  [@core.VBool(th.ny == 0)]
}

///|
pub fn co_yield(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // The interpreter handles `yield` before entering a native frame, so reaching
  // * this body means the call came through a host level call such as a
  // * metamethod, where yielding is not allowed.  On the main thread there is
  // * no coroutine to yield from at all.
  let _ = upvals
  let _ = args
  @core.runtime_error(state, @vm.yield_error(state, state.current_thread))
}

///|
pub fn co_close(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let co = @core.check_thread(state, args, 1, "close")
  if co.id == state.current_thread.id {
    @core.runtime_error(state, "cannot close a running coroutine")
  }
  if co.status == @core.THREAD_NORMAL {
    @core.runtime_error(state, "cannot close a normal coroutine")
  }
  if co.status == @core.THREAD_RUNNING {
    @core.runtime_error(state, "cannot close a running coroutine")
  }
  if !co.started {
    return [@core.VBool(true)]
  }
  if co.status == @core.THREAD_DEAD {
    // A dead coroutine still holding its error yields it to the first
    // `close`, exactly like `lua_closethread` does; later closes succeed.
    if co.dead_error.is_nil() {
      return [@core.VBool(true)]
    }
    let e = co.dead_error
    co.dead_error = @core.VNil
    // The error left the dead coroutine's frames in place, so closing it now
    // runs the `__close` handlers they still own.  Each handler receives the
    // error before it, and the last one standing is what `close` reports.
    let reported = match
      (try {
        close_thread(state, co, e)
        Ok(e)
      } catch {
        @core.LuaRaised(other) => Err(other)
        // `coroutine.close` runs no Lua of its own, so nothing here can yield;
        // a handler that tries is reported as any other error of the close.
        @core.LuaYield(_) =>
          Err(@core.VStr(@core.LStr::of_string(@vm.yield_error(state, co))))
      }) {
      Ok(kept) => kept
      Err(other) => other
    }
    return [@core.VBool(false), reported]
  }
  let r = try {
    close_thread(state, co, @core.VNil)
    Ok(())
  } catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  co.status = @core.THREAD_DEAD
  match r {
    Ok(_) => [@core.VBool(true)]
    Err(e) => [@core.VBool(false), e]
  }
}

///|
/// The function `coroutine.wrap` returns: resume, propagating failures as
/// errors.
pub fn wrap_body(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let co = match upvals[0] {
    @core.VThread(t) => t
    _ => @core.runtime_error(state, "invalid coroutine")
  }
  let (ok, vals) = resume_thread(state, co, args)
  if !ok {
    let e = if vals.length() > 0 { vals[0] } else { @core.VNil }
    // Only a coroutine that died from an error still owns to-be-closed
    // variables, and the function `wrap` returns closes those, as
    // `luaB_auxwrap` does with `lua_closethread`.  A coroutine that could not
    // be resumed at all is untouched -- it may be the one running now -- which
    // is what the reference's test of `lua_status(co)` decides.
    if co.status != @core.THREAD_DEAD {
      @core.raise_fresh(state, e)
    }
    // A handler that fails replaces the error that is reported.
    let close_error = try {
      close_thread(state, co, e)
      None
    } catch {
      @core.LuaRaised(other) => Some(other)
      @core.LuaYield(_) =>
        Some(@core.VStr(@core.LStr::of_string(@vm.yield_error(state, co))))
    }
    match close_error {
      // An error raised while closing is reported as it is, which is what the
      // reference's early `return lua_error(L)` does.
      Some(other) => @core.raise_fresh(state, other)
      None =>
        // A string error gets the position of the call that resumed the
        // coroutine in front of it, which is `auxwrap`'s `luaL_where(L, 1)`:
        // the coroutine's own message already names where it failed, so the
        // extra position is what tells the two apart.
        @core.raise_fresh(state, @core.with_position(state, e, 1))
    }
  }
  vals
}

///|
pub fn co_wrap(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = @core.check_function(state, args, 1, "wrap")
  let co = @core.LThread::new()
  co.func = f
  co.status = @core.THREAD_SUSPENDED
  [
    @core.VBuiltin(
      @core.make_builtin("wrap", @core.BK_NORMAL, -1, wrap_body, [
        @core.VThread(co),
      ]),
    ),
  ]
}

///|
pub fn open_coroutine_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("close", @core.VBuiltin(@core.LBuiltin::make("close", 1, co_close)))
  t.set_str(
    "create",
    @core.VBuiltin(@core.LBuiltin::make("create", 1, co_create)),
  )
  t.set_str(
    "isyieldable",
    @core.VBuiltin(@core.LBuiltin::make("isyieldable", 0, co_isyieldable)),
  )
  t.set_str(
    "resume",
    @core.VBuiltin(@core.LBuiltin::make("resume", -1, co_resume)),
  )
  t.set_str(
    "running",
    @core.VBuiltin(@core.LBuiltin::make("running", 0, co_running)),
  )
  t.set_str(
    "status",
    @core.VBuiltin(@core.LBuiltin::make("status", 1, co_status)),
  )
  t.set_str("wrap", @core.VBuiltin(@core.LBuiltin::make("wrap", 1, co_wrap)))
  t.set_str(
    "yield",
    @core.VBuiltin(
      @core.LBuiltin::make_kind("yield", @core.BK_YIELD, -1, co_yield),
    ),
  )
  state.globals.set_str("coroutine", @core.VTable(t))
}
