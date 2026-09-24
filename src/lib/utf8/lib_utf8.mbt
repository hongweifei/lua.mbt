// The UTF-8 library.

///|
pub let utf8_charpattern : Bytes = b"[\x00-\x7F\xC2-\xFD][\x80-\xBF]*"

///|
/// Decodes one sequence starting at `i`.  Returns the code point and the index
/// just past it, or `None` when the bytes are not a valid sequence.  In strict
/// mode, as in `utf8_decode` with `strict`, code points beyond Unicode or in
/// the surrogate range are also rejected.
pub fn utf8_decode(s : Bytes, i : Int, strict : Bool) -> (Int, Int)? {
  if i >= s.length() {
    return None
  }
  let c = @core.ubyte_at(s, i)
  if c < 0x80 {
    return Some((c, i + 1))
  }
  if c >= 0xfe {
    return None
  }
  // As in the reference, `limits[0]` is the largest unsigned value, so a lead
  // byte that needs no continuation bytes but is not ASCII never decodes.
  let limits = [0x7fffffff, 0x80, 0x800, 0x10000, 0x200000, 0x4000000]
  let mut res = 0
  let mut count = 0
  let mut cc = c
  while (cc & 0x40) != 0 {
    count = count + 1
    if i + count >= s.length() {
      return None
    }
    let next = @core.ubyte_at(s, i + count)
    if (next & 0xc0) != 0x80 {
      return None
    }
    res = (res << 6) | (next & 0x3f)
    cc = cc << 1
  }
  // The first byte contributes its low bits *after* being shifted, exactly as
  // in the reference decoder; using the unshifted byte misreads overlong
  // sequences such as "\xC0\x80".
  res = res | ((cc & 0x7f) << (count * 5))
  if count > 5 || res > 0x7fffffff || res < limits[count] {
    return None
  }
  if strict && (res > 0x10ffff || (res >= 0xd800 && res <= 0xdfff)) {
    return None
  }
  Some((res, i + count + 1))
}

///|
/// Whether the byte is a continuation byte.
pub fn utf8_is_cont(s : Bytes, i : Int) -> Bool {
  if i >= s.length() {
    return false
  }
  (@core.ubyte_at(s, i) & 0xc0) == 0x80
}

///|
/// Encodes one code point.
pub fn utf8_encode(cp : Int, buf : Buffer) -> Unit {
  @compiler.utf8_encode_extended(cp, buf)
}

///|
pub fn utf8_char(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let buf = Buffer::Buffer(size_hint=args.length() * 4)
  let mut i = 0
  while i < args.length() {
    let cp = @core.check_int(state, args, i + 1, "char")
    if cp < 0L || cp > 0x7fffffffL {
      @core.arg_error(state, i + 1, "char", "value out of range")
    }
    utf8_encode(cp.to_int(), buf)
    i = i + 1
  }
  [@core.VStr(@core.LStr::of_bytes(buf.to_bytes()))]
}

///|
/// The position translation of `lutf8lib.c` (`u_posrelat`): negative values
/// count back from the end, and a negative past the start lands at zero, not
/// at one — unlike the string library's `posrelatI`.
fn u_posrelat(pos : Int64, len : Int) -> Int {
  if pos >= 0L {
    pos.to_int()
  } else if 0UL - pos.reinterpret_as_uint64() > len.to_uint64() {
    0
  } else {
    (len.to_int64() + pos + 1L).to_int()
  }
}

///|
pub fn utf8_codepoint(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "codepoint")
  let data = s.data()
  let len = data.length()
  let posi = u_posrelat(@core.opt_int(state, args, 2, "codepoint", 1L), len)
  let pose = u_posrelat(
    @core.opt_int(state, args, 3, "codepoint", posi.to_int64()),
    len,
  )
  let lax = args.length() >= 4 && @core.is_truthy_arg(state, args, 4)
  if posi < 1 {
    @core.arg_error(state, 2, "codepoint", "out of bounds")
  }
  if pose > len {
    @core.arg_error(state, 3, "codepoint", "out of bounds")
  }
  if posi > pose {
    return []
  }
  let out : Array[@core.Value] = []
  let mut i = posi - 1
  while i < pose {
    match utf8_decode(data, i, !lax) {
      Some((cp, next)) => {
        out.push(@core.VInt(cp.to_int64()))
        i = next
      }
      None => @core.runtime_error(state, "invalid UTF-8 code")
    }
  }
  out
}

///|
pub fn utf8_len(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // A number is coerced to its text and a missing argument is reported as a
  // missing string (`luaL_checklstring`).
  let data = @core.check_str(state, args, 1, "len").data()
  let len = data.length()
  let mut posi = u_posrelat(@core.opt_int(state, args, 2, "len", 1L), len)
  let mut posj = u_posrelat(@core.opt_int(state, args, 3, "len", -1L), len)
  let lax = args.length() >= 4 && @core.is_truthy_arg(state, args, 4)
  // `1 <= posi && --posi <= len` and `--posj < len` from `utflen`.
  if posi < 1 || posi - 1 > len {
    @core.arg_error(state, 2, "len", "initial position out of bounds")
  }
  if posj - 1 >= len {
    @core.arg_error(state, 3, "len", "final position out of bounds")
  }
  posi = posi - 1
  posj = posj - 1
  let mut n = 0L
  while posi <= posj {
    match utf8_decode(data, posi, !lax) {
      Some((_, next)) => {
        n = n + 1L
        posi = next
      }
      None => return [@core.VNil, @core.VInt((posi + 1).to_int64())]
    }
  }
  [@core.VInt(n)]
}

///|
pub fn utf8_offset(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let s = @core.check_str(state, args, 1, "offset")
  let data = s.data()
  let len = data.length()
  let n = @core.check_int(state, args, 2, "offset")
  let dflt = if n >= 0L { 1L } else { (len + 1).to_int64() }
  let mut posi = u_posrelat(@core.opt_int(state, args, 3, "offset", dflt), len)
  // `1 <= posi && --posi <= len` from `byteoffset`.
  if posi < 1 || posi - 1 > len {
    @core.arg_error(state, 3, "offset", "position out of bounds")
  }
  posi = posi - 1
  let mut nn = n
  if nn == 0L {
    while posi > 0 && utf8_is_cont(data, posi) {
      posi = posi - 1
    }
  } else {
    if posi < len && utf8_is_cont(data, posi) {
      @core.runtime_error(state, "initial position is a continuation byte")
    }
    if nn < 0L {
      while nn < 0L && posi > 0 {
        posi = posi - 1
        while posi > 0 && utf8_is_cont(data, posi) {
          posi = posi - 1
        }
        nn = nn + 1L
      }
    } else {
      nn = nn - 1L
      while nn > 0L && posi < len {
        posi = posi + 1
        while posi < len && utf8_is_cont(data, posi) {
          posi = posi + 1
        }
        nn = nn - 1L
      }
    }
  }
  if nn == 0L {
    [@core.VInt((posi + 1).to_int64())]
  } else {
    [@core.VNil]
  }
}

///|
/// The iterator behind `utf8.codes`, mirroring `iter_aux`.
pub fn utf8_codes_iterator(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let lax = match upvals[0] {
    @core.VBool(b) => b
    _ => false
  }
  let s = match args[0] {
    @core.VStr(s) => s
    _ => return [@core.VNil]
  }
  let data = s.data()
  let len = data.length()
  let i = @core.check_int(state, args, 2, "codes")
  // The position is the previous result, re-read zero based; the first call
  // starts at zero.  Negative positions end the iteration.
  let mut start = i.to_int()
  if i < 0L || start >= len {
    return [@core.VNil]
  }
  while start < len && utf8_is_cont(data, start) {
    start = start + 1
  }
  if start >= len {
    return [@core.VNil]
  }
  match utf8_decode(data, start, !lax) {
    Some((cp, next)) => {
      if next < len && utf8_is_cont(data, next) {
        @core.runtime_error(state, "invalid UTF-8 code")
      }
      [@core.VInt((start + 1).to_int64()), @core.VInt(cp.to_int64())]
    }
    None => @core.runtime_error(state, "invalid UTF-8 code")
  }
}

///|
pub fn utf8_codes(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  // `luaL_checkstring` coerces a number and reports the type it wanted, so a
  // missing argument is "no value" and `utf8.codes(1)` iterates "1".
  let text = @core.check_str(state, args, 1, "codes")
  let first = text.data()
  let lax = args.length() >= 2 && @core.is_truthy_arg(state, args, 2)
  // `iter_codes` refuses to start inside a sequence.
  if first.length() > 0 && (first.at(0).to_int() & 0xc0) == 0x80 {
    @core.arg_error(state, 1, "codes", "invalid UTF-8 code")
  }
  [
    @core.VBuiltin(
      @core.make_builtin(
        "codes_iterator",
        @core.BK_NORMAL,
        0,
        utf8_codes_iterator,
        [@core.VBool(lax)],
      ),
    ),
    @core.VStr(text),
    @core.VInt(0L),
  ]
}

///|
pub fn open_utf8_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("char", @core.VBuiltin(@core.LBuiltin::make("char", -1, utf8_char)))
  t.set_str("charpattern", @core.VStr(@core.LStr::of_bytes(utf8_charpattern)))
  t.set_str(
    "codepoint",
    @core.VBuiltin(@core.LBuiltin::make("codepoint", 3, utf8_codepoint)),
  )
  t.set_str(
    "codes",
    @core.VBuiltin(@core.LBuiltin::make("codes", 1, utf8_codes)),
  )
  t.set_str("len", @core.VBuiltin(@core.LBuiltin::make("len", 3, utf8_len)))
  t.set_str(
    "offset",
    @core.VBuiltin(@core.LBuiltin::make("offset", 3, utf8_offset)),
  )
  state.globals.set_str("utf8", @core.VTable(t))
}
