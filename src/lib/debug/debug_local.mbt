// debug.getlocal / setlocal.

///|
/// Maps a debug level to the index of the frame it names.  Level 0 is the
/// topmost frame of the thread being asked about: for the running thread that
/// is the debug call's own frame, for a suspended coroutine the `yield` that
/// stopped it.
fn frame_at_level(thread : @core.LThread, level : Int) -> Int? {
  let len = thread.frames.length()
  let idx = len - 1 - level
  if idx >= 0 && idx < len {
    Some(idx)
  } else {
    None
  }
}

///|
/// `luaF_getlocalname`: the name of the n-th (1-based) local variable that
/// is active at `pc`, or `None`.
fn get_local_name(proto : @core.LProto, n : Int, pc : Int) -> String? {
  let mut found = 0
  let mut i = 0
  while i < proto.locvars.length() {
    let v = proto.locvars[i]
    if v.start_pc <= pc && pc < v.end_pc {
      found = found + 1
      if found == n {
        return Some(@core.text_of(v.name.data()))
      }
    }
    i = i + 1
  }
  None
}

///|
/// The parameter names of a Lua function (the `function` form of getlocal):
/// parameters are the first `numparams` locals, active from pc 0.
fn parameter_name(cl : @core.LClosure, n : Int) -> String? {
  if n >= 1 && n <= cl.proto.numparams {
    Some(@core.text_of(cl.proto.locvars[n - 1].name.data()))
  } else {
    None
  }
}

///|
/// The index into a frame's extra arguments that a negative local name refers
/// to, or `None` when the frame is not a vararg one or the index is out of
/// reach, which is what `findvararg` decides.
fn vararg_index(fr : @core.Frame, n : Int) -> Int? {
  if n >= 0 {
    return None
  }
  let i = -n - 1
  match fr.closure {
    Some(cl) =>
      if cl.proto.is_vararg && i < fr.varargs.length() {
        Some(i)
      } else {
        None
      }
    None => None
  }
}

///|
/// The number of slots a frame owns: up to where the frame it called begins,
/// which is `luaG_findlocal`'s limit.
fn frame_room(thread : @core.LThread, fr : @core.Frame, idx : Int) -> Int {
  let next = idx + 1
  let limit = if next < thread.frames.length() {
    thread.frames[next].func_slot
  } else {
    fr.top
  }
  let room = limit - fr.base
  if room < 0 {
    0
  } else {
    room
  }
}

///|
/// Resolves the positive local index `n` of the frame at index `idx`, which
/// addresses register slots.  Returns `(name, absolute slot)`; a slot with no
/// debug name is still readable as "(temporary)" as long as the frame owns it.
/// A host frame has no names, so its arguments are "(C temporary)".  Negative
/// indices name varargs, which the callers reach through `vararg_index`.
fn resolve_local(
  thread : @core.LThread,
  fr : @core.Frame,
  idx : Int,
  n : Int,
) -> (String, Int)? {
  match fr.closure {
    Some(cl) =>
      // The locals in scope at the instruction *being* executed: a local
      // declared by the statement that contains this call is not one of them
      // yet, which is why `local k = debug.getlocal(1, n)` does not report `k`.
      match get_local_name(cl.proto, n, fr.pc - 1) {
        Some(name) => Some((name, fr.base + n - 1))
        None =>
          if n >= 1 && n <= frame_room(thread, fr, idx) {
            Some(("(temporary)", fr.base + n - 1))
          } else {
            None
          }
      }
    None =>
      if n >= 1 && n <= fr.varargs.length() {
        Some(("(C temporary)", fr.base + n - 1))
      } else {
        None
      }
  }
}

///|
pub fn db_getlocal(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let (thread, arg) = get_thread(st, args)
  let f = arg_or_nil(args, arg)
  // The variable index is checked before the function or level, as
  // `db_getlocal` does, so a call with only one argument reports the index.
  let nvar = @core.check_int(st, args, arg + 1, "getlocal").to_int()
  if is_function_arg(f) {
    // Function form: only the parameter names are reported, without values.
    let n = nvar
    match f {
      @core.VFunc(cl) =>
        match parameter_name(cl, n) {
          Some(name) => [@core.VStr(@core.LStr::of_string(name))]
          None => [@core.VNil]
        }
      _ => [@core.VNil]
    }
  } else {
    let level = @core.check_int(st, args, arg, "getlocal").to_int()
    let n = nvar
    match frame_at_level(thread, level) {
      Some(idx) => {
        let fr = thread.frames[idx]
        match vararg_index(fr, n) {
          Some(i) =>
            [@core.VStr(@core.LStr::of_string("(vararg)")), fr.varargs[i]]
          None =>
            match resolve_local(thread, fr, idx, n) {
              Some((name, slot)) =>
                [@core.VStr(@core.LStr::of_string(name)), thread.stack[slot]]
              None => [@core.VNil]
            }
        }
      }
      None => @core.arg_error(st, arg, "getlocal", "level out of range")
    }
  }
}

///|
pub fn db_setlocal(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let (thread, arg) = get_thread(st, args)
  let level = @core.check_int(st, args, arg, "setlocal").to_int()
  let n = @core.check_int(st, args, arg + 1, "setlocal").to_int()
  let value = arg_or_nil(args, arg + 2)
  match frame_at_level(thread, level) {
    Some(idx) => {
      let fr = thread.frames[idx]
      match vararg_index(fr, n) {
        Some(i) => {
          fr.varargs[i] = value
          [@core.VStr(@core.LStr::of_string("(vararg)"))]
        }
        None =>
          match resolve_local(thread, fr, idx, n) {
            Some((name, slot)) => {
              thread.stack[slot] = value
              [@core.VStr(@core.LStr::of_string(name))]
            }
            None => [@core.VNil]
          }
      }
    }
    None => @core.arg_error(st, arg, "setlocal", "level out of range")
  }
}
