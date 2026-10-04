// Reading from a file in the formats the language defines.

///|
/// Skips whitespace, returning the first other byte (pushed back).
pub fn skip_space(f : @core.LFile) -> Int {
  while true {
    let c = @host.lua_mbt_fgetc(f.handle)
    if c < 0 {
      return -1
    }
    let b = if c > 127 { c - 256 } else { c }
    let u = if b < 0 { b + 256 } else { b }
    if !@core.is_space_byte(u) {
      let _ = @host.lua_mbt_ungetc(c, f.handle)
      return c
    }
  }
  0
}

///|
/// Reads a numeral from the stream, the reference's `read_number`: a small state
/// machine collects the longest prefix that *looks* like a numeral, and the
/// numeral reader decides whether it is one.  The order of the tests is what
/// makes `-0x1p4` a single number -- the sign comes before the `0x` -- and a
/// prefix that turns out not to be a numeral is reported as a failed read, with
/// the stream left just past it.
pub fn read_number_from(f : @core.LFile) -> @core.Value {
  // The reference stops collecting at L_MAXLENNUM and answers nil.
  let max_len = 200
  let buf = Buffer::Buffer(size_hint=32)
  let mut n = 0
  let mut hex = false
  let mut digits = 0
  let mut c = @host.lua_mbt_fgetc(f.handle)
  while c >= 0 && @core.is_space_byte(c) {
    c = @host.lua_mbt_fgetc(f.handle)
  }
  // Accept the current character (if the buffer has room) and read the next.
  let mut full = false
  let accept = fn() -> Unit {
    if n >= max_len {
      full = true
    } else {
      buf.write_byte(@core.byte_of(c))
      n = n + 1
      c = @host.lua_mbt_fgetc(f.handle)
    }
  }
  // `readdigits` takes the base as an argument: the exponent is marked `p` for a
  // hexadecimal numeral but always written in decimal digits, so `0x1.13Ap+3`
  // ends at the `p`'s digits and leaves the `x` of a following word alone.
  let digits_here = fn(hexp : Bool) -> Int {
    let mut k = 0
    while c >= 0 &&
          (if hexp {
            @core.is_hex_digit_byte(c)
          } else {
            @core.is_digit_byte(c)
          }) &&
          !full {
      accept()
      k = k + 1
    }
    k
  }
  if c == 45 || c == 43 {
    accept()
  }
  if c == 48 {
    accept()
    if c == 120 || c == 88 {
      hex = true
      accept()
    } else {
      digits = 1
    }
  }
  digits = digits + digits_here(hex)
  if c == 46 || c == @core.locale_decpoint() {
    accept()
    digits = digits + digits_here(hex)
  }
  if digits > 0 && (if hex { c == 112 || c == 80 } else { c == 101 || c == 69 }) {
    accept()
    if c == 45 || c == 43 {
      accept()
    }
    let _ = digits_here(false)
  }
  if c >= 0 {
    let _ = @host.lua_mbt_ungetc(c, f.handle)
  }
  if full {
    return @core.VNil
  }
  match @core.lua_str2num(buf.to_bytes()) {
    Some(@core.NInt(i)) => @core.VInt(i)
    Some(@core.NFloat(d)) => @core.VNum(d)
    None => @core.VNil
  }
}

///|
/// Reads one line.  When `keep_newline` is false the trailing newline is
/// dropped; the result is nil at the end of the file.
pub fn read_line_from(f : @core.LFile, keep_newline : Bool) -> @core.Value {
  let buf = Buffer::Buffer(size_hint=128)
  let mut got = false
  while true {
    let c = @host.lua_mbt_fgetc(f.handle)
    if c < 0 {
      break
    }
    got = true
    if c == 10 {
      if keep_newline {
        buf.write_byte(@core.byte_of(10))
      }
      break
    }
    buf.write_byte(c.to_byte())
  }
  if !got {
    @core.VNil
  } else {
    let b = buf.to_bytes()
    // A carriage return before the newline belongs to the line ending.
    if b.length() > 0 &&
      !keep_newline &&
      @core.ubyte_at(b, b.length() - 1) == 13 {
      @core.VStr(@core.LStr::of_bytes(@core.bytes_slice(b, 0, b.length() - 1)))
    } else {
      @core.VStr(@core.LStr::of_bytes(b))
    }
  }
}

///|
/// Reads the rest of the stream.
pub fn read_all_from(f : @core.LFile) -> @core.Value {
  let buf = Buffer::Buffer(size_hint=4096)
  let chunk = Bytes::new(8192)
  while true {
    let n = @host.lua_mbt_fread(f.handle, chunk, 8192)
    if n <= 0 {
      break
    }
    buf.write_bytes(chunk.view(end=n))
  }
  @core.VStr(@core.LStr::of_bytes(buf.to_bytes()))
}

///|
/// Reads `n` bytes.
pub fn read_chars_from(f : @core.LFile, n : Int) -> @core.Value {
  let buf = Buffer::Buffer(size_hint=n)
  let chunk = Bytes::new(n)
  let mut got = 0
  while got < n {
    let r = @host.lua_mbt_fread(f.handle, chunk, n - got)
    if r <= 0 {
      break
    }
    buf.write_bytes(chunk.view(end=r))
    got = got + r
  }
  if got == 0 && n > 0 {
    @core.VNil
  } else {
    @core.VStr(@core.LStr::of_bytes(buf.to_bytes()))
  }
}

///|
/// The result of a read, unless the stream itself failed.  `g_read` checks
/// `ferror` once the formats have run and reports the failure *instead of* what
/// was collected; this comes before the short-read substitution below, so a
/// handle opened for writing answers `nil, msg, errno` rather than an empty
/// string.
fn read_outcome(
  f : @core.LFile,
  out : Array[@core.Value],
) -> Array[@core.Value] {
  if @host.lua_mbt_ferror(f.handle) != 0 {
    return file_failure(None)
  }
  out
}

///|
/// The shared implementation of `file:read` and `io.read`.
pub fn read_from_file(
  state : @core.LuaState,
  f : @core.LFile,
  formats : ArrayView[@core.Value],
  first : Int,
) -> @core.BuiltinResult raise @core.LuaRaised {
  // The error indicator belongs to the stream, not to this call: clearing it
  // first is what keeps an earlier failure from being reported again by a read
  // that succeeded (`clearerr` at the top of `g_read`).
  @host.lua_mbt_clearerr(f.handle)
  let out : Array[@core.Value] = []
  if formats.length() == 0 {
    out.push(read_line_from(f, false))
    return @core.Many(read_outcome(f, out))
  }
  let mut i = 0
  while i < formats.length() {
    let v = formats[i]
    match v {
      @core.VInt(_) | @core.VNum(_) => {
        let k = match @core.value_to_int64(v) {
          @core.ConvInt(k) => k
          _ =>
            @core.arg_error(
              state,
              first + i,
              "read",
              "number has no integer representation",
            )
        }
        // `read_chars` asks for the whole count in one buffer, so a count that
        // cannot be had is a memory error rather than a short read.
        if k < 0L || k > 0x7fff_ffffL {
          @core.runtime_error(state, "not enough memory")
        }
        let n = k.to_int()
        if n == 0 {
          let c = @host.lua_mbt_fgetc(f.handle)
          if c < 0 {
            out.push(@core.VNil)
          } else {
            let _ = @host.lua_mbt_ungetc(c, f.handle)
            out.push(@core.VStr(@core.LStr::empty()))
          }
        } else {
          out.push(read_chars_from(f, n))
        }
      }
      _ => {
        let s = @core.check_str(state, formats, i + 1, "read").data()
        let mut j = 0
        if s.length() > 0 && @core.ubyte_at(s, 0) == 42 {
          j = 1
        }
        let code = if j < s.length() { @core.ubyte_at(s, j) } else { -1 }
        match code {
          110 => out.push(read_number_from(f))
          108 => out.push(read_line_from(f, false))
          76 => out.push(read_line_from(f, true))
          97 => out.push(read_all_from(f))
          _ => @core.arg_error(state, first + i, "read", "invalid format")
        }
      }
    }
    let last = out[out.length() - 1]
    if last.is_nil() {
      return @core.Many(read_outcome(f, out))
    }
    i = i + 1
  }
  let _ = state
  @core.Many(read_outcome(f, out))
}

///|
pub fn file_read(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let f = check_open_file(state, args, 1, "read")
  let rest : Array[@core.Value] = []
  let mut i = 1
  while i < args.length() {
    rest.push(args[i])
    i = i + 1
  }
  read_from_file(state, f, rest, 2)
}

///|
/// What an iterator over lines answers, following `io_readline`.  A false first
/// value is not a value the loop is given: it is the end, answered with *no*
/// values at all.  The one thing it does turn into is an error -- when the read
/// came back with the message and the error number of a stream failure, that
/// message is raised here, so a loop stops rather than going on silently.
fn lines_answer(
  state : @core.LuaState,
  res : @core.BuiltinResult,
) -> @core.BuiltinResult raise @core.LuaRaised {
  match res {
    @core.Many(vals) =>
      if vals.length() == 0 || vals[0].is_truthy() {
        res
      } else if vals.length() > 1 {
        // Only `file_failure` answers with more than the nil, so the second value
        // is the host's reason -- whose wording is the host's, which is why
        // nothing here repeats it.
        let why = match vals[1] {
          @core.VStr(s) => @core.text_of(s.data())
          _ => ""
        }
        @core.runtime_error(state, why)
      } else {
        @core.Nothing
      }
    _ => res
  }
}

///|
/// The file an iterator over lines reads from.  A generator that has closed the
/// file it owns -- at the end of the file, or on a break out of the loop that
/// took the fourth value -- answers every later call this way, rather than
/// reading through the handle it gave up.
fn lines_file(
  state : @core.LuaState,
  filev : @core.Value,
) -> @core.LFile raise @core.LuaRaised {
  let f = match filev.as_file() {
    Some(f) => f
    None => @core.runtime_error(state, "file is already closed")
  }
  if f.closed || f.handle == 0L {
    @core.runtime_error(state, "file is already closed")
  }
  f
}

///|
/// `aux_lines`' bound on the formats a `lines` iterator carries: at most
/// `MAXARGLINE` of them, and the argument blamed is the *last* one the reference
/// would have room for, not the first one too many.
fn check_line_formats(
  state : @core.LuaState,
  nargs : Int,
) -> Unit raise @core.LuaRaised {
  if nargs > 250 {
    @core.arg_error(state, 252, "lines", "too many arguments")
  }
}

///|
/// The iterator produced by `file:lines`.  It reads once per call and leaves the
/// file open at the end: the handle was not its to close.
pub fn lines_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = args
  let f = lines_file(state, upvals[0])
  let formats : Array[@core.Value] = []
  let mut i = 1
  while i < upvals.length() {
    formats.push(upvals[i])
    i = i + 1
  }
  lines_answer(state, read_from_file(state, f, formats, 1))
}

///|
/// The iterator produced by `io.lines`, which also closes the file.
pub fn io_lines_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = args
  let f = lines_file(state, upvals[0])
  let formats : Array[@core.Value] = []
  let mut i = 1
  while i < upvals.length() {
    formats.push(upvals[i])
    i = i + 1
  }
  let res = read_from_file(state, f, formats, 1)
  let done = match res {
    @core.Many(vals) => vals.length() == 0 || !vals[0].is_truthy()
    _ => false
  }
  if done {
    if !f.closed && !f.standard {
      let _ = @host.lua_mbt_fclose(f.handle)
      f.closed = true
      f.handle = 0L
    }
  }
  lines_answer(state, res)
}

///|
pub fn file_lines(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let _ = check_open_file(state, args, 1, "lines")
  check_line_formats(state, args.length() - 1)
  let up : Array[@core.Value] = [args[0]]
  let mut i = 1
  while i < args.length() {
    up.push(args[i])
    i = i + 1
  }
  @core.Many([
    @core.VBuiltin(
      @core.make_builtin(
        "lines_iterator",
        @core.BK_NORMAL,
        -1,
        lines_iterator,
        up,
      ),
    ),
  ])
}
