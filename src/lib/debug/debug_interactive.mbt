// The two `debug` entries that are not about inspecting a running program:
// the interactive session and the C-stack limit knob 5.4 keeps for
// compatibility.

///|
/// `debug.debug` reads lines from the standard input and runs each one until
/// the line `cont` or the end of the input.  A line that fails is reported on
/// the standard error and the session goes on, which is what the reference's
/// loop does.
#warnings("-unused_error_type")
pub fn db_debug(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  _args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  // The reference reads the standard input directly (`fgets`), so the stream is
  // taken from the io library as a plain file record rather than through the
  // handle `io.stdin` names.
  let input = @iolib.standard_input_file()
  let mut done = false
  while !done {
    @core.write_stderr(@core.bytes_of("lua_debug> "))
    match @iolib.read_line_from(input, true) {
      @core.VStr(s) =>
        if s.data() == @core.bytes_of("cont\n") {
          done = true
        } else {
          run_line(st, s.data())
        }
      // The end of the input, or a value that is not a string, ends the session.
      _ => done = true
    }
  }
  []
}

///|
/// Runs one line of the interactive session, reporting a failure on the
/// standard error.
fn run_line(st : @core.LuaState, line : Bytes) -> Unit {
  match
    @load.compile_source(st, line, "=(debug command)", @core.VTable(st.globals)) {
    @core.LoadError(msg) => report_line(msg)
    @core.LoadOk(f) => {
      let (ok, vals) = @load.pcall_here(st, f, [])
      if !ok {
        let e = if vals.length() > 0 { vals[0] } else { @core.VNil }
        report_line(@load.message_of_error(st, e))
      }
    }
  }
}

///|
/// Reports one line of the interactive session, the way `db_debug` does.
fn report_line(msg : Bytes) -> Unit {
  @core.write_stderr(@core.bytes_concat([msg, @core.bytes_of("\n")]))
}

///|
/// `debug.setcstacklimit` is a leftover of the C-stack limit that 5.4 no longer
/// has: the reference ignores the argument and answers the limit it used to
/// impose.
pub fn db_setcstacklimit(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = @core.check_int(st, args, 1, "setcstacklimit")
  [@core.VInt(@core.MAX_CCALLS.to_int64())]
}
