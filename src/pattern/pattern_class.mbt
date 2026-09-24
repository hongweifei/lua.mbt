// Character classes of the pattern language.

///|
// The classes follow the C locale, as the reference matcher's `isalpha` and
// friends do, so membership is looked up in tables built from the host
// `ctype` and rebuilt whenever the locale generation changes.
let ctype_tables : Array[Array[Bool]] = [
  for _ in 0..<11 => Array::make(256, false)
]

///|
let ctype_built_gen : Ref[Int] = Ref(-1)

///|
fn build_ctype_tables() -> Unit {
  for which in 0..<11 {
    let t = ctype_tables[which]
    for c in 0..<256 {
      t[c] = @core.host_ctype(which, c) != 0
    }
  }
  ctype_built_gen.val = @core.locale_generation.val
}

///|
fn ctype_bit(which : Int, c : Int) -> Bool {
  if ctype_built_gen.val != @core.locale_generation.val {
    build_ctype_tables()
  }
  c >= 0 && c < 256 && ctype_tables[which][c]
}

///|
pub fn is_alpha_c(c : Int) -> Bool {
  ctype_bit(0, c)
}

///|
pub fn is_cntrl_c(c : Int) -> Bool {
  ctype_bit(1, c)
}

///|
pub fn is_digit_c(c : Int) -> Bool {
  ctype_bit(2, c)
}

///|
pub fn is_graph_c(c : Int) -> Bool {
  ctype_bit(3, c)
}

///|
pub fn is_lower_c(c : Int) -> Bool {
  ctype_bit(4, c)
}

///|
pub fn is_upper_c(c : Int) -> Bool {
  ctype_bit(8, c)
}

///|
pub fn is_punct_c(c : Int) -> Bool {
  ctype_bit(6, c)
}

///|
pub fn is_space_c(c : Int) -> Bool {
  ctype_bit(7, c)
}

///|
pub fn is_xdigit_c(c : Int) -> Bool {
  ctype_bit(9, c)
}

///|
pub fn is_alnum_c(c : Int) -> Bool {
  ctype_bit(10, c)
}

///|
/// Tests one character against a `%x` class.
pub fn match_class(c : Int, cl : Int) -> Bool {
  let lower = if cl >= 65 && cl <= 90 { cl + 32 } else { cl }
  let res = match lower {
    97 => is_alpha_c(c)
    99 => is_cntrl_c(c)
    100 => is_digit_c(c)
    103 => is_graph_c(c)
    108 => is_lower_c(c)
    112 => is_punct_c(c)
    115 => is_space_c(c)
    117 => is_upper_c(c)
    119 => is_alnum_c(c)
    120 => is_xdigit_c(c)
    122 => c == 0 // %z, a deprecated option, like the reference matcher
    _ => return cl == c
  }
  if cl >= 65 && cl <= 90 {
    !res
  } else {
    res
  }
}

///|
/// Tests one character against a bracket set starting at `p`.
pub fn match_bracket_class(c : Int, pat : Bytes, p : Int, ec : Int) -> Bool {
  let mut i = p
  let mut sig = true
  if i + 1 < pat.length() && @core.ubyte_at(pat, i + 1) == 94 {
    sig = false
    i = i + 1
  }
  i = i + 1
  while i < ec {
    if @core.ubyte_at(pat, i) == L_ESC {
      i = i + 1
      if i < pat.length() && match_class(c, @core.ubyte_at(pat, i)) {
        return sig
      }
    } else if i + 1 < ec && @core.ubyte_at(pat, i + 1) == 45 && i + 2 < ec {
      if @core.ubyte_at(pat, i) <= c && c <= @core.ubyte_at(pat, i + 2) {
        return sig
      }
      i = i + 2
    } else if @core.ubyte_at(pat, i) == c {
      return sig
    }
    i = i + 1
  }
  !sig
}

///|
/// Returns the index just past the class that starts at `p`.
pub fn class_end(ms : MatchState, p : Int) -> Int raise @core.LuaRaised {
  let pat = ms.pat
  let c = @core.ubyte_at(pat, p)
  let mut i = p + 1
  if c == L_ESC {
    if i >= pat.length() {
      ms.fail("malformed pattern (ends with '%')")
    }
    return i + 1
  }
  if c == 91 {
    if i < pat.length() && @core.ubyte_at(pat, i) == 94 {
      i = i + 1
    }
    while true {
      if i >= pat.length() {
        ms.fail("malformed pattern (missing ']')")
      }
      let ch = @core.ubyte_at(pat, i)
      i = i + 1
      if ch == L_ESC && i < pat.length() {
        i = i + 1
      }
      if i < pat.length() && @core.ubyte_at(pat, i) == 93 {
        return i + 1
      }
      if i >= pat.length() {
        ms.fail("malformed pattern (missing ']')")
      }
    }
  }
  i
}

///|
/// Whether the character at `s` matches the class `p .. ep`.
pub fn single_match(ms : MatchState, s : Int, p : Int, ep : Int) -> Bool {
  if s >= ms.src.length() {
    return false
  }
  let c = @core.ubyte_at(ms.src, s)
  let first = @core.ubyte_at(ms.pat, p)
  if first == 46 {
    return true
  }
  if first == L_ESC {
    return match_class(c, @core.ubyte_at(ms.pat, p + 1))
  }
  if first == 91 {
    return match_bracket_class(c, ms.pat, p, ep - 1)
  }
  first == c
}

///|----------------------------------------------------------------
/// Captures

///|----------------------------------------------------------------
