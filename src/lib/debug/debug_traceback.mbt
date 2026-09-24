// debug.traceback.

///|
/// The level bounds of the abbreviated traceback format, as in the
/// reference implementation.
pub const LEVELS1 : Int = 10

///|
pub const LEVELS2 : Int = 11

///|
/// Builds the "in <description>" part of a traceback line.
fn frame_where(
  st : @core.LuaState,
  thread : @core.LThread,
  fr_idx : Int,
) -> String {
  let fr = thread.frames[fr_idx]
  let func = match fr.closure {
    Some(cl) => @core.VFunc(cl)
    None =>
      match fr.builtin {
        Some(b) => @core.VBuiltin(b)
        None => @core.VNil
      }
  }
  // The name the function is kept under wins, so a call through `debug.x`
  // reads as `debug.x` however the call site was written.
  match @core.global_func_name(st, func) {
    Some(path) => return "in function '" + path + "'"
    None => ()
  }
  // The name the function was called with, if any.
  match func_name_of(thread, fr_idx) {
    Some((namewhat, name)) =>
      if namewhat != "" {
        return "in " + namewhat + " '" + name + "'"
      }
    None => ()
  }
  match fr.closure {
    Some(cl) => {
      let proto = cl.proto
      if proto.line_defined == 0 {
        "in main chunk"
      } else {
        "in function <" +
        @core.source_for_message(proto.source.data()) +
        ":" +
        proto.line_defined.to_string() +
        ">"
      }
    }
    None => "in ?"
  }
}

///|
/// One formatted traceback line for the frame at index `idx`.
fn traceback_line(
  st : @core.LuaState,
  thread : @core.LThread,
  idx : Int,
) -> String {
  let fr = thread.frames[idx]
  let src = match fr.closure {
    Some(cl) => @core.source_for_message(cl.proto.source.data())
    None => "[C]"
  }
  let line = match fr.closure {
    Some(cl) => @core.line_at(cl.proto, fr.pc - 1)
    None => -1
  }
  let where_part = frame_where(st, thread, idx)
  if line >= 0 {
    "\t" + src + ":" + line.to_string() + ": " + where_part
  } else {
    "\t" + src + ": " + where_part
  }
}

///|
pub fn db_traceback(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let (thread, arg) = get_thread(st, args)
  let msg = arg_or_nil(args, arg)
  // Without a level, a trace of the running thread leaves this call itself out
  // while a trace of another thread starts at its topmost frame.
  let here = if thread.id == st.current_thread.id { 1L } else { 0L }
  let start_level = @core.opt_int(st, args, arg + 1, "traceback", here).to_int()
  // A value that is neither a string, a number nor absent is the message the
  // caller wants back, so it is handed over untouched; a string, a number or no
  // argument at all gets the traceback appended to it (`lua_tostring` turns the
  // number into the text of the message).
  match msg {
    @core.VNil =>
      [
        @core.VStr(
          @core.LStr::of_string(traceback_body(st, thread, "", start_level)),
        ),
      ]
    @core.VStr(_) | @core.VInt(_) | @core.VNum(_) =>
      [
        @core.VStr(
          @core.LStr::of_string(
            traceback_body(st, thread, error_tostring(msg), start_level),
          ),
        ),
      ]
    v => [v]
  }
}

///|
/// The traceback text (without a message), walking the frames of `thread`
/// from `start_level` upward.  Long traces are abbreviated in the middle,
/// as the reference implementation does.
pub fn traceback_body(
  st : @core.LuaState,
  thread : @core.LThread,
  msg : String,
  start_level : Int,
) -> String {
  let buf = StringBuilder()
  if msg != "" {
    buf.write_string(msg)
    buf.write_string("\n")
  }
  buf.write_string("stack traceback:")
  let last = thread.frames.length() - 1
  // A trace of more than the two parts combined shows only the first
  // LEVELS1 and the last LEVELS2 levels, with the count of what was left out
  // named on the line between them.
  let mut limit = if last - start_level > LEVELS1 + LEVELS2 {
    LEVELS1
  } else {
    -1
  }
  let mut level = start_level
  while level <= last {
    if limit == 0 {
      let n = last - level - LEVELS2 + 1
      buf.write_string("\n\t...\t(skipping " + n.to_string() + " levels)")
      level = level + n
      limit = -1
    } else {
      let idx = last - level
      buf.write_string("\n")
      buf.write_string(traceback_line(st, thread, idx))
      if thread.frames[idx].tailcalls > 0 {
        buf.write_string("\n\t(...tail calls...)")
      }
      limit = limit - 1
      level = level + 1
    }
  }
  buf.to_string()
}

///|
/// A minimal `tostring` for the traceback message: strings are used as is,
/// numbers are formatted like the reference, anything else becomes the type
/// name (the reference would call __tostring here).
fn error_tostring(v : @core.Value) -> String {
  match v {
    @core.VStr(s) => @core.text_of(s.data())
    @core.VInt(i) => @core.text_of(@core.int64_to_bytes(i))
    @core.VNum(d) => @core.text_of(@core.double_to_g14(d))
    _ => "object"
  }
}
