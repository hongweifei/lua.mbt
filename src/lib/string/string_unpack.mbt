// Binary unpacking.

///|
/// Reads an integer of `size` bytes.
pub fn get_packed_int(
  state : @core.LuaState,
  data : Bytes,
  pos : Int,
  size : Int,
  little : Bool,
  signed : Bool,
) -> Int64 raise @core.LuaRaised {
  if pos + size > data.length() {
    @core.arg_error(state, 2, "unpack", "data string too short")
  }
  // Mirror `unpackint`: only the low eight bytes become the result; when the
  // field is wider, the unread bytes must be pure sign extension or overflow.
  let limit = if size <= 8 { size } else { 8 }
  let mut acc : UInt64 = 0UL
  let mut i = 0
  while i < limit {
    let idx = if little { pos + limit - 1 - i } else { pos + size - limit + i }
    acc = acc * 256UL + @core.ubyte_at(data, idx).to_uint64()
    i = i + 1
  }
  if signed && size < 8 {
    // Sign extend from the top bit of the stored field.
    let shift = 64 - size * 8
    return (acc << shift).reinterpret_as_int64() >> shift
  }
  let res = acc.reinterpret_as_int64()
  if size > 8 {
    let mask = if !signed || res >= 0L { 0 } else { 0xff }
    let mut j = limit
    while j < size {
      let idx = if little { pos + j } else { pos + size - 1 - j }
      if @core.ubyte_at(data, idx) != mask {
        @core.runtime_error(
          state,
          size.to_string() + "-byte integer does not fit into Lua Integer",
        )
      }
      j = j + 1
    }
  }
  res
}

///|
pub fn get_packed_float(
  state : @core.LuaState,
  data : Bytes,
  pos : Int,
  size : Int,
  little : Bool,
) -> Double raise @core.LuaRaised {
  if pos + size > data.length() {
    @core.arg_error(state, 2, "unpack", "data string too short")
  }
  let mut acc : UInt64 = 0UL
  let mut i = 0
  while i < size {
    let idx = if little { pos + size - 1 - i } else { pos + i }
    acc = acc * 256UL + @core.ubyte_at(data, idx).to_uint64()
    i = i + 1
  }
  if size == 4 {
    Float::reinterpret_from_uint(acc.to_uint()).to_double()
  } else {
    acc.reinterpret_as_double()
  }
}

///|
/// `string.unpack`.
pub fn str_unpack(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let fmt = @core.check_str(state, args, 1, "unpack").data()
  let s = @core.check_str(state, args, 2, "unpack")
  let data = s.data()
  let mut pos = @pattern.pos_relat_init(
    @core.opt_int(state, args, 3, "unpack", 1L),
    data.length(),
  )
  if pos > data.length() {
    @core.arg_error(state, 3, "unpack", "initial position out of string")
  }
  let hdr = pack_header()
  let out : Array[@core.Value] = []
  // `fi` walks the format string; `pos` walks the data (0-based).  They are
  // independent: mixing them up makes every aligned option read from the
  // wrong offset.
  let mut fi = 0
  while fi < fmt.length() {
    let (opt, next) = pack_getoption(state, hdr, fmt, fi)
    fi = next
    if opt.kind == PK_NOP {
      continue
    }
    if opt.kind == PK_PADDING {
      // 'X': align to the next option, which it consumes.
      let (nopt, nnext) = if fi >= fmt.length() {
        ({ kind: PK_NOP, size: 0, }, fi)
      } else {
        pack_getoption(state, hdr, fmt, fi)
      }
      if nnext == fi || nopt.kind == PK_CHAR || nopt.size == 0 {
        @core.arg_error(
          state, 1, "unpack", "invalid next option for option 'X'",
        )
      }
      fi = nnext
      pos = pos + pack_align(state, "unpack", hdr, nopt.size, pos)
      continue
    }
    if opt.kind == PK_PAD {
      pos = pos + 1
      continue
    }
    // Align the read position relative to the start of the data.
    let pad = pack_align(
      state,
      "unpack",
      hdr,
      if opt.kind == PK_CHAR {
        0
      } else {
        opt.size
      },
      pos,
    )
    pos = pos + pad
    if pos > data.length() {
      @core.arg_error(state, 2, "unpack", "data string too short")
    }
    match opt.kind {
      PK_INT => {
        out.push(
          @core.VInt(
            get_packed_int(state, data, pos, opt.size, hdr.little, true),
          ),
        )
        pos = pos + opt.size
      }
      PK_UINT => {
        out.push(
          @core.VInt(
            get_packed_int(state, data, pos, opt.size, hdr.little, false),
          ),
        )
        pos = pos + opt.size
      }
      PK_FLOAT => {
        out.push(
          @core.VNum(get_packed_float(state, data, pos, opt.size, hdr.little)),
        )
        pos = pos + opt.size
      }
      PK_CHAR => {
        if pos + opt.size > data.length() {
          @core.arg_error(state, 2, "unpack", "data string too short")
        }
        out.push(
          @core.VStr(
            @core.LStr::of_bytes(@core.bytes_slice(data, pos, opt.size)),
          ),
        )
        pos = pos + opt.size
      }
      PK_STRING => {
        let len = get_packed_int(state, data, pos, opt.size, hdr.little, false).to_int()
        pos = pos + opt.size
        if len < 0 || pos + len > data.length() {
          @core.arg_error(state, 2, "unpack", "data string too short")
        }
        out.push(
          @core.VStr(@core.LStr::of_bytes(@core.bytes_slice(data, pos, len))),
        )
        pos = pos + len
      }
      PK_ZSTR => {
        let mut len = 0
        while pos + len < data.length() && @core.ubyte_at(data, pos + len) != 0 {
          len = len + 1
        }
        if pos + len >= data.length() {
          @core.arg_error(
            state, 2, "unpack", "unfinished string for format 'z'",
          )
        }
        out.push(
          @core.VStr(@core.LStr::of_bytes(@core.bytes_slice(data, pos, len))),
        )
        pos = pos + len + 1
      }
      _ => @core.runtime_error(state, "invalid format option")
    }
  }
  out.push(@core.VInt((pos + 1).to_int64()))
  @core.Many(out)
}

///|
/// `string.packsize`.
pub fn str_packsize(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let fmt = @core.check_str(state, args, 1, "packsize").data()
  let hdr = pack_header()
  let mut total = 0
  let mut pos = 0
  while pos < fmt.length() {
    let (opt, next) = pack_getoption(state, hdr, fmt, pos)
    pos = next
    if opt.kind == PK_NOP {
      continue
    }
    if opt.kind == PK_PADDING {
      let (nopt, nnext) = if pos >= fmt.length() {
        ({ kind: PK_NOP, size: 0, }, pos)
      } else {
        pack_getoption(state, hdr, fmt, pos)
      }
      if nnext == pos || nopt.kind == PK_CHAR || nopt.size == 0 {
        @core.arg_error(
          state, 1, "packsize", "invalid next option for option 'X'",
        )
      }
      pos = nnext
      total = total + pack_align(state, "packsize", hdr, nopt.size, total)
      continue
    }
    if opt.kind == PK_PAD {
      total = total + 1
      continue
    }
    if opt.kind == PK_STRING || opt.kind == PK_ZSTR {
      @core.arg_error(state, 1, "packsize", "variable-length format")
    }
    total = total +
      pack_align(
        state,
        "packsize",
        hdr,
        if opt.kind == PK_CHAR {
          0
        } else {
          opt.size
        },
        total,
      )
    total = total + opt.size
  }
  @core.One(@core.VInt(total.to_int64()))
}
