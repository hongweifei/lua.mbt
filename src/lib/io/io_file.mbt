// The file userdata and its methods.

///|
pub fn new_file_value(
  state : @core.LuaState,
  handle : Int64,
  name : String,
  standard : Bool,
  popened : Bool,
) -> @core.Value {
  let f : @core.LFile = { handle, closed: false, standard, popened, name, }
  let u = @core.LUserData::new_file(f)
  let mt = file_metatable(state)
  u.meta = Some(mt)
  // The file metatable closes the handle in `__gc`, so a collected file is
  // closed by the collector like any other finalizable object.
  @core.gc_register(state, @core.VUserData(u))
  @core.VUserData(u)
}

///|
/// The complaint about an argument that should hold a file handle.  An
/// argument that was never passed has no type at all, which the reference
/// reports as "no value".
fn file_expected(
  state : @core.LuaState,
  args : Array[@core.Value],
  n : Int,
) -> String {
  let got = match args.get(n - 1) {
    None => "no value"
    Some(v) => @core.type_error_name(state, v)
  }
  "FILE* expected, got " + got
}

///|
/// The metatable shared by every file.
pub fn file_metatable(state : @core.LuaState) -> @core.LTable {
  match state.registry.get_str("__file_meta") {
    @core.VTable(t) => t
    _ => {
      let mt = @core.LTable::new()
      // Named after the C type, as the library's metatable registry does, so
      // that an argument error can say "got FILE*".
      mt.set_str("__name", @core.VStr(@core.LStr::of_string("FILE*")))
      let methods = @core.LTable::new()
      methods.set_str(
        "close",
        @core.VBuiltin(@core.LBuiltin::make("close", 1, file_close)),
      )
      methods.set_str(
        "flush",
        @core.VBuiltin(@core.LBuiltin::make("flush", 1, file_flush)),
      )
      methods.set_str(
        "lines",
        @core.VBuiltin(@core.LBuiltin::make("lines", -1, file_lines)),
      )
      methods.set_str(
        "read",
        @core.VBuiltin(@core.LBuiltin::make("read", -1, file_read)),
      )
      methods.set_str(
        "seek",
        @core.VBuiltin(@core.LBuiltin::make("seek", 3, file_seek)),
      )
      methods.set_str(
        "setvbuf",
        @core.VBuiltin(@core.LBuiltin::make("setvbuf", 3, file_setvbuf)),
      )
      methods.set_str(
        "write",
        @core.VBuiltin(@core.LBuiltin::make("write", -1, file_write)),
      )
      mt.set_str("__index", @core.VTable(methods))
      mt.set_str("__name", @core.VStr(@core.LStr::of_string("FILE*")))
      mt.set_str(
        "__tostring",
        @core.VBuiltin(@core.LBuiltin::make("__tostring", 1, file_tostring)),
      )
      mt.set_str(
        "__close",
        @core.VBuiltin(@core.LBuiltin::make("__close", 2, file_gc)),
      )
      mt.set_str(
        "__gc",
        @core.VBuiltin(@core.LBuiltin::make("__gc", 1, file_gc)),
      )
      let _ = state.registry.set_str("__file_meta", @core.VTable(mt))
      mt
    }
  }
}

///|
/// The handle of a file argument, rejecting closed files.
pub fn check_open_file(
  state : @core.LuaState,
  args : Array[@core.Value],
  n : Int,
  fname : String,
) -> @core.LFile raise @core.LuaRaised {
  let v = match args.get(n - 1) {
    Some(v) => v
    None => @core.VNil
  }
  let f = match v.as_file() {
    Some(f) => f
    None => @core.arg_error(state, n, fname, file_expected(state, args, n))
  }
  if f.closed || f.handle == 0L {
    @core.runtime_error(state, "attempt to use a closed file")
  }
  f
}

///|
/// A file result following the convention: the value, or nil plus a message
/// and the error number.
pub fn file_result(ok : Bool, name : String) -> Array[@core.Value] {
  if ok {
    [@core.VBool(true)]
  } else {
    file_failure(Some(name))
  }
}

///|
/// `luaL_fileresult`'s failure case: nil, the host's text for the error number,
/// and that number.  `name` is the file the failure is about, and `None` is the
/// NULL name the reference passes where there is no file to name -- a *stream*
/// that failed rather than an operation on a path, which is how `g_read` reports
/// a read error.
fn file_failure(name : String?) -> Array[@core.Value] {
  let e = @host.lua_mbt_errno()
  let text = @core.text_of(@core.errno_message())
  let msg = match name {
    Some(n) => n + ": " + text
    None => text
  }
  [@core.VNil, @core.VStr(@core.LStr::of_string(msg)), @core.VInt(e.to_int64())]
}

///|
/// Closes an open, non-standard file and returns what the caller should report:
/// a process's exit status for a `popen`ed file, `true` or a file result
/// otherwise.
fn close_open_file(f : @core.LFile) -> Array[@core.Value] {
  if f.popened {
    // Closing a process reports how it ended, which is `luaL_execresult`'s
    // triple: on Windows the type is always "exit" and the code is what
    // `pclose` returned (`l_inspectstat` is a no-op there).
    let r = @host.lua_mbt_pclose(f.handle)
    f.closed = true
    f.handle = 0L
    return [
      if r == 0 {
        @core.VBool(true)
      } else {
        @core.VNil
      },
      @core.VStr(@core.LStr::of_string("exit")),
      @core.VInt(r.to_int64()),
    ]
  }
  let r = @host.lua_mbt_fclose(f.handle)
  f.closed = true
  f.handle = 0L
  if r != 0 {
    file_result(false, f.name)
  } else {
    [@core.VBool(true)]
  }
}

///|
/// The `close` method.  A file that is already closed is an error, which is
/// `f_close`'s `tofile`; only the collector's own handler ignores one.
pub fn file_close(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = match args.get(0) {
    Some(v) => v
    None => @core.VNil
  }
  let f = match v.as_file() {
    Some(f) => f
    None => @core.arg_error(state, 1, "close", file_expected(state, args, 1))
  }
  if f.closed || f.handle == 0L {
    @core.runtime_error(state, "attempt to use a closed file")
  }
  if f.standard {
    return [
      @core.VNil,
      @core.VStr(@core.LStr::of_string("cannot close standard file")),
    ]
  }
  close_open_file(f)
}

///|
/// The `__gc` and `__close` handler of a file, the reference's `f_gc`: the
/// argument has to be a file (`tolstream`), but a closed or incompletely open
/// one is ignored rather than reported, and the result of the close is thrown
/// away because nothing asked for it.
pub fn file_gc(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = match args.get(0) {
    Some(v) => v
    None => @core.VNil
  }
  let f = match v.as_file() {
    Some(f) => f
    None => @core.arg_error(state, 1, "__gc", file_expected(state, args, 1))
  }
  if !f.closed && f.handle != 0L && !f.standard {
    let _ = close_open_file(f)
  }
  []
}

///|
pub fn file_flush(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = check_open_file(state, args, 1, "flush")
  let r = @host.lua_mbt_fflush(f.handle)
  if r == 0 {
    [@core.VBool(true)]
  } else {
    file_result(false, f.name)
  }
}

///|
pub fn file_setvbuf(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = check_open_file(state, args, 1, "setvbuf")
  let mode = @core.check_option(
    state,
    args,
    2,
    "setvbuf",
    ["no", "full", "line"],
    "no",
  )
  let size = @core.opt_int(state, args, 3, "setvbuf", 1024L)
  let m = match mode {
    "no" => 2
    "full" => 0
    _ => 1
  }
  let r = @host.lua_mbt_setvbuf(f.handle, m, size.to_int())
  if r == 0 {
    [@core.VBool(true)]
  } else {
    file_result(false, f.name)
  }
}

///|
pub fn file_tostring(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "tostring")
  let f = match v.as_file() {
    Some(f) => f
    None => @core.arg_error(state, 1, "tostring", "FILE* expected")
  }
  if f.closed {
    [@core.VStr(@core.LStr::of_string("file (closed)"))]
  } else {
    // The reference prints the stream's address (`io_tostring`'s `file (%p)`),
    // and the handle *is* the `FILE*`.
    [
      @core.VStr(
        @core.LStr::of_string("file (" + @core.hex_address(f.handle) + ")"),
      ),
    ]
  }
}

///|----------------------------------------------------------------
/// Reading

///|----------------------------------------------------------------

///|
pub fn file_write(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = check_open_file(state, args, 1, "write")
  let mut i = 1
  while i < args.length() {
    let b = write_arg(state, args, i, "write")
    let n = @host.lua_mbt_fwrite(f.handle, b, b.length())
    if n != b.length() {
      return file_result(false, f.name)
    }
    i = i + 1
  }
  [args[0]]
}

///|
/// `g_write` takes strings and numbers only; any other value is an error, it
/// does not fall back on `tostring`.
fn write_arg(
  state : @core.LuaState,
  args : Array[@core.Value],
  n : Int,
  fname : String,
) -> Bytes raise @core.LuaRaised {
  match args[n] {
    @core.VStr(s) => s.data()
    @core.VInt(_) | @core.VNum(_) => @vm.to_string(state, args[n])
    _ => @core.check_str(state, args, n + 1, fname).data()
  }
}

///|
pub fn file_seek(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let f = check_open_file(state, args, 1, "seek")
  let whence = @core.check_option(
    state,
    args,
    2,
    "seek",
    ["set", "cur", "end"],
    "cur",
  )
  let offset = @core.opt_int(state, args, 3, "seek", 0L)
  let w = match whence {
    "set" => 0
    "cur" => 1
    _ => 2
  }
  let r = @host.lua_mbt_fseek(f.handle, offset, w)
  if r != 0.0 {
    return file_result(false, f.name)
  }
  let pos = @host.lua_mbt_ftell(f.handle)
  [@core.VInt(pos)]
}

///|----------------------------------------------------------------
/// The `io` table

///|----------------------------------------------------------------
