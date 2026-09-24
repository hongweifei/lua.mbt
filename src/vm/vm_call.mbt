// Calling from the host, and recovering from errors.

///|
/// Calls a value and waits for its results.  Used by every host function that
/// has to call back into Lua (metamethods, comparators, replacement functions,
/// error handlers).
pub fn call_value(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
  want : Int,
) -> Array[@core.Value] raise @core.LuaRaised {
  let thread = st.current_thread
  let saved_frames = thread.frames.length()
  let func_slot = thread.stack.length()
  thread.stack.push(f)
  for a in args {
    thread.stack.push(a)
  }
  st.native_depth = st.native_depth + 1
  // Re-entering the interpreter costs host stack, and a program that recurses
  // through host callbacks can run the real stack out before a count of levels
  // would stop it: the level count below is the reference's, but what one level
  // costs is this backend's to know.  Both are checked, and the stack is the one
  // that decides on a host whose stack is small.
  let stack_left = @core.host_stack_left()
  if st.native_depth > @core.MAX_NATIVE_DEPTH ||
    (stack_left >= 0 && stack_left < @core.MIN_HOST_STACK) {
    st.native_depth = st.native_depth - 1
    thread.frames.truncate(saved_frames)
    thread.stack.truncate(func_slot)
    @core.vm_error(st, "C stack overflow")
  }
  push_frame(
    st,
    thread,
    func_slot,
    args.length(),
    func_slot,
    want,
    @core.src_none,
    0,
  )
  let nf = thread.frames.length() - 1
  if st.mm_name != "" {
    thread.frames[nf].mm_name = st.mm_name
    st.mm_name = ""
  }
  if (thread.hook_mask & @core.HOOK_CALL) != 0 && !thread.hook_running {
    let saved = st.current_thread
    st.current_thread = thread
    hook_call_event(st, thread, args.length(), false)
    st.current_thread = saved
  }
  let r = Ok(run_protected(st, thread, saved_frames)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  st.native_depth = st.native_depth - 1
  match r {
    Ok(@core.RFinished(vals)) => vals
    Ok(@core.RYield(vals)) => {
      // The call suspended.  The frames stay where they are -- it is the
      // innermost of them that a later resume continues -- so this can be
      // carried only if there is a way back:
      // - `OP_RETURN` or `OP_CLOSE` produce no value, so the instruction is
      //   *run again*, which is what closes the next pending to-be-closed
      //   variable (`luaV_finishOp` rewinds `savedpc` for exactly these two).
      // - A value-producing instruction is *finished* instead: the result is
      //   already on the stack, and the frame takes it when it runs again.
      // - A protected call that is closing its frames after a failure keeps
      //   what is left to close on its marker, so reaching that marker again
      //   carries the closing on -- the reference's `finishpcallk`.
      // A level marked non-yieldable, or one of these with nothing to come
      // back to, refuses: the reference's `luaD_callnoyield` boundaries.
      let caller_idx = saved_frames - 1
      let mut resumable = false
      if thread.ny == 0 && caller_idx >= 0 {
        let caller = thread.frames[caller_idx]
        if caller.pending_closes is Some(_) {
          resumable = true
        } else if (match caller.builtin {
            Some(b) => b.kind == @core.BK_PAIRS
            None => false
          }) {
          // `pairs` has nothing left to do but return what the metamethod
          // produced, so the resume finishes it with those values rather than
          // running it again -- the reference's `pairscont`.
          caller.pending_result = Some(
            (func_slot, if want >= 0 { want } else { 3 }),
          )
          resumable = true
        } else {
          match caller.closure {
            Some(cl) => {
              let at = caller.pc - 1
              if at >= 0 && at < cl.proto.code.length() {
                let op = cl.proto.code[at].op
                if op == @core.OP_RETURN || op == @core.OP_CLOSE {
                  caller.pc = at
                  resumable = true
                } else if can_finish_after_yield(op) {
                  caller.pending_finish = at
                  caller.pending_slot = func_slot
                  resumable = true
                }
              }
            }
            None => ()
          }
        }
      }
      if resumable {
        raise @core.LuaYield(vals)
      }
      thread.frames.truncate(saved_frames)
      thread.stack.truncate(func_slot)
      raise_yield_error(st, thread)
    }
    Err(e) => {
      // The message handler has already run: `run_protected`, which this
      // function calls, reports the error from the point it was raised, where
      // the frames of the failing call still stand.
      //
      // The frames this call created are dropped here, and the reference drops
      // them the same way -- by cutting the chain back and only then running
      // the `__close` handlers that were left pending inside them.  That is
      // what closes a to-be-closed variable declared *inside* a close method.
      let doomed : Array[@core.Frame] = thread.frames[saved_frames:].to_owned()
      thread.frames.truncate(saved_frames)
      // Nothing can resume a handler closed here -- there is no frame that will
      // be reached again to carry on -- so the level is marked non-yieldable,
      // as the reference does by closing with `luaD_callnoyield` from a C
      // function that has no continuation.
      thread.ny = thread.ny + 1
      let final_err = close_detached(st, thread, None, doomed, e)
      thread.ny = thread.ny - 1
      thread.stack.truncate(func_slot)
      raise @core.LuaRaised(final_err)
    }
  }
}

///|
/// Calls a value, discarding the results.
pub fn call_discarding(
  st : @core.LuaState,
  f : @core.Value,
  args : Array[@core.Value],
) -> Unit raise @core.LuaRaised {
  let _ = call_value(st, f, args, 0)
}

///|----------------------------------------------------------------
/// Error recovery

///|----------------------------------------------------------------

///|
/// Runs the message handler of an `xpcall`.  It runs at the point the error was
/// raised, before the stack is unwound, so it still sees the frames of the call
/// it protects.  The protection is already dropped, so an error the handler
/// itself raises goes to the same handler again: the reference implementation
/// recurses that way, each round one call deeper past the C-call limit, until
/// the limit reports "error in error handling".  Recursing forever is not an
/// option here, so the rounds are counted instead.
fn message_handler_result(
  st : @core.LuaState,
  handler : @core.Value,
  err : @core.Value,
) -> @core.Value {
  let mut current = err
  let mut rounds = 0
  while rounds < 64 {
    rounds = rounds + 1
    let next = try {
      let res = call_value(st, handler, [current], 1)
      Ok(if res.length() > 0 { res[0] } else { @core.VNil })
    } catch {
      @core.LuaRaised(e) => Err(e)
      // A message handler runs where nothing can be resumed, as the reference
      // calls it with `luaD_callnoyield`; a yield inside one ends the retries
      // the same way running out of C stack does.
      @core.LuaYield(_) =>
        Err(@core.VStr(@core.LStr::of_string("error in error handling")))
    }
    match next {
      Ok(v) => return v
      Err(e) => current = e
    }
  }
  @core.VStr(@core.LStr::of_string("error in error handling"))
}

///|
/// Runs the message handler of the innermost active `xpcall`, at the point the
/// error was raised.  That is where the reference calls it, from `luaG_errormsg`
/// before the long jump, and it is what lets the handler see the frames of the
/// failing call -- including the `__close` frame of a handler that failed, and
/// the host frame of `error` itself.  A protection with no handler clears the
/// field for as long as it lasts, so an enclosing `xpcall` is not reached
/// through it.
pub fn handle_at_raise_point(
  st : @core.LuaState,
  thread : @core.LThread,
  err : @core.Value,
) -> @core.Value {
  // An error that was already reported and is only being carried further while
  // the stack unwinds passes through here untouched.
  if !thread.fresh_error {
    return err
  }
  thread.fresh_error = false
  let handler = thread.errfunc
  if handler.is_nil() || thread.in_errfunc {
    return err
  }
  thread.in_errfunc = true
  // Room for the handler's own frames.  The reference has already grown the
  // stack to its error size by the time `luaG_errormsg` runs, which is what
  // lets a handler work while the stack that overflowed is still standing.
  let saved_room = st.err_room
  st.err_room = saved_room + 32
  let out = message_handler_result(st, handler, err)
  st.err_room = saved_room
  thread.in_errfunc = false
  out
}

///|
/// Handles an error by completing the innermost protected frame at or above
/// `floor`.  Frames below `floor` belong to enclosing host calls that will run
/// their own recovery, so they must not be touched here.  Returns false when
/// the error has to keep travelling.
pub fn recover(
  st : @core.LuaState,
  thread : @core.LThread,
  err : @core.Value,
  floor : Int,
) -> (Bool, @core.RunStatus?) raise @core.LuaRaised {
  let mut i = thread.frames.length() - 1
  while i >= floor {
    // An error raised while the frames of a failed protected call are being
    // closed is the error the closing carries on with, not a new one to
    // recover: the reference catches it in `luaD_closeprotected` and closes
    // what is left with it.  The frames the handler itself created are closed
    // first, since they stand above the marker.
    let pending = thread.frames[i].pending_closes
    match pending {
      Some(doomed) => {
        let mut above = i + 1
        while above < thread.frames.length() {
          doomed.push(thread.frames[above])
          above = above + 1
        }
        thread.frames.truncate(i + 1)
        thread.frames[i].pending_err = err
        let final_err = close_detached(
          st,
          thread,
          Some(thread.frames[i]),
          doomed,
          err,
        )
        thread.frames[i].pending_closes = None
        st.err_room = thread.frames[i].pending_room
        let fin = complete_frame(
          st,
          thread,
          i,
          floor,
          Listed([final_err]),
          false,
        )
        return (
          true,
          match fin {
            Some(vals) => Some(@core.RFinished(vals))
            None => None
          },
        )
      }
      None => ()
    }
    let prots = thread.frames[i].prots
    if prots.length() > 0 {
      // The protection is dropped before anything runs, so an error raised by
      // a `__close` method is not caught by the same one.  Its message handler
      // has already run, at the raise point; `thread.errfunc` still names it,
      // because the reference restores the field only after closing.
      let n = prots.length()
      let mut k = 1
      while k < n {
        prots[k - 1] = prots[k]
        k = k + 1
      }
      prots.truncate(n - 1)
      // The level is given back only now: while the handler runs, the call it
      // protects still stands, and that is what lets a failing handler recurse
      // past the C-call limit.
      thread.ccalls = thread.ccalls - 1
      // The frames the protected call created leave the chain *before* its
      // `__close` handlers run, so a handler sees the marker of the protected
      // call as the frame that called it, as `luaD_pcall` arranges.  The marker
      // itself stays, and is finished last: it is where the `(false, err)`
      // result of the protected call belongs.
      let doomed : Array[@core.Frame] = thread.frames[i + 1:].to_owned()
      thread.frames.truncate(i + 1)
      // The marker keeps what is left to close, so a handler that yields leaves
      // the rest of it for the pass that reaches the marker again.
      thread.frames[i].pending_closes = Some(doomed)
      thread.frames[i].pending_err = err
      // Room for the handlers' own frames: the stack may have overflowed.  The
      // closing can be suspended in the middle of it, so where to put it back
      // is kept on the marker as well.
      thread.frames[i].pending_room = st.err_room
      st.err_room = st.err_room + 32
      let final_err = close_detached(
        st,
        thread,
        Some(thread.frames[i]),
        doomed,
        err,
      )
      thread.frames[i].pending_closes = None
      st.err_room = thread.frames[i].pending_room
      let fin = complete_frame(st, thread, i, floor, Listed([final_err]), false)
      return (
        true,
        match fin {
          Some(vals) => Some(@core.RFinished(vals))
          None => None
        },
      )
    }
    i = i - 1
  }
  (false, None)
}

///|
/// The message for a yield that is not allowed here: a coroutine is blocked by
/// a host call in between, while the main thread has no coroutine to yield from
/// at all.  The reference raises it from the C function itself, so it carries
/// no position.
pub fn yield_error(st : @core.LuaState, thread : @core.LThread) -> String {
  if thread.id == st.main_thread.id {
    "attempt to yield from outside a coroutine"
  } else {
    "attempt to yield across a C-call boundary"
  }
}

///|
/// Raises the refusal of a yield, without the position prefix a runtime error
/// would get.
pub fn[T] raise_yield_error(
  st : @core.LuaState,
  thread : @core.LThread,
) -> T raise @core.LuaRaised {
  @core.raise_fresh(
    st,
    @core.VStr(@core.LStr::of_string(yield_error(st, thread))),
  )
}

///|
/// Runs the interpreter, converting errors into the completion of a protected
/// frame when one is present.
pub fn run_protected(
  st : @core.LuaState,
  thread : @core.LThread,
  floor : Int,
) -> @core.RunStatus raise @core.LuaRaised {
  while true {
    let r = Ok(execute(st, thread, floor)) catch {
      @core.LuaRaised(e) => Err(e)
      // A yield that came out of a host callback, raised by `call_value` from
      // the frame whose instruction started that call.  It is not an error:
      // the frames are where they were, and the thread stops here.
      @core.LuaYield(v) => return @core.RYield(v)
    }
    match r {
      Ok(status) => return status
      Err(e) => {
        let reported = handle_at_raise_point(st, thread, e)
        let (handled, done) = recover(st, thread, reported, floor)
        if !handled {
          raise @core.LuaRaised(reported)
        }
        match done {
          Some(s) => return s
          None => ()
        }
      }
    }
  } nobreak {
    @core.RFinished([])
  }
}

///|----------------------------------------------------------------
/// The interpreter loop

///|----------------------------------------------------------------
