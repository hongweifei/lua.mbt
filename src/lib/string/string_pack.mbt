// Binary packing.

///|
/// The kind of a format option.
pub const PK_INT : Int = 0

///|
pub const PK_UINT : Int = 1

///|
pub const PK_FLOAT : Int = 2

///|
pub const PK_CHAR : Int = 3

///|
pub const PK_STRING : Int = 4

///|
pub const PK_ZSTR : Int = 5

///|
pub const PK_PAD : Int = 6

///|
pub const PK_PADDING : Int = 7

///|
pub const PK_NOP : Int = 8

///|
pub const PK_MAX_ALIGN : Int = 8

///|
/// Largest size a format can ask for; it matches the string size limit.
pub const PK_MAXSIZE : Int = 0x7fff_ffff

///|
/// A parsed option.
pub(all) struct PackOption {
  kind : Int
  size : Int
}

///|
/// The state a format string describes.
pub(all) struct PackHeader {
  mut little : Bool
  mut max_align : Int
}

///|
pub fn pack_header() -> PackHeader {
  // Fields are packed tightly until '!' asks for an alignment.
  { little: true, max_align: 1, }
}

///|
/// Reads `[0-9]` after an option, defaulting to `dflt`.
pub fn pack_getnum(fmt : Bytes, pos : Int, dflt : Int) -> (Int, Int) {
  if pos >= fmt.length() || !@core.is_digit_byte(@core.ubyte_at(fmt, pos)) {
    return (dflt, pos)
  }
  let mut v = 0
  let mut i = pos
  while true {
    v = v * 10 + (@core.ubyte_at(fmt, i) - 48)
    i = i + 1
    // Stop as soon as the value passes what a size can hold, leaving the rest
    // of the digits for the next option to reject: an over-long size is
    // reported as an invalid format rather than silently wrapped.
    let limit = (PK_MAXSIZE - 9) / 10
    let more = i < fmt.length() &&
      @core.is_digit_byte(@core.ubyte_at(fmt, i)) &&
      v <= limit
    if !more {
      break
    }
  }
  (v, i)
}

///|
/// Reads a size that must be present and within `limit`.
pub fn pack_getnumlimit(
  state : @core.LuaState,
  fmt : Bytes,
  pos : Int,
  dflt : Int,
  limit : Int,
) -> (Int, Int) raise @core.LuaRaised {
  let (size, next) = pack_getnum(fmt, pos, dflt)
  if size <= 0 || size > limit {
    @core.runtime_error(
      state,
      "integral size (" +
      size.to_string() +
      ") out of limits [1," +
      limit.to_string() +
      "]",
    )
  }
  (size, next)
}

///|
/// Parses one option, advancing the header when it is a mode switch.
pub fn pack_getoption(
  state : @core.LuaState,
  hdr : PackHeader,
  fmt : Bytes,
  pos : Int,
) -> (PackOption, Int) raise @core.LuaRaised {
  let _ = state
  let c = @core.ubyte_at(fmt, pos)
  let i = pos + 1
  match c {
    98 => ({ kind: PK_INT, size: 1, }, i)
    66 => ({ kind: PK_UINT, size: 1, }, i)
    104 => ({ kind: PK_INT, size: 2, }, i)
    72 => ({ kind: PK_UINT, size: 2, }, i)
    108 => ({ kind: PK_INT, size: 8, }, i)
    76 => ({ kind: PK_UINT, size: 8, }, i)
    106 => ({ kind: PK_INT, size: 8, }, i)
    74 => ({ kind: PK_UINT, size: 8, }, i)
    84 => ({ kind: PK_UINT, size: 8, }, i)
    102 => ({ kind: PK_FLOAT, size: 4, }, i)
    100 => ({ kind: PK_FLOAT, size: 8, }, i)
    110 => ({ kind: PK_FLOAT, size: 8, }, i)
    105 => {
      let (size, next) = pack_getnumlimit(state, fmt, i, 8, 16)
      ({ kind: PK_INT, size, }, next)
    }
    73 => {
      let (size, next) = pack_getnumlimit(state, fmt, i, 8, 16)
      ({ kind: PK_UINT, size, }, next)
    }
    115 => {
      let (size, next) = pack_getnumlimit(state, fmt, i, 8, 16)
      ({ kind: PK_STRING, size, }, next)
    }
    99 => {
      let (size, next) = pack_getnum(fmt, i, -1)
      if size == -1 {
        @core.runtime_error(state, "missing size for format option 'c'")
      }
      ({ kind: PK_CHAR, size, }, next)
    }
    122 => ({ kind: PK_ZSTR, size: 0, }, i)
    120 => ({ kind: PK_PAD, size: 1, }, i)
    88 => ({ kind: PK_PADDING, size: 0, }, i)
    32 => ({ kind: PK_NOP, size: 0, }, i)
    60 => {
      hdr.little = true
      ({ kind: PK_NOP, size: 0, }, i)
    }
    62 => {
      hdr.little = false
      ({ kind: PK_NOP, size: 0, }, i)
    }
    61 => {
      hdr.little = true
      ({ kind: PK_NOP, size: 0, }, i)
    }
    33 => {
      let (size, next) = pack_getnumlimit(state, fmt, i, PK_MAX_ALIGN, 16)
      hdr.max_align = size
      ({ kind: PK_NOP, size: 0, }, next)
    }
    _ => {
      let ch = unsafe_char_text(c)
      @core.runtime_error(state, "invalid format option '" + ch + "'")
    }
  }
}

///|
/// The alignment and padding needed before placing a field of `size` bytes at
/// offset `total` in a block.
pub fn pack_align(
  state : @core.LuaState,
  fname : String,
  hdr : PackHeader,
  size : Int,
  total : Int,
) -> Int raise @core.LuaRaised {
  if size <= 1 {
    return 0
  }
  let align = if size > hdr.max_align { hdr.max_align } else { size }
  if (align & (align - 1)) != 0 {
    @core.arg_error(state, 1, fname, "format asks for alignment not power of 2")
  }
  let rem = total % align
  if rem == 0 {
    0
  } else {
    align - rem
  }
}

///|----------------------------------------------------------------
/// Packing

///|----------------------------------------------------------------

///|
/// Writes an integer in the requested size and byte order.
pub fn put_packed_int(
  buf : Buffer,
  value : UInt64,
  size : Int,
  little : Bool,
  negative : Bool,
) -> Unit {
  let bytes = Array::make(size, 0)
  let mut n = value
  let mut i = 0
  while i < size {
    let b = (n % 256UL).to_int()
    bytes[if little { i } else { size - 1 - i }] = b
    n = n / 256UL
    i = i + 1
  }
  if negative {
    let mut j = 8
    while j < size {
      bytes[if little { j } else { size - 1 - j }] = 255
      j = j + 1
    }
  }
  for b in bytes {
    buf.write_byte(b.to_byte())
  }
}

///|
pub fn put_packed_float(
  buf : Buffer,
  v : Double,
  size : Int,
  little : Bool,
) -> Unit {
  if size == 4 {
    let f : Float = Float::from_double(v)
    let bits = f.reinterpret_as_uint()
    put_packed_int(buf, bits.to_uint64(), 4, little, false)
  } else {
    let bits = v.reinterpret_as_uint64()
    put_packed_int(buf, bits, 8, little, false)
  }
}

///|
/// `string.pack`.
pub fn str_pack(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let fmt = @core.check_str(state, args, 1, "pack").data()
  let hdr = pack_header()
  let buf = Buffer::Buffer(size_hint=32)
  let mut total = 0
  let mut pos = 0
  let mut argi = 1
  while pos < fmt.length() {
    let prev = pos
    let (opt, next) = pack_getoption(state, hdr, fmt, pos)
    pos = next
    if opt.kind == PK_NOP {
      continue
    }
    if opt.kind == PK_PADDING {
      // 'X' takes its alignment from the next option and consumes it.
      let (nopt, nnext) = if pos >= fmt.length() {
        ({ kind: PK_NOP, size: 0, }, pos)
      } else {
        pack_getoption(state, hdr, fmt, pos)
      }
      if nnext == pos || nopt.kind == PK_CHAR || nopt.size == 0 {
        @core.arg_error(state, 1, "pack", "invalid next option for option 'X'")
      }
      pos = nnext
      let pad = pack_align(state, "pack", hdr, nopt.size, total)
      let mut i = 0
      while i < pad {
        buf.write_byte(@core.byte_of(0))
        i = i + 1
      }
      total = total + pad
      continue
    }
    let pad = pack_align(
      state,
      "pack",
      hdr,
      if opt.kind == PK_CHAR {
        0
      } else {
        opt.size
      },
      total,
    )
    let mut i = 0
    while i < pad {
      buf.write_byte(@core.byte_of(0))
      i = i + 1
    }
    total = total + pad
    if opt.kind == PK_PAD {
      buf.write_byte(@core.byte_of(0))
      total = total + 1
      continue
    }
    argi = argi + 1
    if argi > args.length() {
      // The reference pushes a nil marker after the arguments, to separate them
      // from its result buffer, so the value a format asks for when none was
      // given reads as nil: `string.pack("i4")` says `number expected, got
      // nil`, not `got no value`.
      let expected = match opt.kind {
        PK_INT | PK_FLOAT => "number"
        _ => "string"
      }
      @core.arg_error(state, argi, "pack", expected + " expected, got nil")
    }
    match opt.kind {
      PK_INT => {
        let v = @core.check_int(state, args, argi, "pack")
        if opt.size < 8 {
          // A field narrower than a lua_Integer must hold the whole value.
          let lim = 1L << (opt.size * 8 - 1)
          if v < -lim || v >= lim {
            @core.arg_error(state, argi, "pack", "integer overflow")
          }
        }
        put_packed_int(
          buf,
          v.reinterpret_as_uint64(),
          opt.size,
          hdr.little,
          v < 0L,
        )
        total = total + opt.size
      }
      PK_UINT => {
        let v = @core.check_int(state, args, argi, "pack")
        if opt.size < 8 {
          // Read as unsigned, a negative value is far above the field's range.
          let lim = 1UL << (opt.size * 8)
          if v.reinterpret_as_uint64() >= lim {
            @core.arg_error(state, argi, "pack", "unsigned overflow")
          }
        }
        put_packed_int(
          buf,
          v.reinterpret_as_uint64(),
          opt.size,
          hdr.little,
          false,
        )
        total = total + opt.size
      }
      PK_FLOAT => {
        let v = @core.check_number(state, args, argi, "pack")
        put_packed_float(buf, v, opt.size, hdr.little)
        total = total + opt.size
      }
      PK_CHAR => {
        let s = @core.check_str(state, args, argi, "pack").data()
        if s.length() > opt.size {
          @core.arg_error(state, argi, "pack", "string longer than given size")
        }
        buf.write_bytes(s.view())
        total = total + s.length()
        let mut k = s.length()
        while k < opt.size {
          buf.write_byte(@core.byte_of(0))
          k = k + 1
        }
        total = total + (opt.size - s.length())
      }
      PK_STRING => {
        let s = @core.check_str(state, args, argi, "pack").data()
        if opt.size < 8 {
          let lim = 1UL << (opt.size * 8)
          if s.length().to_uint64() >= lim {
            @core.arg_error(
              state, argi, "pack", "string length does not fit in given size",
            )
          }
        }
        put_packed_int(buf, s.length().to_uint64(), opt.size, hdr.little, false)
        buf.write_bytes(s.view())
        total = total + opt.size + s.length()
      }
      PK_ZSTR => {
        let s = @core.check_str(state, args, argi, "pack").data()
        if s.length() != c_string_length(s) {
          @core.arg_error(state, argi, "pack", "string contains zeros")
        }
        buf.write_bytes(s.view())
        buf.write_byte(@core.byte_of(0))
        total = total + s.length() + 1
      }
      _ => {
        let _ = prev
        @core.runtime_error(state, "invalid format option")
      }
    }
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|----------------------------------------------------------------
/// Unpacking

///|----------------------------------------------------------------
