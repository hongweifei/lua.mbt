// The straightforward string operations.

///|
pub fn str_len(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "len")
  [@core.VInt(s.length().to_int64())]
}

///|
pub fn str_sub(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "sub")
  let data = s.data()
  let len = data.length()
  // The start is required (`str_sub`: `luaL_checkinteger(L, 2)`); only the end
  // has a default.
  let mut i = @pattern.pos_relat(@core.check_int(state, args, 2, "sub"), len)
  let mut j = @pattern.end_relat(@core.opt_int(state, args, 3, "sub", -1L), len)
  if i < 1 {
    i = 1
  }
  if j > len {
    j = len
  }
  if i > j {
    [@core.VStr(@core.LStr::empty())]
  } else {
    [
      @core.VStr(
        @core.LStr::of_bytes(@core.bytes_slice(data, i - 1, j - i + 1)),
      ),
    ]
  }
}

///|
pub fn str_upper(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "upper")
  let src = s.data()
  let buf = Buffer::Buffer(size_hint=src.length())
  let mut i = 0
  while i < src.length() {
    let c = @core.ubyte_at(src, i)
    buf.write_byte(@core.toupper_byte(c))
    i = i + 1
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
pub fn str_lower(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "lower")
  let src = s.data()
  let buf = Buffer::Buffer(size_hint=src.length())
  let mut i = 0
  while i < src.length() {
    let c = @core.ubyte_at(src, i)
    buf.write_byte(@core.tolower_byte(c))
    i = i + 1
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
pub fn str_rep(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "rep")
  let n = @core.check_int(state, args, 2, "rep")
  let sep = if args.length() >= 3 && !args[2].is_nil() {
    @core.check_str(state, args, 3, "rep").data()
  } else {
    Bytes::new(0)
  }
  if n <= 0L {
    return [@core.VStr(@core.LStr::empty())]
  }
  // `str_rep` refuses results that cannot fit; the divisor form catches
  // overflow without computing the size first.
  let maxsize : Int64 = 0x7fff_ffffL
  let per = s.length() + sep.length()
  if per < s.length() || per.to_int64() > maxsize / n {
    @core.runtime_error(state, "resulting string too large")
  }
  let buf = Buffer::Buffer(size_hint=(s.length() + sep.length()) * n.to_int())
  let mut i = 0L
  while i < n {
    if i > 0L && sep.length() > 0 {
      buf.write_bytes(sep.view())
    }
    buf.write_bytes(s.data().view())
    i = i + 1L
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
pub fn str_reverse(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "reverse")
  let src = s.data()
  let buf = Buffer::Buffer(size_hint=src.length())
  let mut i = src.length()
  while i > 0 {
    i = i - 1
    buf.write_byte(src.at(i))
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
/// The bytes of a string, as `string.byte` reports them.
pub fn str_byte(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "byte")
  let data = s.data()
  let len = data.length()
  let pi = @core.opt_int(state, args, 2, "byte", 1L)
  let mut i = @pattern.pos_relat(pi, len)
  // The end defaults to the *unclamped* start, as `str_byte` does.
  let mut j = @pattern.end_relat(@core.opt_int(state, args, 3, "byte", pi), len)
  if i < 1 {
    i = 1
  }
  if j > len {
    j = len
  }
  let out : Array[@core.Value] = []
  let mut k = i
  while k <= j {
    out.push(@core.VInt(@core.ubyte_at(data, k - 1).to_int64()))
    k = k + 1
  }
  out
}

///|
/// Builds a string from byte values.
pub fn str_char(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let buf = Buffer::Buffer(size_hint=args.length())
  let mut i = 0
  while i < args.length() {
    let c = @core.check_int(state, args, i + 1, "char")
    if c < 0L || c > 255L {
      @core.arg_error(state, i + 1, "char", "value out of range")
    }
    buf.write_byte(c.to_int().to_byte())
    i = i + 1
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
/// Updates one of a native closure's captured values.
pub fn upgrade_upval(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  i : Int,
  v : @core.Value,
) -> Unit {
  let _ = state
  if i < upvals.length() {
    upvals[i] = v
  }
}

///|
/// A parsed conversion specification.
pub(all) struct FormatSpec {
  text : Buffer
  conv : Int
}
