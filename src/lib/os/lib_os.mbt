// The operating system library.

///|
pub fn os_clock(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = state
  let _ = upvals
  let _ = args
  @core.One(@core.VNum(@host.lua_mbt_clock()))
}

///|
pub fn os_time(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 || args[0].is_nil() {
    return @core.One(@core.VInt(@host.lua_mbt_time()))
  }
  let t = @core.check_table(state, args, 1, "time")
  // Year, month and day have no default, so a date table missing one is
  // refused; the time-of-day fields do have them (`os_time`'s `getfield`).
  let year = field_int(state, t, "year", -1L)
  let month = field_int(state, t, "month", -1L)
  let day = field_int(state, t, "day", -1L)
  let hour = field_int(state, t, "hour", 12L)
  let min = field_int(state, t, "min", 0L)
  let sec = field_int(state, t, "sec", 0L)
  let isdst = match t.get_str("isdst") {
    @core.VBool(true) => 1
    @core.VBool(false) => 0
    _ => -1
  }
  let r = @host.lua_mbt_time_make(
    year.to_int(),
    month.to_int(),
    day.to_int(),
    hour.to_int(),
    min.to_int(),
    sec.to_int(),
    isdst,
    1,
  )
  if r == -1L {
    @core.runtime_error(
      state, "time result cannot be represented in this installation",
    )
  }
  @core.One(@core.VInt(r))
}

///|
pub fn field_int(
  state : @core.LuaState,
  t : @core.LTable,
  name : String,
  dflt : Int64,
) -> Int64 raise @core.LuaRaised {
  match t.get_str(name) {
    @core.VInt(i) => i
    @core.VNum(d) =>
      if @core.float_is_int64(d) {
        @core.float_to_int64(d)
      } else {
        @core.runtime_error(state, "field '" + name + "' is not an integer")
      }
    @core.VNil =>
      // A negative default marks a field the reference requires.
      if dflt < 0L {
        @core.runtime_error(state, "field '" + name + "' missing in date table")
      } else {
        dflt
      }
    _ => @core.runtime_error(state, "field '" + name + "' is not an integer")
  }
}

///|
pub fn os_difftime(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  // Both timestamps are required, and both are integers: `l_checktime` goes
  // through `luaL_checkinteger`, so a fractional value is refused rather than
  // truncated.  The result is a float.
  let a = @core.check_int(state, args, 1, "difftime")
  let b = @core.check_int(state, args, 2, "difftime")
  @core.One(@core.VNum(@host.lua_mbt_diff_seconds(a, b)))
}

///|
/// `os.date` formats a timestamp, or breaks it into the fields of a table when
/// the format is `*t` or `!*t`.
pub fn os_date(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let mut fmt = if args.length() >= 1 && !args[0].is_nil() {
    @core.check_str(state, args, 1, "date").data()
  } else {
    @core.bytes_of("%c")
  }
  let t = if args.length() >= 2 && !args[1].is_nil() {
    @core.check_int(state, args, 2, "date")
  } else {
    @host.lua_mbt_time()
  }
  let mut utc = false
  if fmt.length() > 0 && @core.ubyte_at(fmt, 0) == 33 {
    utc = true
    fmt = @core.bytes_slice(fmt, 1, fmt.length() - 1)
  }
  let mut break_table = false
  if fmt.length() > 0 &&
    @core.ubyte_at(fmt, 0) == 42 &&
    fmt.length() == 2 &&
    @core.ubyte_at(fmt, 1) == 116 {
    break_table = true
  }
  if break_table {
    return @core.One(date_table(state, t, utc))
  }
  check_date_format(state, fmt)
  let is_local = if utc { 0 } else { 1 }
  // The host fills a fixed buffer and reports failure by returning nothing, so
  // a long format (or a long rendering of it) is retried once with a large one.
  // Nothing coming back at all is a legitimate empty result, which the
  // reference appends as nothing rather than reporting.
  let mut buf = Bytes::new(256)
  let mut n = @host.lua_mbt_strftime_time(buf, 256, fmt, t, is_local)
  if n == -2 {
    @core.runtime_error(
      state, "date result cannot be represented in this installation",
    )
  }
  if n < 0 {
    buf = Bytes::new(65536)
    n = @host.lua_mbt_strftime_time(buf, 65536, fmt, t, is_local)
    if n == -2 {
      @core.runtime_error(
        state, "date result cannot be represented in this installation",
      )
    }
  }
  let len = if n < 0 { 0 } else { n }
  @core.One(@core.VStr(@core.LStr::of_bytes(@core.bytes_slice(buf, 0, len))))
}

///|
/// The conversion specifiers the host's `strftime` is allowed to see, grouped
/// by length exactly as the reference's `LUA_STRFTIMEOPTIONS` is for a Windows
/// build (`loslib.c`): the one-character ones, then the two-character ones.
/// A `%` introducing anything else is refused before the host is reached --
/// which is both what the reference reports and what keeps a host `strftime`
/// from aborting the process on a specifier it does not know.
let strftime_options : Bytes = @core.bytes_of(
  "aAbBcdHIjmMpSUwWxXyYzZ%||#c#x#d#H#I#j#m#M#S#U#w#W#y#Y",
)

///|
/// Checks every conversion specifier of a `os.date` format, the way the
/// reference's `checkoption` does: the longest listed specifier wins, and the
/// error names the text from that `%` to the end of the format.
fn check_date_format(
  state : @core.LuaState,
  fmt : Bytes,
) -> Unit raise @core.LuaRaised {
  let n = fmt.length()
  let mut i = 0
  while i < n {
    if @core.ubyte_at(fmt, i) != 37 {
      i = i + 1
      continue
    }
    let rest = n - i - 1
    let mut oplen = 1
    let mut j = 0
    let mut matched = 0
    while j < strftime_options.length() && oplen <= rest {
      if @core.ubyte_at(strftime_options, j) == 124 {
        oplen = oplen + 1
      } else {
        let mut k = 0
        let mut same = true
        while k < oplen {
          if @core.ubyte_at(fmt, i + 1 + k) !=
            @core.ubyte_at(strftime_options, j + k) {
            same = false
          }
          k = k + 1
        }
        if same {
          matched = oplen
        }
      }
      j = j + oplen
    }
    if matched == 0 {
      let text = @core.text_of(@core.bytes_slice(fmt, i + 1, rest))
      @core.arg_error(
        state,
        1,
        "date",
        "invalid conversion specifier '%" + text + "'",
      )
    }
    i = i + 1 + matched
  }
}

///|
pub fn date_table(
  state : @core.LuaState,
  t : Int64,
  utc : Bool,
) -> @core.Value raise @core.LuaRaised {
  let _ = state
  let raw = Bytes::new(36)
  let rc = @host.lua_mbt_tm_breakdown(t, if utc { 0 } else { 1 }, raw)
  if rc != 0 {
    @core.raise_fresh(
      state,
      @core.VStr(
        @core.LStr::of_string(
          "date result cannot be represented in this installation",
        ),
      ),
    )
  }
  let out = @core.LTable::new()
  let vals : Array[Int] = []
  let mut i = 0
  while i < 9 {
    let mut acc = 0
    let mut k = 3
    while k >= 0 {
      acc = acc * 256 + @core.ubyte_at(raw, i * 4 + k)
      k = k - 1
    }
    vals.push(acc)
    i = i + 1
  }
  out.set_str("year", @core.VInt(vals[0].to_int64()))
  out.set_str("month", @core.VInt(vals[1].to_int64()))
  out.set_str("day", @core.VInt(vals[2].to_int64()))
  out.set_str("hour", @core.VInt(vals[3].to_int64()))
  out.set_str("min", @core.VInt(vals[4].to_int64()))
  out.set_str("sec", @core.VInt(vals[5].to_int64()))
  out.set_str("wday", @core.VInt(vals[6].to_int64()))
  out.set_str("yday", @core.VInt(vals[7].to_int64()))
  out.set_str("isdst", @core.VBool(vals[8] != 0))
  @core.VTable(out)
}

///|
/// The value of the environment variable `name`, or none when it is unset.
/// The host reports the length the value needs when the buffer is too small, so
/// the buffer grows until the value fits.
pub fn os_env(name : String) -> Bytes? {
  let key = @core.bytes_of(name)
  let mut size = 1024
  while size < 1048576 {
    let buf = Bytes::new(size)
    let n = @host.lua_mbt_getenv(key, buf, size)
    if n < 0 {
      return None
    }
    if n < size {
      return Some(@core.bytes_slice(buf, 0, n))
    }
    size = n + 1
  }
  None
}

///|
pub fn os_getenv(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "getenv")
  match os_env(@core.text_of(name.data())) {
    Some(v) => @core.One(@core.VStr(@core.LStr::of_bytes(v)))
    None => @core.One(@core.VNil)
  }
}

///|
pub fn os_remove(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let name = @core.check_str(state, args, 1, "remove")
  let r = @host.lua_mbt_remove(name.data())
  if r != 0 {
    return @core.Many([
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
    ])
  }
  @core.One(@core.VBool(true))
}

///|
pub fn os_rename(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let from = @core.check_str(state, args, 1, "rename")
  let to = @core.check_str(state, args, 2, "rename")
  let r = @host.lua_mbt_rename(from.data(), to.data())
  if r != 0 {
    return @core.Many([
      @core.VNil,
      @core.VStr(@core.LStr::of_bytes(@core.errno_message())),
      @core.VInt(@host.lua_mbt_errno().to_int64()),
    ])
  }
  @core.One(@core.VBool(true))
}

///|
pub fn os_tmpname(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let _ = args
  let buf = Bytes::new(512)
  let ok = @host.lua_mbt_tmpnam(buf, 512)
  if ok == 0L {
    @core.runtime_error(state, "unable to generate a unique filename")
  }
  let len = @strlib.c_string_length(buf)
  @core.One(@core.VStr(@core.LStr::of_bytes(@core.bytes_slice(buf, 0, len))))
}

///|
/// Executes a shell command.  With no argument it reports whether a shell is
/// available, like the reference implementation.
pub fn os_execute(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  // Without a command the answer is just whether a shell is available, and
  // with one it is `luaL_execresult`'s triple -- whose first value is *nil*,
  // not false, when the command failed.
  if args.length() == 0 || args[0].is_nil() {
    return @core.One(@core.VBool(@host.lua_mbt_system_available() != 0))
  }
  let cmd = @core.check_str(state, args, 1, "execute")
  let r = @host.lua_mbt_system(cmd.data())
  @core.Many([
    if r == 0 {
      @core.VBool(true)
    } else {
      @core.VNil
    },
    @core.VStr(@core.LStr::of_string("exit")),
    @core.VInt(r.to_int64()),
  ])
}

///|
/// Terminates the process.  A second argument of true asks the host to release
/// its resources first, which is what the reference implementation does.
pub fn os_exit(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let code = @core.opt_int(state, args, 1, "exit", 0L)
  let _ = args
  @core.host_exit(code.to_int())
  @core.Nothing
}

///|
pub fn os_setlocale(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 || args[0].is_nil() {
    let buf = Bytes::new(256)
    let n = @host.lua_mbt_getlocale(buf, 256)
    return @core.One(
      @core.VStr(@core.LStr::of_bytes(@core.bytes_slice(buf, 0, n))),
    )
  }
  let locale = @core.check_str(state, args, 1, "setlocale")
  let cats : Array[String] = [
    "all", "collate", "ctype", "monetary", "numeric", "time",
  ]
  let cat = if args.length() >= 2 && !args[1].is_nil() {
    @core.text_of(@core.check_str(state, args, 2, "setlocale").data())
  } else {
    "all"
  }
  let mut category = -1
  let mut i = 0
  while i < cats.length() {
    if cats[i] == cat {
      category = i
    }
    i = i + 1
  }
  if category < 0 {
    @core.arg_error(state, 2, "setlocale", "invalid option '" + cat + "'")
  }
  let ok = @host.lua_mbt_setlocale(locale.data(), category)
  if ok == 0 {
    return @core.One(@core.VNil)
  }
  @core.bump_locale_generation()
  let buf = Bytes::new(256)
  let n = @host.lua_mbt_getlocale(buf, 256)
  @core.One(@core.VStr(@core.LStr::of_bytes(@core.bytes_slice(buf, 0, n))))
}

///|
pub fn open_os_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("clock", @core.VBuiltin(@core.LBuiltin::make("clock", 0, os_clock)))
  t.set_str("date", @core.VBuiltin(@core.LBuiltin::make("date", 2, os_date)))
  t.set_str(
    "difftime",
    @core.VBuiltin(@core.LBuiltin::make("difftime", 2, os_difftime)),
  )
  t.set_str(
    "execute",
    @core.VBuiltin(@core.LBuiltin::make("execute", 1, os_execute)),
  )
  t.set_str("exit", @core.VBuiltin(@core.LBuiltin::make("exit", 2, os_exit)))
  t.set_str(
    "getenv",
    @core.VBuiltin(@core.LBuiltin::make("getenv", 1, os_getenv)),
  )
  t.set_str(
    "remove",
    @core.VBuiltin(@core.LBuiltin::make("remove", 1, os_remove)),
  )
  t.set_str(
    "rename",
    @core.VBuiltin(@core.LBuiltin::make("rename", 2, os_rename)),
  )
  t.set_str(
    "setlocale",
    @core.VBuiltin(@core.LBuiltin::make("setlocale", 2, os_setlocale)),
  )
  t.set_str("time", @core.VBuiltin(@core.LBuiltin::make("time", 1, os_time)))
  t.set_str(
    "tmpname",
    @core.VBuiltin(@core.LBuiltin::make("tmpname", 0, os_tmpname)),
  )
  state.globals.set_str("os", @core.VTable(t))
}
