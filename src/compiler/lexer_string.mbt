// String and comment bodies, including escape sequences.

///|
/// Counts the `=` signs of a long bracket opener or closer.  Returns the level
/// when the matching character follows, or a negative value when it does not.
pub fn Lexer::skip_sep(self : Lexer) -> Int {
  let mut count = 0
  let s = self.current
  self.next()
  while self.current == 61 {
    self.next()
    count = count + 1
  }
  if self.current == s {
    count
  } else {
    -count - 1
  }
}

///|
/// Reads a long string or long comment.  The opening bracket has already been
/// consumed once; `level` is the number of `=` signs.
pub fn Lexer::read_long_bracket(
  self : Lexer,
  level : Int,
  want_content : Bool,
) -> Bytes raise @core.LuaRaised {
  let startline = self.line
  let buf = Buffer::Buffer()
  self.next()
  // A newline directly after the opener is not part of the contents.
  if self.is_newline() {
    self.next()
  }
  while true {
    if self.current < 0 {
      let what = if want_content {
        "unfinished long string"
      } else {
        "unfinished long comment"
      }
      self.error(
        what + " (starting at line " + startline.to_string() + ") near <eof>",
      )
    } else if self.current == 93 {
      let sep = self.skip_sep()
      if sep == level {
        self.next()
        break
      }
      // skip_sep consumed the ']' and some '=' signs; they are content when
      // this is not the matching closer, and `skip_sep`'s negative result
      // still reports how many '=' it read.
      if want_content {
        buf.write_byte(@core.byte_of(93))
        let n = if sep >= 0 { sep } else { -sep - 1 }
        for _ in 0..<n {
          buf.write_byte(@core.byte_of(61))
        }
      }
    } else if self.is_newline() {
      if want_content {
        buf.write_byte(@core.byte_of(10))
      }
      self.next()
    } else if want_content {
      self.save_and_next(buf)
    } else {
      self.next()
    }
  }
  buf.to_bytes()
}

///|
/// Checks whether the cursor sits on a long bracket opener and consumes it.
pub fn Lexer::try_long_bracket(self : Lexer) -> Int {
  // current is '['
  let save_pos = self.pos
  let save_line = self.line
  let save_cur = self.current
  let level = self.skip_sep()
  if level >= 0 {
    return level
  }
  self.pos = save_pos
  self.line = save_line
  self.current = save_cur
  -1
}

///|----------------------------------------------------------------
/// Escape sequences

///|----------------------------------------------------------------

///|
/// Encodes a code point as UTF-8, mirroring `luaO_utf8esc` which allows values
/// beyond the Unicode range (up to 0x7FFFFFFF) and therefore up to six bytes.
pub fn utf8_encode_extended(x : Int, buf : Buffer) -> Unit {
  if x < 0x80 {
    buf.write_byte(x.to_byte())
    return
  }
  let tmp = Array::make(6, 0)
  let mut n = 1
  let mut v = x
  let mut mfb = 0x3f
  // Continuation bytes are emitted from the end; `mfb` tracks how many bits the
  // leading byte can still carry, exactly as in `luaO_utf8esc`.
  while true {
    tmp[6 - n] = 0x80 | (v & 0x3f)
    n = n + 1
    v = v >> 6
    mfb = mfb >> 1
    if v <= mfb {
      break
    }
  }
  tmp[6 - n] = ((mfb.lnot() << 1) | v) & 0xff
  let mut i = 6 - n
  while i < 6 {
    buf.write_byte(tmp[i].to_byte())
    i = i + 1
  }
}

///|
/// Reads the `\x` escape and returns its value.  `start` is the position of
/// the opening quote, used for the `near` text of errors.
pub fn Lexer::read_hex_escape(
  self : Lexer,
  start : Int,
) -> Int raise @core.LuaRaised {
  // current is 'x'
  self.next()
  let mut value = 0
  let mut i = 0
  while i < 2 {
    if !@core.is_hex_digit_byte(self.current) {
      self.error_raw("hexadecimal digit expected", start, true)
    }
    value = value * 16 + @core.hex_digit_value(self.current)
    self.next()
    i = i + 1
  }
  value
}

///|
/// Reads the `\u{...}` escape and writes its UTF-8 encoding.
pub fn Lexer::read_utf8_escape(
  self : Lexer,
  start : Int,
  buf : Buffer,
) -> Unit raise @core.LuaRaised {
  // current is 'u'
  self.next()
  if self.current != 123 {
    self.error_raw("missing '{'", start, true)
  }
  self.next()
  if !@core.is_hex_digit_byte(self.current) {
    self.error_raw("hexadecimal digit expected", start, true)
  }
  let mut value = 0
  for ;; {
    if value > 0x7ffffff {
      self.error_raw("UTF-8 value too large", start, true)
    }
    value = value * 16 + @core.hex_digit_value(self.current)
    self.next()
    if !@core.is_hex_digit_byte(self.current) {
      break
    }
  }
  if self.current != 125 {
    self.error_raw("missing '}'", start, true)
  }
  self.next()
  utf8_encode_extended(value, buf)
}

///|
/// Reads a quoted string.  `del` is the quote byte.
pub fn Lexer::read_quoted_string(
  self : Lexer,
  del : Int,
) -> Bytes raise @core.LuaRaised {
  let buf = Buffer::Buffer()
  let start = self.pos
  self.next()
  while self.current != del {
    if self.current < 0 {
      self.error("unfinished string near <eof>")
    } else if self.is_newline() {
      self.error_raw("unfinished string", start, false)
    } else if self.current == 92 {
      self.next()
      let c = self.current
      if c == 97 {
        buf.write_byte(@core.byte_of(7))
        self.next()
      } else if c == 98 {
        buf.write_byte(@core.byte_of(8))
        self.next()
      } else if c == 102 {
        buf.write_byte(@core.byte_of(12))
        self.next()
      } else if c == 110 {
        buf.write_byte(@core.byte_of(10))
        self.next()
      } else if c == 114 {
        buf.write_byte(@core.byte_of(13))
        self.next()
      } else if c == 116 {
        buf.write_byte(@core.byte_of(9))
        self.next()
      } else if c == 118 {
        buf.write_byte(@core.byte_of(11))
        self.next()
      } else if c == 120 {
        let value = self.read_hex_escape(start)
        buf.write_byte(value.to_byte())
      } else if c == 117 {
        self.read_utf8_escape(start, buf)
      } else if c == 10 || c == 13 {
        // A backslash before a real line break produces a newline.
        self.next()
        buf.write_byte(@core.byte_of(10))
      } else if c == 92 || c == 34 || c == 39 {
        buf.write_byte(c.to_byte())
        self.next()
      } else if c < 0 {
        self.error("unfinished string near <eof>")
      } else if c == 122 {
        // \z skips the following span of whitespace.
        self.next()
        while @core.is_space_byte(self.current) || self.is_newline() {
          self.next()
        }
      } else if @core.is_digit_byte(c) {
        let mut value = 0
        let mut i = 0
        while i < 3 && @core.is_digit_byte(self.current) {
          value = value * 10 + (self.current - 48)
          self.next()
          i = i + 1
        }
        if value > 255 {
          self.error_raw("decimal escape too large", start, true)
        }
        buf.write_byte(value.to_byte())
      } else {
        self.error_raw("invalid escape sequence", start, true)
      }
    } else {
      self.save_and_next(buf)
    }
  }
  self.next()
  buf.to_bytes()
}

///|----------------------------------------------------------------
/// Comments

///|----------------------------------------------------------------

///|
/// Skips a comment.  The leading `--` has already been consumed.
pub fn Lexer::read_comment(self : Lexer) -> Unit raise @core.LuaRaised {
  if self.current == 91 {
    let level = self.try_long_bracket()
    if level >= 0 {
      let _ = self.read_long_bracket(level, false)
      return
    }
  }
  while self.current >= 0 && !self.is_newline() {
    self.next()
  }
}

///|----------------------------------------------------------------
/// Numerals and names

///|----------------------------------------------------------------
