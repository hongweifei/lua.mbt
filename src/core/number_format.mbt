// Writing numbers as text.

///|
/// Decimal representation of an integer.  Handled here rather than through the
/// host so that the minimum 64 bit value, whose magnitude does not fit in an
/// `Int64`, needs no special casing at the call site.
pub fn int64_to_bytes(v : Int64) -> Bytes {
  if v == 0L {
    return bytes_of("0")
  }
  let neg = v < 0L
  let mut u : UInt64 = if neg {
    0UL - v.reinterpret_as_uint64()
  } else {
    v.reinterpret_as_uint64()
  }
  let buf = Buffer::Buffer(size_hint=20)
  let digits = Buffer::Buffer(size_hint=20)
  while u > 0UL {
    digits.write_byte((48 + (u % 10UL).to_int()).to_byte())
    u = u / 10UL
  }
  if neg {
    buf.write_byte(byte_of(45))
  }
  let rev = digits.to_bytes()
  let mut i = rev.length()
  while i > 0 {
    i = i - 1
    buf.write_byte(rev.at(i))
  }
  buf.to_bytes()
}

///|
/// Formats a float the way the reference implementation does: `%.14g`, with
/// `.0` appended when the result would otherwise read as an integer.
pub fn double_to_g14(d : Double) -> Bytes {
  // The spelling a host printf uses for the special values differs between C
  // libraries, so they are named here.  This is the form the language documents.
  if d.is_nan() {
    return bytes_of("nan")
  }
  if d.is_pos_inf() {
    return bytes_of("inf")
  }
  if d.is_neg_inf() {
    return bytes_of("-inf")
  }
  let text = format_with_double(d, bytes_of("%.14g"))
  if looks_like_integer_text(text) {
    bytes_concat([text, bytes_of(".0")])
  } else {
    text
  }
}

///|
/// True when every byte is a digit or a sign, i.e. the text would be taken for
/// an integer.
pub fn looks_like_integer_text(b : Bytes) -> Bool {
  if b.length() == 0 {
    return false
  }
  let mut i = 0
  while i < b.length() {
    let c = ubyte_at(b, i)
    if !(is_digit_byte(c) || c == 45) {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Runs the host formatter, growing the buffer once if the host reports that
/// the output did not fit.
pub fn format_with_double(v : Double, fmt : Bytes) -> Bytes {
  let buf = Bytes::new(128)
  let n = @host.lua_mbt_fmt_double(buf, 128, fmt, v)
  if n < 0 || n >= 128 {
    let big = Bytes::new(1024)
    let m = @host.lua_mbt_fmt_double(big, 1024, fmt, v)
    if m < 0 {
      return Bytes::new(0)
    }
    return bytes_slice(big, 0, m)
  }
  bytes_slice(buf, 0, n)
}

///|
/// Runs the host formatter for a 64 bit integer.
pub fn format_with_int64(v : Int64, fmt : Bytes) -> Bytes {
  let buf = Bytes::new(128)
  let n = @host.lua_mbt_fmt_int64(buf, 128, fmt, v)
  if n < 0 || n >= 128 {
    let big = Bytes::new(1024)
    let m = @host.lua_mbt_fmt_int64(big, 1024, fmt, v)
    if m < 0 {
      return Bytes::new(0)
    }
    return bytes_slice(big, 0, m)
  }
  bytes_slice(buf, 0, n)
}

///|
/// The default textual form of a number, used by `tostring` and `print`.
pub fn number_to_bytes(v : Value) -> Bytes {
  match v {
    VInt(i) => int64_to_bytes(i)
    VNum(d) => double_to_g14(d)
    _ => bytes_of("?")
  }
}

///|
/// Runs the host formatter for an unsigned 64 bit integer.
pub fn format_with_uint64(v : UInt64, fmt : Bytes) -> Bytes {
  let buf = Bytes::new(128)
  let n = @host.lua_mbt_fmt_uint64(buf, 128, fmt, v)
  if n < 0 || n >= 128 {
    let big = Bytes::new(1024)
    let m = @host.lua_mbt_fmt_uint64(big, 1024, fmt, v)
    if m < 0 {
      return Bytes::new(0)
    }
    return bytes_slice(big, 0, m)
  }
  bytes_slice(buf, 0, n)
}

///|
/// Runs the host formatter for a machine sized integer, used by `%c`.
pub fn format_with_int(v : Int, fmt : Bytes) -> Bytes {
  let buf = Bytes::new(128)
  let n = @host.lua_mbt_fmt_int(buf, 128, fmt, v)
  if n < 0 || n >= 128 {
    let big = Bytes::new(1024)
    let m = @host.lua_mbt_fmt_int(big, 1024, fmt, v)
    if m < 0 {
      return Bytes::new(0)
    }
    return bytes_slice(big, 0, m)
  }
  bytes_slice(buf, 0, n)
}

///|
/// Runs the host formatter for a NUL terminated C string.
pub fn format_with_cstr(v : Bytes, fmt : Bytes) -> Bytes {
  let buf = Bytes::new(256)
  let n = @host.lua_mbt_fmt_cstr(buf, 256, fmt, v)
  if n < 0 || n >= 256 {
    let big = Bytes::new(4096)
    let m = @host.lua_mbt_fmt_cstr(big, 4096, fmt, v)
    if m < 0 {
      return Bytes::new(0)
    }
    return bytes_slice(big, 0, m)
  }
  bytes_slice(buf, 0, n)
}
