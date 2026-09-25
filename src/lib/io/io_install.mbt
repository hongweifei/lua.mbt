// The io table and the default streams.

///|
/// Checks that a mode string is one the host accepts.
pub fn check_mode(mode : Bytes) -> Bool {
  if mode.length() == 0 {
    return false
  }
  let first = @core.ubyte_at(mode, 0)
  if !(first == 114 || first == 119 || first == 97) {
    return false
  }
  let mut i = 1
  if i < mode.length() && @core.ubyte_at(mode, i) == 43 {
    i = i + 1
  }
  while i < mode.length() {
    if @core.ubyte_at(mode, i) != 98 {
      return false
    }
    i = i + 1
  }
  true
}

///|
pub fn io_open(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "open")
  let mode = if args.length() >= 2 && !args[1].is_nil() {
    @core.check_str(state, args, 2, "open").data()
  } else {
    @core.bytes_of("r")
  }
  if !check_mode(mode) {
    @core.arg_error(state, 2, "open", "invalid mode")
  }
  let h = @host.lua_mbt_fopen(name.data(), mode)
  if h == 0L {
    return [
      @core.VNil,
      @core.VStr(
        @core.LStr::of_bytes(
          @core.bytes_concat([
            name.data(),
            @core.bytes_of(": "),
            @core.errno_message(),
          ]),
        ),
      ),
      @core.VInt(@host.lua_mbt_errno().to_int64()),
    ]
  }
  [new_file_value(state, h, @core.text_of(name.data()), false, false)]
}

///|
pub fn io_close(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // Only a call with no argument at all closes the default output; an explicit
  // nil is a value that is not a file (`lua_isnone`, not `lua_isnoneornil`).
  if args.length() == 0 {
    let out = default_output(state)
    return file_close(state, [], [out])
  }
  file_close(state, [], args)
}

///|
pub fn io_flush(
  _state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let _ = args
  let _ = @host.lua_mbt_fflush(0L)
  []
}

///|
pub fn io_read(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = default_input(state)
  let f = match v.as_file() {
    Some(f) => f
    None => @core.runtime_error(state, "default input file is not open")
  }
  read_from_file(state, f, args, 1)
}

///|
pub fn io_write(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = default_output(state)
  let f = match v.as_file() {
    Some(f) => f
    None => @core.runtime_error(state, "default output file is not open")
  }
  let mut i = 0
  while i < args.length() {
    let b = write_arg(state, args, i, "write")
    let n = @host.lua_mbt_fwrite(f.handle, b, b.length())
    if n != b.length() {
      return file_result(false, f.name)
    }
    i = i + 1
  }
  [v]
}

///|
/// Sets or returns the default input or output file.
pub fn set_default_file(
  state : @core.LuaState,
  args : Array[@core.Value],
  key : String,
  fname : String,
  mode : Bytes,
) -> Array[@core.Value] raise @core.LuaRaised {
  if args.length() >= 1 && !args[0].is_nil() {
    // A string *or a number* names a file to open (`lua_tostring` coerces);
    // anything else has to be a file handle.
    let named : Bytes? = match args[0] {
      @core.VStr(s) => Some(s.data())
      @core.VInt(i) => Some(@core.int64_to_bytes(i))
      @core.VNum(d) => Some(@core.double_to_g14(d))
      _ => None
    }
    match named {
      Some(name) => {
        let s = @core.LStr::of_bytes(name)
        let h = @host.lua_mbt_fopen(s.data(), mode)
        if h == 0L {
          @core.runtime_error(
            state,
            "cannot open file '" +
            @core.text_of(s.data()) +
            "' (" +
            @core.text_of(@core.errno_message()) +
            ")",
          )
        }
        let v = new_file_value(state, h, @core.text_of(s.data()), false, false)
        let _ = state.registry.set_str(key, v)
      }
      None =>
        match args[0] {
          @core.VUserData(u) => {
            let not_a_file = match u.kind {
              @core.UDFile(_) => false
              _ => true
            }
            if not_a_file {
              @core.arg_error(
                state,
                1,
                fname,
                "FILE* expected, got " + @core.type_error_name(state, args[0]),
              )
            }
            let _ = state.registry.set_str(key, args[0])
          }
          other =>
            @core.arg_error(
              state,
              1,
              fname,
              "FILE* expected, got " + @core.type_error_name(state, other),
            )
        }
    }
  }
  let cur = state.registry.get_str(key)
  let missing = match cur {
    @core.VUserData(_) => false
    _ => true
  }
  if missing {
    // Neither default file exists yet: stand in for the process stream.
    let reading = @core.ubyte_at(mode, 0) == 114
    let std = if reading {
      new_file_value(state, @host.lua_mbt_stdin(), "stdin", true, false)
    } else {
      new_file_value(state, @host.lua_mbt_stdout(), "stdout", true, false)
    }
    let _ = state.registry.set_str(key, std)
    [std]
  } else {
    [cur]
  }
}

///|
/// The default input file, created lazily.
pub fn default_input(st : @core.LuaState) -> @core.Value {
  match st.registry.get_str("__io_input") {
    @core.VUserData(_) => st.registry.get_str("__io_input")
    _ => {
      let v = new_file_value(st, @host.lua_mbt_stdin(), "stdin", true, false)
      let _ = st.registry.set_str("__io_input", v)
      v
    }
  }
}

///|
/// The default output file, created lazily.
pub fn default_output(st : @core.LuaState) -> @core.Value {
  match st.registry.get_str("__io_output") {
    @core.VUserData(_) => st.registry.get_str("__io_output")
    _ => {
      let v = new_file_value(st, @host.lua_mbt_stdout(), "stdout", true, false)
      let _ = st.registry.set_str("__io_output", v)
      v
    }
  }
}

///|
pub fn io_input(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  set_default_file(state, args, "__io_input", "input", @core.bytes_of("r"))
}

///|
pub fn io_output(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  set_default_file(state, args, "__io_output", "output", @core.bytes_of("w"))
}

///|
pub fn io_lines(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 || args[0].is_nil() {
    let v = default_input(state)
    return [
      @core.VBuiltin(
        @core.make_builtin(
          "io_lines_iterator",
          @core.BK_NORMAL,
          -1,
          io_lines_iterator,
          [v],
        ),
      ),
    ]
  }
  let name = @core.check_str(state, args, 1, "lines")
  let h = @host.lua_mbt_fopen(name.data(), @core.bytes_of("r"))
  if h == 0L {
    @core.runtime_error(
      state,
      "cannot open file '" +
      @core.text_of(name.data()) +
      "' (" +
      @core.text_of(@core.errno_message()) +
      ")",
    )
  }
  let v = new_file_value(state, h, @core.text_of(name.data()), false, false)
  let up : Array[@core.Value] = [v]
  let mut i = 1
  while i < args.length() {
    up.push(args[i])
    i = i + 1
  }
  [
    @core.VBuiltin(
      @core.make_builtin(
        "io_lines_iterator",
        @core.BK_NORMAL,
        -1,
        io_lines_iterator,
        up,
      ),
    ),
    // The state and the control value are nil, and the *file* is the fourth
    // value: a generic `for` closes it when the loop ends, however it ends.
    // That is what closes the file when the loop is broken out of, which the
    // iterator itself cannot see (`lstrlib`'s `io_lines` returns the same four).
    @core.VNil,
    @core.VNil,
    v,
  ]
}

///|
pub fn io_popen(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let cmd = @core.check_str(state, args, 1, "popen")
  let mode = if args.length() >= 2 && !args[1].is_nil() {
    @core.check_str(state, args, 2, "popen").data()
  } else {
    @core.bytes_of("r")
  }
  if !check_mode(mode) {
    @core.arg_error(state, 2, "popen", "invalid mode")
  }
  let h = @host.lua_mbt_popen(cmd.data(), mode)
  if h == 0L {
    return [
      @core.VNil,
      @core.VStr(
        @core.LStr::of_bytes(
          @core.bytes_concat([
            cmd.data(),
            @core.bytes_of(": "),
            @core.errno_message(),
          ]),
        ),
      ),
      @core.VInt(@host.lua_mbt_errno().to_int64()),
    ]
  }
  [new_file_value(state, h, @core.text_of(cmd.data()), false, true)]
}

///|
pub fn io_tmpfile(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let _ = args
  let h = @host.lua_mbt_tmpfile()
  if h == 0L {
    return [
      @core.VNil,
      @core.VStr(@core.LStr::of_bytes(@core.errno_message())),
      @core.VInt(@host.lua_mbt_errno().to_int64()),
    ]
  }
  [new_file_value(state, h, "tmpfile", false, false)]
}

///|
/// Reports the kind of a file value.
pub fn io_type(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "type")
  match v.as_file() {
    Some(f) =>
      if f.closed {
        [@core.VStr(@core.LStr::of_string("closed file"))]
      } else {
        [@core.VStr(@core.LStr::of_string("file"))]
      }
    None => [@core.VNil]
  }
}

///|
pub fn open_io_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("close", @core.VBuiltin(@core.LBuiltin::make("close", 1, io_close)))
  t.set_str("flush", @core.VBuiltin(@core.LBuiltin::make("flush", 0, io_flush)))
  t.set_str("input", @core.VBuiltin(@core.LBuiltin::make("input", 1, io_input)))
  t.set_str(
    "lines",
    @core.VBuiltin(@core.LBuiltin::make("lines", -1, io_lines)),
  )
  t.set_str("open", @core.VBuiltin(@core.LBuiltin::make("open", 2, io_open)))
  t.set_str(
    "output",
    @core.VBuiltin(@core.LBuiltin::make("output", 1, io_output)),
  )
  t.set_str("popen", @core.VBuiltin(@core.LBuiltin::make("popen", 2, io_popen)))
  t.set_str("read", @core.VBuiltin(@core.LBuiltin::make("read", -1, io_read)))
  t.set_str(
    "tmpfile",
    @core.VBuiltin(@core.LBuiltin::make("tmpfile", 0, io_tmpfile)),
  )
  t.set_str("type", @core.VBuiltin(@core.LBuiltin::make("type", 1, io_type)))
  t.set_str(
    "write",
    @core.VBuiltin(@core.LBuiltin::make("write", -1, io_write)),
  )
  t.set_str(
    "stdin",
    new_file_value(state, @host.lua_mbt_stdin(), "stdin", true, false),
  )
  t.set_str(
    "stdout",
    new_file_value(state, @host.lua_mbt_stdout(), "stdout", true, false),
  )
  t.set_str(
    "stderr",
    new_file_value(state, @host.lua_mbt_stderr(), "stderr", true, false),
  )
  state.globals.set_str("io", @core.VTable(t))
}
