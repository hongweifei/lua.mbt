// Debug hook triggering: the VM side of `debug.sethook`.

///|
/// Calls the hook function with the event name and, for line events, the
/// current line.  The hook never triggers itself: while it runs
/// `hook_running` is set and every other trigger point bails out.
pub fn call_hook(
  st : @core.LuaState,
  thread : @core.LThread,
  event : String,
  line : Int,
  ftransfer : Int,
  ntransfer : Int,
) -> Unit raise @core.LuaRaised {
  if thread.hook_running {
    return
  }
  let f = thread.hook_fn
  if f is @core.VNil {
    return
  }
  thread.hook_running = true
  // The transfer information belongs to the frame the event is about, which is
  // the innermost one here: the returning frame for a return event and the new
  // frame for a call event.  The reference records it only when there is
  // something to record (`ntransfer != 0`) and clears it once the hook returns,
  // because the flag that marks it is part of the hook's own call status
  // (`luaD_hook`'s `CIST_TRAN`).
  let hooked : @core.Frame? = if ntransfer != 0 && thread.frames.length() > 0 {
    let fr = thread.frames[thread.frames.length() - 1]
    fr.ftransfer = ftransfer
    fr.ntransfer = ntransfer
    Some(fr)
  } else {
    None
  }
  let args : Array[@core.Value] = [@core.VStr(@core.LStr::of_string(event))]
  if event == "line" {
    // A chunk without line information reports no line, and the hook is told
    // so with `nil` -- the reference pushes nil for a negative line.
    if line >= 0 {
      args.push(@core.VInt(line.to_int64()))
    } else {
      args.push(@core.VNil)
    }
  }
  let saved_current = st.current_thread
  st.current_thread = thread
  try {
    let _ = run_call_hook_fn(st, thread, f, args)
  } catch {
    @core.LuaRaised(e) => {
      clear_transfer(hooked)
      thread.hook_running = false
      st.current_thread = saved_current
      raise @core.LuaRaised(e)
    }
    @core.LuaYield(v) => {
      clear_transfer(hooked)
      thread.hook_running = false
      st.current_thread = saved_current
      raise @core.LuaYield(v)
    }
  }
  clear_transfer(hooked)
  thread.hook_running = false
  st.current_thread = saved_current
}

///|
/// Takes the transfer information back off a frame once the hook that put it
/// there has returned.
fn clear_transfer(fr : @core.Frame?) -> Unit {
  match fr {
    Some(f) => {
      f.ftransfer = 0
      f.ntransfer = 0
    }
    None => ()
  }
}

///|
/// Calls the hook through a marked frame, so that `debug.getinfo` inside the
/// hook reports `namewhat == "hook"`.
fn run_call_hook_fn(
  st : @core.LuaState,
  thread : @core.LThread,
  f : @core.Value,
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let saved_frames = thread.frames.length()
  let func_slot = thread.stack.length()
  thread.stack.push(f)
  for a in args {
    thread.stack.push(a)
  }
  st.native_depth = st.native_depth + 1
  if st.native_depth > @core.MAX_NATIVE_DEPTH {
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
    0,
    @core.src_none,
    0,
  )
  let nf = thread.frames.length() - 1
  thread.frames[nf].hook_frame = true
  let r = Ok(run_protected(st, thread, saved_frames)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  st.native_depth = st.native_depth - 1
  match r {
    Ok(@core.RFinished(vals)) => vals
    Ok(@core.RYield(_)) => {
      thread.frames.truncate(saved_frames)
      thread.stack.truncate(func_slot)
      raise_yield_error(st, thread)
    }
    Err(e) => {
      thread.frames.truncate(saved_frames)
      thread.stack.truncate(func_slot)
      raise @core.LuaRaised(e)
    }
  }
}

///|
/// `settraps`: a hook installed while Lua is running has to be seen by the
/// frames that are already on the stack, not only by the ones pushed later.
pub fn set_traps(thread : @core.LThread) -> Unit {
  let on = (thread.hook_mask & (@core.HOOK_LINE | @core.HOOK_COUNT)) != 0
  let mut i = 0
  while i < thread.frames.length() {
    let fr = thread.frames[i]
    match fr.closure {
      Some(_) => fr.trap = on
      None => ()
    }
    i = i + 1
  }
}

///|
/// Runs the line and count events for the instruction at `pc` of the current
/// frame.  Called once per instruction from the interpreter loop.
pub fn hook_tick(
  st : @core.LuaState,
  thread : @core.LThread,
  fr : @core.Frame,
  pc : Int,
) -> Unit raise @core.LuaRaised {
  if thread.hook_running || !fr.trap {
    return
  }
  let mask = thread.hook_mask
  if (mask & (@core.HOOK_LINE | @core.HOOK_COUNT)) == 0 {
    // Nothing this frame is asked to report; the reference clears 'trap'.
    fr.trap = false
    return
  }
  // The reference reaches a hook with the saved pc of the frame already past
  // the instruction being traced, which is what lets `debug.getinfo` inside the
  // hook name the line that is about to run.  The marker is put back after the
  // hook, because the interpreter keeps running that instruction.
  fr.pc = pc + 1
  let done = Ok(hook_events(st, thread, fr, pc, mask)) catch {
    @core.LuaRaised(e) => Err(e)
    @core.LuaYield(v) => raise @core.LuaYield(v)
  }
  fr.pc = pc
  match done {
    Err(e) => raise @core.LuaRaised(e)
    Ok(_) => ()
  }
}

///|
/// The count and line events for one instruction.
fn hook_events(
  st : @core.LuaState,
  thread : @core.LThread,
  fr : @core.Frame,
  pc : Int,
  mask : Int,
) -> Unit raise @core.LuaRaised {
  // Count event: fires every `hook_base_count` instructions, but only while
  // the count mask is on, as in the reference implementation.
  if (mask & @core.HOOK_COUNT) != 0 && thread.hook_base_count > 0 {
    thread.hook_count = thread.hook_count - 1
    if thread.hook_count <= 0 {
      thread.hook_count = thread.hook_base_count
      call_hook(st, thread, "count", -1, 0, 0)
      return
    }
  }
  if (mask & @core.HOOK_LINE) != 0 {
    match fr.closure {
      Some(cl) => {
        let newline = @core.line_at(cl.proto, pc)
        // The old pc refers to the previous instruction when it belongs to
        // the same function; an out-of-range value means a fresh frame (the
        // reference resets oldpc to 0 on every call).
        let oldpc = if thread.hook_old_pc < cl.proto.code.length() {
          thread.hook_old_pc
        } else {
          0
        }
        let oldline = @core.line_at(cl.proto, oldpc)
        // Fire on a jump back into an executed line (loops) or on a new line.
        if pc <= oldpc || newline != oldline {
          call_hook(st, thread, "line", newline, 0, 0)
        }
        thread.hook_old_pc = pc
      }
      None => ()
    }
  } else {
    thread.hook_old_pc = pc
  }
}

///|
/// Fires the call or tail-call event for a freshly pushed frame.  The transfer
/// information names the arguments the hook can reach: a Lua function exposes
/// its parameters, and a host function every value it was called with.
pub fn hook_call_event(
  st : @core.LuaState,
  thread : @core.LThread,
  nargs : Int,
  tail : Bool,
) -> Unit raise @core.LuaRaised {
  let event = if tail { "tail call" } else { "call" }
  let ntransfer = match thread.frames[thread.frames.length() - 1].closure {
    Some(cl) => cl.proto.numparams
    None => nargs
  }
  call_hook(st, thread, event, -1, 1, ntransfer)
}

///|
/// Fires the return event for a frame returning `nres` values starting at
/// relative slot `a` (1-based, as in the RETURN instruction).
pub fn hook_return_event(
  st : @core.LuaState,
  thread : @core.LThread,
  a : Int,
  nres : Int,
) -> Unit raise @core.LuaRaised {
  call_hook(st, thread, "return", -1, a, nres)
}
