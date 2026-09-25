// print, type, tostring and tonumber.

///|
/// Writes the display form of every argument to standard output, separated by
/// tabs and terminated by a newline, exactly like the reference implementation.
pub fn base_print(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let parts : Array[Bytes] = []
  let mut i = 0
  while i < args.length() {
    if i > 0 {
      parts.push(@core.bytes_of("\t"))
    }
    parts.push(@vm.to_string(state, args[i]))
    i = i + 1
  }
  parts.push(@core.bytes_of("\n"))
  @core.write_stdout(@core.bytes_concat(parts))
  @core.flush_stdout()
  @core.Nothing
}

///|
pub fn base_type(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "type")
  @core.One(@core.VStr(@core.LStr::of_string(v.type_name())))
}

///|
pub fn base_tostring(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "tostring")
  @core.One(@core.VStr(@core.LStr::of_bytes(@vm.to_string(state, v))))
}

///|
/// Converts text to a number, optionally in a given base.
pub fn base_tonumber(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let _ = upvals
  if args.length() < 2 || args[1].is_nil() {
    let v = @core.check_any(state, args, 1, "tonumber")
    match v {
      @core.VInt(_) | @core.VNum(_) => return @core.One(v)
      @core.VStr(s) =>
        match @core.lua_str2num(s.data()) {
          Some(@core.NInt(i)) => return @core.One(@core.VInt(i))
          Some(@core.NFloat(d)) => return @core.One(@core.VNum(d))
          None => return @core.One(@core.VNil)
        }
      _ => {
        let _ = @core.check_any(state, args, 1, "tonumber")
        return @core.One(@core.VNil)
      }
    }
  }
  let text = match @core.check_any(state, args, 1, "tonumber") {
    @core.VStr(s) => s
    v =>
      if v.is_number() {
        let _ : Unit = @core.arg_error(
          state, 1, "tonumber", "string expected, got number",
        )
        @core.LStr::empty()
      } else {
        let _ : Unit = @core.arg_error(
          state,
          1,
          "tonumber",
          "string expected, got " + @core.type_error_name(state, v),
        )
        @core.LStr::empty()
      }
  }
  let base = @core.check_int(state, args, 2, "tonumber")
  if base < 2L || base > 36L {
    @core.arg_error(state, 2, "tonumber", "base out of range")
  }
  match str_to_int_base(text.data(), base.to_int()) {
    Some(n) => @core.One(@core.VInt(n))
    None => @core.One(@core.VNil)
  }
}

///|
/// Parses an integer in an arbitrary base, the way `strtol` with a base does:
/// surrounding spaces, an optional sign and digits of the base.  Overflow wraps
/// around modulo 2^64.
pub fn str_to_int_base(s : Bytes, base : Int) -> Int64? {
  let n = s.length()
  let mut i = 0
  while i < n && @core.is_space_byte(@core.ubyte_at(s, i)) {
    i = i + 1
  }
  let mut neg = false
  if i < n && (@core.ubyte_at(s, i) == 45 || @core.ubyte_at(s, i) == 43) {
    neg = @core.ubyte_at(s, i) == 45
    i = i + 1
  }
  let start = i
  let mut acc : UInt64 = 0UL
  while i < n {
    let c = @core.ubyte_at(s, i)
    let d = if @core.is_digit_byte(c) {
      c - 48
    } else if @core.is_alpha_byte(c) {
      let lower = if c >= 65 && c <= 90 { c + 32 } else { c }
      lower - 97 + 10
    } else {
      -1
    }
    if d < 0 || d >= base {
      break
    }
    acc = acc * base.to_uint64() + d.to_uint64()
    i = i + 1
  }
  if i == start {
    return None
  }
  while i < n && @core.is_space_byte(@core.ubyte_at(s, i)) {
    i = i + 1
  }
  if i != n {
    return None
  }
  let magnitude = if neg { 0UL - acc } else { acc }
  Some(magnitude.reinterpret_as_int64())
}
