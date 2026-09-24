// Byte oriented helpers.

///|
pub fn bytes_of(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// Decodes bytes as UTF-8, replacing malformed sequences.  Used for
/// diagnostics only; Lua values never round trip through this.
pub fn text_of(b : Bytes) -> String {
  @utf8.decode_lossy(b)
}

///|
/// Copies `len` bytes starting at `start`.  The range must be valid.
pub fn bytes_slice(b : Bytes, start : Int, len : Int) -> Bytes {
  if len <= 0 {
    return Bytes::new(0)
  }
  let buf = Buffer::Buffer(size_hint=len)
  buf.write_bytes(b.view(start~, end=start + len))
  buf.to_bytes()
}

///|
/// Concatenation of any number of byte sequences.
pub fn bytes_concat(parts : Array[Bytes]) -> Bytes {
  let mut total = 0
  for p in parts {
    total = total + p.length()
  }
  let buf = Buffer::Buffer(size_hint=total)
  for p in parts {
    buf.write_bytes(p.view())
  }
  buf.to_bytes()
}

///|
/// Byte at `i` as an unsigned value in 0..255.
pub fn ubyte_at(b : Bytes, i : Int) -> Int {
  match b.get(i) {
    Some(v) => v.to_int()
    None => -1
  }
}

///|
/// A byte from an integer value, for readability where a literal would be
/// ambiguous.
pub fn byte_of(n : Int) -> Byte {
  n.to_byte()
}

///|
/// Builds a one element byte sequence.
pub fn bytes_one(v : Int) -> Bytes {
  let buf = Buffer::Buffer(size_hint=1)
  buf.write_byte(v.to_byte())
  buf.to_bytes()
}

///|
/// Repeats a byte sequence `n` times.
pub fn bytes_repeat(b : Bytes, n : Int) -> Bytes {
  if n <= 0 {
    return Bytes::new(0)
  }
  let buf = Buffer::Buffer(size_hint=b.length() * n)
  let mut i = 0
  while i < n {
    buf.write_bytes(b.view())
    i = i + 1
  }
  buf.to_bytes()
}

///|
/// A pointer as the reference's `%p` prints it on this platform: sixteen
/// lowercase hexadecimal digits with no `0x`.  Objects here have no real
/// address, so their identity number stands in for one -- the shape is what
/// `print` shows either way.
pub fn hex_address(n : Int64) -> String {
  let hexd : Bytes = b"0123456789abcdef"
  let buf = Buffer::Buffer(size_hint=16)
  let mut shift = 60
  while shift >= 0 {
    let nibble = ((n >> shift) & 0xfL).to_int()
    buf.write_byte(hexd.at(nibble))
    shift = shift - 4
  }
  text_of(buf.to_bytes())
}
