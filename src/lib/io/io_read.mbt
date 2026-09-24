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
  let digits_here = fn() -> Int {
    let mut k = 0
    while c >= 0 &&
          (if hex {
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
  digits = digits + digits_here()
  if c == 46 || c == @core.locale_decpoint() {
    accept()
    digits = digits + digits_here()
  }
  if digits > 0 && (if hex { c == 112 || c == 80 } else { c == 101 || c == 69 }) {
    accept()
    if c == 45 || c == 43 {
      accept()
    }
    let _ = digits_here()
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
  formats : Array[@core.Value],
  first : Int,
) -> Array[@core.Value] raise @core.LuaRaised {
  // The error indicator belongs to the stream, not to this call: clearing it
  // first is what keeps an earlier failure from being reported again by a read
  // that succeeded (`clearerr` at the top of `g_read`).
  @host.lua_mbt_clearerr(f.handle)
  let out : Array[@core.Value] = []
  if formats.length() == 0 {
    out.push(read_line_from(f, false))
    return read_outcome(f, out)
  }
  let mut i = 0
  while i < formats.length() {
    let v = formats[i]
    match v {
      @core.VInt(_) | @core.VNum(_) => {
        let k = match @core.value_to_int64(v) {
          Some(k) => k
          None =>
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
      return read_outcome(f, out)
    }
    i = i + 1
  }
  let _ = state
  read_outcome(f, out)
}

///|
pub fn file_read(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
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
/// The iterator produced by `file:lines`.  It reads once per call and closes
/// the file when it reaches the end.
pub fn lines_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = args
  let filev = upvals[0]
  let f = match filev.as_file() {
    Some(f) => f
    None => return [@core.VNil]
  }
  let formats : Array[@core.Value] = []
  let mut i = 1
  while i < upvals.length() {
    formats.push(upvals[i])
    i = i + 1
  }
  let res = read_from_file(state, f, formats, 1)
  if res.length() > 0 && res[0].is_nil() {
    return [@core.VNil]
  }
  res
}

///|
/// The iterator produced by `io.lines`, which also closes the file.
pub fn io_lines_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = args
  let filev = upvals[0]
  let f = match filev.as_file() {
    Some(f) => f
    None => return [@core.VNil]
  }
  let formats : Array[@core.Value] = []
  let mut i = 1
  while i < upvals.length() {
    formats.push(upvals[i])
    i = i + 1
  }
  let res = read_from_file(state, f, formats, 1)
  if res.length() > 0 && res[0].is_nil() {
    if !f.closed && !f.standard {
      let _ = @host.lua_mbt_fclose(f.handle)
      f.closed = true
      f.handle = 0L
    }
    return [@core.VNil]
  }
  res
}

///|
pub fn file_lines(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let _ = check_open_file(state, args, 1, "lines")
  let up : Array[@core.Value] = [args[0]]
  let mut i = 1
  while i < args.length() {
    up.push(args[i])
    i = i + 1
  }
  [
    @core.VBuiltin(
      @core.make_builtin(
        "lines_iterator",
        @core.BK_NORMAL,
        -1,
        lines_iterator,
        up,
      ),
    ),
  ]
}
