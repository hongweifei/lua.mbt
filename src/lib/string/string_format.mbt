// string.format.

///|
/// The flags each conversion accepts and whether it takes a precision,
/// mirroring the `L_FMTFLAGS*` sets of the reference.
fn format_flags(conv : Int) -> (Bytes, Bool) {
  match conv {
    99 => (b"-", false) // 'c'
    100 | 105 => (b"-+0 ", true) // 'd', 'i'
    117 => (b"-0", true) // 'u'
    111 | 120 | 88 => (b"-#0", true) // 'o', 'x', 'X'
    97 | 65 | 101 | 69 | 102 | 70 | 103 | 71 => (b"-+#0 ", true)
    112 => (b"-", false) // 'p'
    115 => (b"-", true) // 's'
    _ => (b"", false)
  }
}

///|
/// The characters `getformat` spans while collecting a specification.
fn is_spec_char(c : Int) -> Bool {
  c == 45 ||
  c == 43 ||
  c == 35 ||
  c == 48 ||
  c == 32 ||
  c == 46 ||
  (c >= 49 && c <= 57)
}

///|
/// Skips up to two decimal digits, as `get2digits` does.
fn get2digits(f : Bytes, i : Int) -> Int {
  let mut k = i
  if k < f.length() && @core.is_digit_byte(@core.ubyte_at(f, k)) {
    k = k + 1
    if k < f.length() && @core.is_digit_byte(@core.ubyte_at(f, k)) {
      k = k + 1
    }
  }
  k
}

///|
/// Validates the collected specification against what the conversion
/// accepts, raising the reference's
/// `invalid conversion specification: '<form>'` otherwise.
fn check_format(
  state : @core.LuaState,
  f : Bytes,
  spec_start : Int,
  conv_at : Int,
  conv : Int,
) -> Unit raise @core.LuaRaised {
  let (flags, prec) = format_flags(conv)
  let mut k = spec_start + 1
  while k < conv_at &&
        @core.ubyte_at(flags, find_flag(flags, @core.ubyte_at(f, k))) >= 0 {
    k = k + 1
  }
  // The remainder must not begin with a zero width unless the flag set
  // already consumed it.
  if k >= conv_at || @core.ubyte_at(f, k) != 48 {
    k = get2digits(f, k)
    if prec && k < conv_at && @core.ubyte_at(f, k) == 46 {
      k = k + 1
      k = get2digits(f, k)
    }
  }
  if k != conv_at || conv < 0 || !@core.is_alpha_byte(conv) {
    let form = @core.bytes_slice(f, spec_start, conv_at - spec_start + 1)
    @core.runtime_error(
      state,
      "invalid conversion specification: '" + @core.text_of(form) + "'",
    )
  }
}

///|
fn find_flag(flags : Bytes, c : Int) -> Int {
  let mut i = 0
  while i < flags.length() {
    if @core.ubyte_at(flags, i) == c {
      return i
    }
    i = i + 1
  }
  -1
}

///|
pub fn str_format(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let fmt = @core.check_str(state, args, 1, "format")
  let f = fmt.data()
  let buf = Buffer::Buffer(size_hint=f.length())
  let mut argi = 1
  let mut i = 0
  while i < f.length() {
    let c = @core.ubyte_at(f, i)
    if c != 37 {
      buf.write_byte(f.at(i))
      i = i + 1
      continue
    }
    i = i + 1
    if i < f.length() && @core.ubyte_at(f, i) == 37 {
      buf.write_byte(@core.byte_of(37))
      i = i + 1
      continue
    }
    argi = argi + 1
    if argi > args.length() {
      @core.arg_error(state, argi, "format", "no value")
    }
    let spec_start = i - 1
    // `getformat`: span flags, width and precision, then the specifier.
    let mut j = i
    while j < f.length() && is_spec_char(@core.ubyte_at(f, j)) {
      j = j + 1
    }
    if j - i >= 20 {
      @core.runtime_error(state, "invalid format (too long)")
    }
    let conv = if j < f.length() { @core.ubyte_at(f, j) } else { -1 }
    i = j + 1
    let head = @core.bytes_slice(
      f,
      spec_start,
      (if j < f.length() { j } else { f.length() - 1 }) - spec_start + 1,
    )
    // Conversions validated by `checkformat`.
    match conv {
      99
      | 100
      | 105
      | 117
      | 111
      | 120
      | 88
      | 97
      | 65
      | 101
      | 69
      | 102
      | 103
      | 71
      | 112 => check_format(state, f, spec_start, j, conv)
      _ => ()
    }
    match conv {
      99 => {
        // %c takes an int.
        let v = @core.check_int(state, args, argi, "format")
        buf.write_bytes(host_format_int(v.to_int(), head, conv))
      }
      100 | 105 => {
        let v = @core.check_int(state, args, argi, "format")
        buf.write_bytes(host_format_int64(v, head, conv))
      }
      117 | 111 | 120 | 88 => {
        let v = @core.check_int(state, args, argi, "format")
        buf.write_bytes(
          host_format_uint64(v.reinterpret_as_uint64(), head, conv),
        )
      }
      97 | 65 | 101 | 69 | 102 | 103 | 71 => {
        let v = @core.check_number(state, args, argi, "format")
        let out = host_format_double(v, head, conv)
        // Hexadecimal spellings always use a dot, whatever the locale; the
        // reference replaces the locale mark in `%a` output.
        if conv == 97 || conv == 65 {
          buf.write_bytes(force_dot(out).view())
        } else {
          buf.write_bytes(out.view())
        }
      }
      115 => {
        let v = @core.check_any(state, args, argi, "format")
        let s = @vm.to_string(state, v)
        if head.length() == 2 {
          buf.write_bytes(s.view())
        } else {
          if s.length() != c_string_length(s) {
            @core.arg_error(state, argi, "format", "string contains zeros")
          }
          check_format(state, f, spec_start, j, conv)
          if !bytes_contains(head, 46) && s.length() >= 100 {
            // No precision and the string is too long for the buffer.
            buf.write_bytes(s.view())
          } else {
            buf.write_bytes(host_format_str(s, head, conv))
          }
        }
      }
      113 => {
        if head.length() > 2 {
          @core.runtime_error(state, "specifier '%q' cannot have modifiers")
        }
        let v = @core.check_any(state, args, argi, "format")
        append_quoted(state, buf, v, argi)
      }
      112 => {
        // '%p' of a non-pointer value prints "(null)"; pointers are rendered
        // from text, so the conversion is formatted as a string.
        let v = @core.check_any(state, args, argi, "format")
        let ptr = match v {
          @core.VNil | @core.VBool(_) | @core.VInt(_) | @core.VNum(_) =>
            @core.bytes_of("(null)")
          _ => @core.bytes_of(@vm.object_address(v))
        }
        let shead = @core.bytes_concat([
          @core.bytes_slice(head, 0, head.length() - 1),
          @core.bytes_of("s"),
        ])
        buf.write_bytes(host_format_str(ptr, shead, 115))
      }
      _ =>
        @core.runtime_error(
          state,
          "invalid conversion '" + @core.text_of(head) + "' to 'format'",
        )
    }
  }
  @core.One(@core.VStr(@core.LStr::of_bytes(buf.to_bytes())))
}

///|
fn bytes_contains(b : Bytes, c : Int) -> Bool {
  let mut i = 0
  while i < b.length() {
    if @core.ubyte_at(b, i) == c {
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Replaces the locale's decimal mark with a dot.
fn force_dot(b : Bytes) -> Bytes {
  let dp = @core.locale_decpoint()
  if dp == 46 || !bytes_contains(b, dp) {
    return b
  }
  let arr = b.to_array()
  for i, x in arr {
    if x == dp.to_byte() {
      arr[i] = @core.byte_of(46)
    }
  }
  Bytes::from_array(arr[:])
}

///|
/// The length of a C string, i.e. the position of the first zero byte.
pub fn c_string_length(b : Bytes) -> Int {
  let mut i = 0
  while i < b.length() {
    if @core.ubyte_at(b, i) == 0 {
      return i
    }
    i = i + 1
  }
  b.length()
}

///|
pub fn unsafe_char_text(c : Int) -> String {
  let buf = Buffer::Buffer(size_hint=1)
  buf.write_byte(c.to_byte())
  @core.text_of(buf.to_bytes())
}

///|
/// Builds the host format string by inserting the length modifier the
/// conversion needs.
pub fn with_length_modifier(head : Bytes, modulo : Bytes) -> Bytes {
  if head.length() == 0 {
    return modulo
  }
  @core.bytes_concat([
    @core.bytes_slice(head, 0, head.length() - 1),
    modulo,
    @core.bytes_slice(head, head.length() - 1, 1),
  ])
}

///|
pub fn host_format_int64(v : Int64, head : Bytes, conv : Int) -> Bytes {
  let _ = conv
  @core.format_with_int64(v, with_length_modifier(head, @core.bytes_of("ll")))
}

///|
pub fn host_format_uint64(v : UInt64, head : Bytes, conv : Int) -> Bytes {
  let _ = conv
  @core.format_with_uint64(v, with_length_modifier(head, @core.bytes_of("ll")))
}

///|
pub fn host_format_double(v : Double, head : Bytes, conv : Int) -> Bytes {
  let _ = conv
  @core.format_with_double(v, head)
}

///|
pub fn host_format_int(v : Int, head : Bytes, conv : Int) -> Bytes {
  let _ = conv
  @core.format_with_int(v, head)
}

///|
pub fn host_format_str(v : Bytes, head : Bytes, conv : Int) -> Bytes {
  let _ = conv
  @core.format_with_cstr(v, head)
}

///|
/// Appends a string in the form `%q` produces.  `argi` is the argument being
/// formatted, which the reference names when the value has no literal form
/// (`addliteral`'s `luaL_argerror`).
pub fn append_quoted(
  state : @core.LuaState,
  buf : Buffer,
  v : @core.Value,
  argi : Int,
) -> Unit raise @core.LuaRaised {
  match v {
    @core.VStr(s) => {
      buf.write_byte(@core.byte_of(34))
      let d = s.data()
      let mut i = 0
      while i < d.length() {
        let c = @core.ubyte_at(d, i)
        if c == 34 || c == 92 || c == 10 {
          buf.write_byte(@core.byte_of(92))
          buf.write_byte(c.to_byte())
        } else if @pattern.is_cntrl_c(c) {
          let next = if i + 1 < d.length() {
            @core.ubyte_at(d, i + 1)
          } else {
            -1
          }
          let text = if !@core.is_digit_byte(next) {
            "\\" + c.to_string()
          } else {
            "\\" + pad3(c)
          }
          buf.write_bytes(@core.bytes_of(text).view())
        } else if c == 13 {
          buf.write_bytes(@core.bytes_of("\\r").view())
        } else {
          buf.write_byte(d.at(i))
        }
        i = i + 1
      }
      buf.write_byte(@core.byte_of(34))
    }
    @core.VInt(i) =>
      // As in `quotefloat`: the minimum integer has no decimal literal, so it
      // is spelled in hexadecimal.
      if i.reinterpret_as_uint64() == 0x8000_0000_0000_0000UL {
        buf.write_bytes(@core.bytes_of("0x8000000000000000").view())
      } else {
        buf.write_bytes(@vm.to_string(state, v).view())
      }
    @core.VNum(d) => buf.write_bytes(quote_float(d).view())
    @core.VNil | @core.VBool(_) =>
      buf.write_bytes(@vm.to_string(state, v).view())
    _ => @core.arg_error(state, argi, "format", "value has no literal form")
  }
}

///|
/// The literal form of a float for `%q`: hexadecimal, so that it round trips,
/// with the dot forced as the radix mark even under locales that use a comma,
/// mirroring `quotefloat`.
pub fn quote_float(d : Double) -> Bytes {
  if d.is_nan() {
    return @core.bytes_of("(0/0)")
  }
  if d.is_pos_inf() {
    return @core.bytes_of("1e9999")
  }
  if d.is_neg_inf() {
    return @core.bytes_of("-1e9999")
  }
  let raw = @core.format_with_double(d, @core.bytes_of("%a"))
  let dp = @core.locale_decpoint()
  if dp != 46 {
    let arr = raw.to_array()
    for i, b in arr {
      if b == dp.to_byte() {
        arr[i] = @core.byte_of(46)
        break
      }
    }
    return Bytes::from_array(arr[:])
  }
  raw
}

///|
pub fn pad3(v : Int) -> String {
  if v < 10 {
    "00" + v.to_string()
  } else if v < 100 {
    "0" + v.to_string()
  } else {
    v.to_string()
  }
}

///|----------------------------------------------------------------
/// Installation

///|----------------------------------------------------------------
