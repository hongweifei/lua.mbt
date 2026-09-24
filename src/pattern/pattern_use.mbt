// The library level pattern operations.

///|
/// The captures of a successful match.  When the pattern has no captures the
/// whole match is returned, which is what `string.match` and `string.find`
/// report.
pub fn push_captures(
  ms : MatchState,
  s : Int,
  e : Int,
) -> Array[@core.Value] raise @core.LuaRaised {
  let out : Array[@core.Value] = []
  let n = if ms.level == 0 { 1 } else { ms.level }
  let mut i = 0
  while i < n {
    out.push(one_capture(ms, i, s, e))
    i = i + 1
  }
  out
}

///|
pub fn one_capture(
  ms : MatchState,
  i : Int,
  s : Int,
  e : Int,
) -> @core.Value raise @core.LuaRaised {
  if i >= ms.level {
    if i != 0 {
      ms.fail("invalid capture index %" + (i + 1).to_string())
    }
    return @core.VStr(@core.LStr::of_bytes(@core.bytes_slice(ms.src, s, e - s)))
  }
  let l = ms.capture_len[i]
  if l == CAP_POSITION {
    return @core.VInt((ms.capture_start[i] + 1).to_int64())
  }
  if l == CAP_UNFINISHED {
    ms.fail("unfinished capture")
  }
  @core.VStr(
    @core.LStr::of_bytes(@core.bytes_slice(ms.src, ms.capture_start[i], l)),
  )
}

///|
/// Whether a pattern contains no special characters and can be searched for
/// literally.
pub fn pattern_is_plain(p : Bytes) -> Bool {
  let specials : Bytes = b"^$*+?.([%-"
  let mut i = 0
  while i < p.length() {
    let c = @core.ubyte_at(p, i)
    let mut j = 0
    while j < specials.length() {
      if specials.at(j).to_int() == c {
        return false
      }
      j = j + 1
    }
    i = i + 1
  }
  true
}

///|
/// A plain substring search.
pub fn plain_find(src : Bytes, init : Int, p : Bytes) -> Int {
  if p.length() == 0 {
    return init
  }
  let mut i = init
  while i + p.length() <= src.length() {
    if @core.bytes_slice(src, i, p.length()) == p {
      return i
    }
    i = i + 1
  }
  -1
}

///|----------------------------------------------------------------
/// Library level operations

///|----------------------------------------------------------------

///|
/// `string.find` and `string.match`.
pub fn str_find_aux(
  state : @core.LuaState,
  args : Array[@core.Value],
  want_find : Bool,
) -> Array[@core.Value] raise @core.LuaRaised {
  let fname = if want_find { "find" } else { "match" }
  let s = @core.check_str(state, args, 1, fname)
  let p = @core.check_str(state, args, 2, fname)
  let src = s.data()
  let pat = p.data()
  let init = pos_relat_init(
    @core.opt_int(state, args, 3, fname, 1L),
    src.length(),
  )
  if init > src.length() {
    return [@core.VNil]
  }
  if want_find && (@core.is_truthy_arg(state, args, 4) || pattern_is_plain(pat)) {
    let found = plain_find(src, init, pat)
    if found >= 0 {
      return [
        @core.VInt((found + 1).to_int64()),
        @core.VInt((found + pat.length()).to_int64()),
      ]
    }
    return [@core.VNil]
  }
  let ms = MatchState::new(src, pat)
  let mut pstart = 0
  let mut anchor = false
  if pat.length() > 0 && @core.ubyte_at(pat, 0) == 94 {
    anchor = true
    pstart = 1
  }
  let mut si = init
  while si <= src.length() {
    ms.reset_captures()
    let res = do_match(ms, si, pstart)
    match res {
      Some(e) => {
        if want_find {
          let out : Array[@core.Value] = [
            @core.VInt((si + 1).to_int64()),
            @core.VInt(e.to_int64()),
          ]
          if ms.level > 0 {
            for v in push_captures(ms, si, e) {
              out.push(v)
            }
          }
          return out
        }
        return push_captures(ms, si, e)
      }
      None => ()
    }
    if anchor {
      break
    }
    si = si + 1
  }
  [@core.VNil]
}

///|
/// Converts a relative start index to a zero based absolute one, clamping like
/// the reference implementation.
pub fn pos_relat_init(pos : Int64, len : Int) -> Int {
  // The reference computes this in 64 bit (`posrelatI`), so values such as
  // `math.mininteger` never overflow the narrower type here.
  if pos > 0L {
    let p = pos.to_int()
    if p <= 0 {
      // A position too large for the machine word is far out of range, which
      // the caller reports as a failed search.
      return len + 1
    }
    // Like `posrelatI`, positive positions are not clamped; out-of-range is
    // decided by the caller comparing against the subject length.
    p - 1
  } else if pos == 0L {
    0
  } else {
    let p = len.to_int64() + pos
    if p < 0L {
      0
    } else {
      p.to_int()
    }
  }
}

///|
/// Converts a relative index like `string.sub` and friends do.
pub fn pos_relat(pos : Int64, len : Int) -> Int {
  // Mirrors `posrelatI` from lstrlib.c: positions past the end stay past the
  // end (callers clamp), and the arithmetic runs in 64 bit so extreme
  // arguments such as `math.mininteger` cannot wrap.
  if pos > 0L {
    let p = pos.to_int()
    if p <= 0 {
      // Too large for the machine word: far beyond the end of the string.
      return len + 1
    }
    p
  } else if pos == 0L {
    1
  } else if pos < -len.to_int64() {
    1
  } else {
    (len.to_int64() + pos + 1L).to_int()
  }
}

///|
/// Mirrors `getendpos` from lstrlib.c, used for the *final* position of sub,
/// byte and the utf8 functions.  Note it clamps differently from `pos_relat`:
/// a start too far out clips to 1, an end too far out clips to 0, which is
/// what makes `sub(s, math.mininteger, math.mininteger)` the empty string.
pub fn end_relat(pos : Int64, len : Int) -> Int {
  if pos > len.to_int64() {
    len
  } else if pos >= 0L {
    pos.to_int()
  } else if pos < -len.to_int64() {
    0
  } else {
    (len.to_int64() + pos + 1L).to_int()
  }
}
