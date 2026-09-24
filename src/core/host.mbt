// Host services the interpreter uses directly: the standard streams, reading

///|
pub fn write_stdout(b : Bytes) -> Unit {
  let out = @host.lua_mbt_stdout()
  if out != 0L && b.length() > 0 {
    let _ = @host.lua_mbt_fwrite(out, b, b.length())
  }
}

///|
/// Writes bytes to standard error.
pub fn write_stderr(b : Bytes) -> Unit {
  let err = @host.lua_mbt_stderr()
  if err != 0L && b.length() > 0 {
    let _ = @host.lua_mbt_fwrite(err, b, b.length())
  }
}

///|
/// Flushes standard output.  The reference flushes it wherever its
/// `lua_writeline` is used -- after a prompt, after a line of results, and
/// after every `print` -- which is what makes a prompt appear before the
/// interpreter waits for input and what keeps output and errors in order when
/// both are redirected to the same file.  Only standard output is flushed: a
/// file a program has open keeps whatever the host has buffered for it, exactly
/// as it does in the reference.
pub fn flush_stdout() -> Unit {
  let out = @host.lua_mbt_stdout()
  if out != 0L {
    let _ = @host.lua_mbt_fflush(out)
  }
}

///|
/// Reads a whole file, returning its contents together with an error message
/// when it cannot be read.
pub fn read_whole_file(path : Bytes) -> Result[Bytes, Bytes] {
  let f = @host.lua_mbt_fopen(path, b"rb")
  if f == 0L {
    return Err(errno_message())
  }
  let buf = Buffer::Buffer(size_hint=8192)
  let chunk = Bytes::new(65536)
  while true {
    let n = @host.lua_mbt_fread(f, chunk, 65536)
    if n <= 0 {
      break
    }
    buf.write_bytes(chunk.view(end=n))
  }
  let err = @host.lua_mbt_ferror(f)
  let _ = @host.lua_mbt_fclose(f)
  if err != 0 {
    return Err(bytes_of("read error"))
  }
  Ok(buf.to_bytes())
}

///|
/// Writes a whole file.
pub fn write_whole_file(path : Bytes, data : Bytes) -> Result[Unit, Bytes] {
  let f = @host.lua_mbt_fopen(path, b"wb")
  if f == 0L {
    return Err(errno_message())
  }
  let n = @host.lua_mbt_fwrite(f, data, data.length())
  let _ = @host.lua_mbt_fclose(f)
  if n != data.length() {
    return Err(errno_message())
  }
  Ok(())
}

///|
/// The message for the current value of the host error indicator.
pub fn errno_message() -> Bytes {
  let buf = Bytes::new(256)
  let n = @host.lua_mbt_strerror(@host.lua_mbt_errno(), buf, 256)
  // The host writes into a fixed buffer; only the bytes up to its reported
  // length (or the first terminator, whichever comes first) are the message.
  let mut len = 0
  while len < n && len < 256 && ubyte_at(buf, len) != 0 {
    len = len + 1
  }
  bytes_slice(buf, 0, len)
}

///|
/// Appends a textual suffix to a byte string, for building messages.
pub fn bytes_add(a : Bytes, b : String) -> Bytes {
  bytes_concat([a, bytes_of(b)])
}

///|
/// Terminates the process, flushing standard streams first.
pub fn host_exit(code : Int) -> Unit {
  @host.lua_mbt_exit(code)
}

///|
/// Locale-aware string comparison, as the VM's ordering uses `strcmp`.

///|
/// Segment-wise locale comparison, as `l_strcmp` in the reference VM.
pub fn lstrcmp(a : Bytes, b : Bytes) -> Int {
  @host.lua_mbt_lstrcmp(a, a.length(), b, b.length())
}

///|
/// Incremented whenever the C locale changes, so that cached locale tables
/// (character classes and the like) can notice and rebuild.
pub let locale_generation : Ref[Int] = Ref(0)

///|
pub fn bump_locale_generation() -> Unit {
  locale_generation.val = locale_generation.val + 1
}

///|
/// The C `ctype` classification for one byte under the current locale.
pub fn host_ctype(which : Int, c : Int) -> Int {
  @host.lua_mbt_ctype(which, c)
}

///|
/// Cached per-locale byte case-conversion tables.
let case_upper : Array[Byte] = Array::make(256, byte_of(0))

///|
let case_lower : Array[Byte] = Array::make(256, byte_of(0))

///|
let case_built_gen : Ref[Int] = Ref(-1)

///|
fn build_case_tables() -> Unit {
  for c in 0..<256 {
    case_upper[c] = @host.lua_mbt_toupper32(c).to_byte()
    case_lower[c] = @host.lua_mbt_tolower32(c).to_byte()
  }
  case_built_gen.val = locale_generation.val
}

///|
pub fn toupper_byte(c : Int) -> Byte {
  if case_built_gen.val != locale_generation.val {
    build_case_tables()
  }
  case_upper[c]
}

///|
pub fn tolower_byte(c : Int) -> Byte {
  if case_built_gen.val != locale_generation.val {
    build_case_tables()
  }
  case_lower[c]
}
