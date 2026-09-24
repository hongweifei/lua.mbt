// Reading numerals.

///|
pub(all) enum NumValue {
  NInt(Int64)
  NFloat(Double)
}

///|
pub fn is_space_byte(c : Int) -> Bool {
  c == 32 || (c >= 9 && c <= 13)
}

///|
pub fn is_digit_byte(c : Int) -> Bool {
  c >= 48 && c <= 57
}

///|
pub fn is_hex_digit_byte(c : Int) -> Bool {
  is_digit_byte(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
}

///|
pub fn hex_digit_value(c : Int) -> Int {
  if c >= 48 && c <= 57 {
    c - 48
  } else if c >= 97 && c <= 102 {
    c - 97 + 10
  } else {
    c - 65 + 10
  }
}

///|
pub fn is_alpha_byte(c : Int) -> Bool {
  (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
}

///|
pub fn is_alnum_byte(c : Int) -> Bool {
  is_alpha_byte(c) || is_digit_byte(c)
}

///|
/// The largest power of ten that can be multiplied into a 64 bit integer
/// without overflowing, and the largest digit allowed after it.
pub let max_before_mul10 : UInt64 = 922337203685477580UL

///|
pub let max_last_digit : UInt64 = 7UL

///|
/// Converts text to an integer, or `None` when the text is not exactly an
/// integer (a decimal value that overflows, a fractional part, trailing
/// characters).  Hexadecimal values wrap around modulo 2^64.
pub fn scan_integer(s : Bytes) -> Int64? {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  let mut neg = false
  if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
    neg = ubyte_at(s, i) == 45
    i = i + 1
  }
  let mut a : UInt64 = 0UL
  let mut empty = true
  if i + 1 < n &&
    ubyte_at(s, i) == 48 &&
    (ubyte_at(s, i + 1) == 120 || ubyte_at(s, i + 1) == 88) {
    i = i + 2
    while i < n && is_hex_digit_byte(ubyte_at(s, i)) {
      a = a * 16UL + hex_digit_value(ubyte_at(s, i)).to_uint64()
      empty = false
      i = i + 1
    }
  } else {
    let bias : UInt64 = if neg { 1UL } else { 0UL }
    while i < n && is_digit_byte(ubyte_at(s, i)) {
      let d = (ubyte_at(s, i) - 48).to_uint64()
      if a >= max_before_mul10 &&
        (a > max_before_mul10 || d > max_last_digit + bias) {
        return None
      }
      a = a * 10UL + d
      empty = false
      i = i + 1
    }
  }
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  if empty || i != n {
    return None
  }
  let magnitude = if neg { 0UL - a } else { a }
  Some(magnitude.reinterpret_as_int64())
}

///|
/// Validates the syntax of a decimal float: `[+-]? (digits[.digits?] | .digits)
/// ([eE][+-]?digits)?`.
pub fn check_decimal_float(s : Bytes) -> Bool {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
    i = i + 1
  }
  let mut digits = 0
  while i < n && is_digit_byte(ubyte_at(s, i)) {
    digits = digits + 1
    i = i + 1
  }
  if i < n && ubyte_at(s, i) == 46 {
    i = i + 1
    while i < n && is_digit_byte(ubyte_at(s, i)) {
      digits = digits + 1
      i = i + 1
    }
  }
  if digits == 0 {
    return false
  }
  if i < n && (ubyte_at(s, i) == 101 || ubyte_at(s, i) == 69) {
    i = i + 1
    if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
      i = i + 1
    }
    let mut exp_digits = 0
    while i < n && is_digit_byte(ubyte_at(s, i)) {
      exp_digits = exp_digits + 1
      i = i + 1
    }
    if exp_digits == 0 {
      return false
    }
  }
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  i == n
}

///|
/// Float remainder with the sign of the divisor: `fmod` follows the dividend,
/// so a mismatched sign needs one correction. A zero remainder keeps whatever
/// sign `fmod` produced, and a zero divisor yields NaN.
pub fn float_mod(a : Double, b : Double) -> Double {
  let m = a.mod(b)
  if m != 0.0 && (m < 0.0) != (b < 0.0) {
    m + b
  } else {
    m
  }
}

///|
/// 2.0 raised to an exact power up to 1023, built from the exponent field so
/// that no rounding is involved.
fn pow2(e : Int) -> Double {
  if e == 0 {
    return 1.0
  }
  let bits = (e + 1023).to_uint64() << 52
  bits.reinterpret_as_double()
}

///|
/// `x * 2^e`, scaled in steps so that neither the factor nor the intermediate
/// result leaves the finite range.
fn ldexp(x : Double, e : Int) -> Double {
  let mut r = x
  let mut k = e
  while k > 0 {
    let step = if k > 500 { 500 } else { k }
    r = r * pow2(step)
    k = k - step
  }
  while k < 0 {
    let step = if k < -500 { -500 } else { k }
    r = r / pow2(0 - step)
    k = k - step
  }
  r
}

///|
/// The value of a hexadecimal float, read the way C99's `strtod` does: at most
/// `max_sig_digits` digits enter the accumulator, and every further digit only
/// moves the binary exponent.  Each digit is worth four bits, and a digit after
/// the point contributes -4.
pub fn hex_float_value(s : Bytes) -> Double {
  // Accumulating more than this many hexadecimal digits cannot change the
  // rounded result, since each one shifts the value by a factor of sixteen.
  let max_sig_digits = 30
  let n = s.length()
  let mut i = 0
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  let mut neg = false
  if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
    neg = ubyte_at(s, i) == 45
    i = i + 1
  }
  i = i + 2 // skip the radix prefix, which the syntax check already accepted
  let mut r : Double = 0.0
  let mut sig_digits = 0
  let mut e = 0
  let mut has_dot = false
  while i < n {
    let c = ubyte_at(s, i)
    if c == 46 {
      if has_dot {
        break
      }
      has_dot = true
    } else if is_hex_digit_byte(c) {
      // Leading zeros carry no information and cost no slot; digits past the
      // window still move the exponent, and any digit after the point pulls it
      // back by four bits.
      if c == 48 && sig_digits == 0 {
        ()
      } else if sig_digits < max_sig_digits {
        r = r * 16.0 + hex_digit_value(c).to_double()
        sig_digits = sig_digits + 1
      } else {
        e = e + 1
      }
      if has_dot {
        e = e - 1
      }
    } else {
      break
    }
    i = i + 1
  }
  e = e * 4
  if i < n && (ubyte_at(s, i) == 112 || ubyte_at(s, i) == 80) {
    i = i + 1
    let mut neg1 = false
    if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
      neg1 = ubyte_at(s, i) == 45
      i = i + 1
    }
    let mut exp1 = 0
    while i < n && is_digit_byte(ubyte_at(s, i)) {
      exp1 = exp1 * 10 + (ubyte_at(s, i) - 48)
      i = i + 1
    }
    e = e + (if neg1 { 0 - exp1 } else { exp1 })
  }
  if neg {
    r = 0.0 - r
  }
  ldexp(r, e)
}

///|
/// Validates the syntax of a hexadecimal float:
/// `[+-]? 0[xX] (hexdigits[.hexdigits?] | .hexdigits) ([pP][+-]?digits)?`.
pub fn check_hex_float(s : Bytes) -> Bool {
  let n = s.length()
  let mut i = 0
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
    i = i + 1
  }
  if i + 1 >= n || ubyte_at(s, i) != 48 {
    return false
  }
  if ubyte_at(s, i + 1) != 120 && ubyte_at(s, i + 1) != 88 {
    return false
  }
  i = i + 2
  let mut digits = 0
  while i < n && is_hex_digit_byte(ubyte_at(s, i)) {
    digits = digits + 1
    i = i + 1
  }
  if i < n && ubyte_at(s, i) == 46 {
    i = i + 1
    while i < n && is_hex_digit_byte(ubyte_at(s, i)) {
      digits = digits + 1
      i = i + 1
    }
  }
  if digits == 0 {
    return false
  }
  if i < n && (ubyte_at(s, i) == 112 || ubyte_at(s, i) == 80) {
    i = i + 1
    if i < n && (ubyte_at(s, i) == 45 || ubyte_at(s, i) == 43) {
      i = i + 1
    }
    let mut exp_digits = 0
    while i < n && is_digit_byte(ubyte_at(s, i)) {
      exp_digits = exp_digits + 1
      i = i + 1
    }
    if exp_digits == 0 {
      return false
    }
  }
  while i < n && is_space_byte(ubyte_at(s, i)) {
    i = i + 1
  }
  i == n
}

///|
/// The current locale's decimal mark, for locale-aware number conversions.
pub fn locale_decpoint() -> Int {
  @host.lua_mbt_locale_decpoint()
}

///|
/// The text as the C locale would spell it: the first dot becomes the locale's
/// decimal mark.  `lua_mbt_strtod` follows the locale, while the syntax
/// validators here are dot-based, so the conversion needs the translation.
fn locale_float_text(s : Bytes) -> Bytes {
  let dp = locale_decpoint()
  if dp == 46 {
    return s
  }
  match s.find(b".") {
    Some(i) => {
      let arr = s.to_array()
      arr[i] = byte_of(dp)
      Bytes::from_array(arr[:])
    }
    None => s
  }
}

///|
/// Converts text to a float.  Returns `None` when the text is not a float, or
/// when it spells `inf`/`nan`, which Lua deliberately refuses.
pub fn scan_float(s : Bytes) -> Double? {
  let n = s.length()
  // The reference implementation searches for the first of ".xXnN" and rejects
  // * the numeral outright when that character is 'n' or 'N'.
  let mut first = 0
  let mut i = 0
  while i < n {
    let c = ubyte_at(s, i)
    if c == 46 || c == 120 || c == 88 || c == 110 || c == 78 {
      first = c
      break
    }
    i = i + 1
  }
  if first == 110 || first == 78 {
    return None
  }
  let ok = if first == 120 || first == 88 {
    check_hex_float(s)
  } else {
    check_decimal_float(s)
  }
  if !ok {
    return None
  }
  if first == 120 || first == 88 {
    return Some(hex_float_value(s))
  }
  let t = locale_float_text(s)
  Some(@host.lua_mbt_strtod(t, t.length()))
}

///|
/// The full numeral conversion: integer first, then float.  A failed
/// conversion is retried with the locale's decimal mark replaced by a dot,
/// mirroring the fallback of `l_str2d`.
pub fn lua_str2num(s : Bytes) -> NumValue? {
  match scan_integer(s) {
    Some(i) => Some(NInt(i))
    None =>
      match scan_float(s) {
        Some(d) => Some(NFloat(d))
        None => lua_str2num_locale(s)
      }
  }
}

///|
fn lua_str2num_locale(s : Bytes) -> NumValue? {
  let dp = locale_decpoint()
  if dp == 46 {
    return None
  }
  let arr = s.to_array()
  let mut found = false
  for i, b in arr {
    if b == dp.to_byte() {
      arr[i] = byte_of(46)
      found = true
      break
    }
  }
  if !found {
    return None
  }
  let t = Bytes::from_array(arr[:])
  match scan_integer(t) {
    Some(i) => Some(NInt(i))
    None =>
      match scan_float(t) {
        Some(d) => Some(NFloat(d))
        None => None
      }
  }
}

///|----------------------------------------------------------------
/// Formatting

///|----------------------------------------------------------------
