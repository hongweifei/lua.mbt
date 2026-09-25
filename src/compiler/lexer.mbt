// The scanner: whitespace, names, numerals, operators.

///|
/// Where a chunk's bytes come from when not all of them are at hand: `next`
/// gives the piece the reader produced, or `None` once it is spent, and
/// `failure` answers with the failure that ended the stream, if any.
///
/// Pulling piece by piece is what makes a reader with side effects stop where
/// the parser stopped, and a reader that never ends fail on the syntax error the
/// extra input causes instead of being read forever -- the reference reads its
/// reader the same way, through `luaZ_fill`.  A failure is *kept* rather than
/// raised, because it has to outrank the syntax error the missing bytes would
/// produce, and the caller asks for it after the parse is over.
pub(all) struct SourceFeed {
  next : () -> Bytes?
  failure : () -> @core.Value?
}

///|
pub(all) struct Lexer {
  /// The bytes read so far, in a buffer with room to grow: `filled` says how
  /// much of it is real, and the rest is slack a piece may be appended into.
  /// A reader hands its pieces over one at a time, and the parser may still need
  /// the bytes before the one it is at, so the bytes have to be kept -- but
  /// appending to a flat buffer would copy it once per piece, which is why the
  /// buffer is grown by doubling instead.
  mut buf : FixedArray[Byte]
  mut filled : Int
  feed : SourceFeed?
  mut pos : Int
  mut line : Int
  mut current : Int
  chunk : String
  interned : Map[Bytes, @core.LStr]
}

///|
pub fn Lexer::new(src : Bytes, chunk : String) -> Lexer {
  let lx : Lexer = {
    buf: src.to_fixedarray(),
    filled: src.length(),
    feed: None,
    pos: 0,
    line: 1,
    current: -1,
    chunk,
    interned: Map([]),
  }
  lx.current = lx.byte_at(0)
  lx
}

///|
/// A lexer that pulls the chunk from a reader as the parser asks for it.
pub fn Lexer::from_feed(feed : SourceFeed, chunk : String) -> Lexer {
  let lx : Lexer = {
    buf: FixedArray::make(0, @core.byte_of(0)),
    filled: 0,
    feed: Some(feed),
    pos: 0,
    line: 1,
    current: -1,
    chunk,
    interned: Map([]),
  }
  lx.current = lx.byte_at(0)
  lx
}

///|
/// Reuse one string object per distinct contents, mirroring the table the
/// reference implementation's lexer anchors strings in.
pub fn Lexer::intern(self : Lexer, b : Bytes) -> @core.LStr {
  match self.interned.get(b) {
    Some(s) => s
    None => {
      let s = @core.LStr::of_bytes(b)
      self.interned[b] = s
      s
    }
  }
}

///|
pub fn Lexer::byte_at(self : Lexer, i : Int) -> Int {
  while i >= self.filled {
    if !self.pull() {
      return -1
    }
  }
  self.buf[i].to_int()
}

///|
/// Takes one more piece from the reader, and answers whether one arrived.  The
/// piece is appended to a buffer that doubles when it runs out of room, so a
/// reader that hands over many small pieces costs the copying of each byte once
/// rather than once per piece.
fn Lexer::pull(self : Lexer) -> Bool {
  let feed = match self.feed {
    Some(f) => f
    None => return false
  }
  match (feed.next)() {
    None => false
    Some(piece) => {
      let need = self.filled + piece.length()
      if need > self.buf.length() {
        let mut cap = if self.buf.length() == 0 {
          64
        } else {
          self.buf.length()
        }
        while cap < need {
          cap = cap * 2
        }
        self.buf = self.buf.make_and_blit(
          allocate_len=cap,
          init=@core.byte_of(0),
          len=self.filled,
        )
      }
      self.buf.blit_from_bytes(self.filled, piece, 0, piece.length())
      self.filled = need
      true
    }
  }
}

///|
/// The bytes of a range that has already been read: a token's spelling as the
/// source wrote it, which is what an error message quotes.
pub fn Lexer::slice(self : Lexer, start : Int, len : Int) -> Bytes {
  Bytes::makei(len, i => self.buf[start + i])
}

///|
pub fn[T] Lexer::error(self : Lexer, msg : String) -> T raise @core.LuaRaised {
  let full = self.chunk + ":" + self.line.to_string() + ": " + msg
  raise @core.LuaRaised(@core.VStr(@core.LStr::of_string(full)))
}

///|
/// Error carrying the text that was being read, mirroring the `near '...'`
/// suffix the reference implementation appends.
pub fn[T] Lexer::error_near(
  self : Lexer,
  msg : String,
  near : Bytes,
) -> T raise @core.LuaRaised {
  let suffix = if near.length() > 0 {
    " near '" + render_token_text(near) + "'"
  } else {
    ""
  }
  self.error(msg + suffix)
}

///|
/// Error whose `near` text is the raw source slice of the token being read,
/// from `start` up to the current byte, optionally including it.  Mirrors the
/// buffer the reference scanner saves and reports on escape errors.
pub fn[T] Lexer::error_raw(
  self : Lexer,
  msg : String,
  start : Int,
  include_current : Bool,
) -> T raise @core.LuaRaised {
  let stop = if include_current && self.current >= 0 {
    self.pos + 1
  } else {
    self.pos
  }
  self.error_near(msg, self.slice(start, stop - start))
}

///|
/// The name this chunk is known by in diagnostics.
pub fn Lexer::chunk_name(self : Lexer) -> String {
  self.chunk
}

///|
/// Advances past the current byte, counting line breaks.  A `\n\r` or `\r\n`
/// pair counts as one break, like in the reference implementation.
pub fn Lexer::next(self : Lexer) -> Unit {
  let old = self.current
  self.pos = self.pos + 1
  if old == 10 || old == 13 {
    self.line = self.line + 1
    let d = self.byte_at(self.pos)
    if (d == 10 || d == 13) && d != old {
      self.pos = self.pos + 1
    }
  }
  self.current = self.byte_at(self.pos)
}

///|
pub fn Lexer::is_newline(self : Lexer) -> Bool {
  self.current == 10 || self.current == 13
}

///|
pub fn Lexer::save_and_next(self : Lexer, buf : Buffer) -> Unit {
  buf.write_byte(self.current.to_byte())
  self.next()
}

///|----------------------------------------------------------------
/// Long brackets

///|----------------------------------------------------------------

///|
/// Reads a numeral.  Everything that could belong to a numeral is consumed
/// first, then the text is converted; a numeral that does not convert is a
/// lexical error, which is why `1..2` is rejected rather than read as `1 .. 2`.
pub fn Lexer::read_numeral(self : Lexer) -> Bytes raise @core.LuaRaised {
  // As in `read_name`: the numeral is recognised by consuming bytes, and cut
  // out of the source once at the end rather than copied as it goes.
  let start = self.pos
  let first = self.current
  let mut hex = false
  self.next()
  if first == 48 && (self.current == 120 || self.current == 88) {
    hex = true
    self.next()
  }
  while true {
    let c = self.current
    if !hex && (c == 101 || c == 69) {
      self.next()
      if self.current == 43 || self.current == 45 {
        self.next()
      }
    } else if hex && (c == 112 || c == 80) {
      self.next()
      if self.current == 43 || self.current == 45 {
        self.next()
      }
    } else if @core.is_hex_digit_byte(c) || c == 46 {
      self.next()
    } else {
      break
    }
  }
  // A numeral touching a letter absorbs one letter, forcing the malformed
  // number error, as `read_numeral` in the reference scanner does.
  if @core.is_alpha_byte(self.current) || self.current == 95 {
    self.next()
  }
  self.slice(start, self.pos - start)
}

///|
pub fn Lexer::read_name(self : Lexer) -> Bytes {
  // The bytes are taken from the source once, at the end, instead of being
  // copied a byte at a time into a buffer of their own.
  let start = self.pos
  while @core.is_alnum_byte(self.current) || self.current == 95 {
    self.next()
  }
  self.slice(start, self.pos - start)
}

///|----------------------------------------------------------------
/// Token reader

///|----------------------------------------------------------------

///|
/// Produces the next token.
pub fn Lexer::next_token(self : Lexer) -> Token raise @core.LuaRaised {
  while true {
    if self.current < 0 {
      return {
        kind: TK_EOF,
        text: @core.LStr::empty(),
        raw: @core.bytes_of(""),
        int_value: 0L,
        float_value: 0.0,
        line: self.line,
      }
    }
    match self.current {
      32 | 9 | 11 | 12 => self.next()
      10 | 13 => self.next()
      45 => {
        // '-' or a comment
        self.next()
        if self.current == 45 {
          self.next()
          self.read_comment()
        } else {
          return self.make_symbol(TK_MINUS, self.line, -1)
        }
      }
      91 => {
        // '[' or a long string
        let startline = self.line
        let written = self.pos
        let level = self.try_long_bracket()
        if level >= 0 {
          let content = self.read_long_bracket(level, true)
          return {
            kind: TK_STRING,
            text: self.intern(content),
            raw: self.slice(written, self.pos - written),
            int_value: 0L,
            float_value: 0.0,
            line: startline,
          }
        }
        self.next()
        return self.make_symbol(TK_LBRACKET, startline, -1)
      }
      61 => {
        let startline = self.line
        self.next()
        if self.current == 61 {
          self.next()
          return self.make_symbol(TK_EQ, startline, -1)
        }
        return self.make_symbol(TK_ASSIGN, startline, -1)
      }
      60 => {
        let startline = self.line
        self.next()
        if self.current == 61 {
          self.next()
          return self.make_symbol(TK_LE, startline, -1)
        }
        if self.current == 60 {
          self.next()
          return self.make_symbol(TK_SHL, startline, -1)
        }
        return self.make_symbol(TK_LT, startline, -1)
      }
      62 => {
        let startline = self.line
        self.next()
        if self.current == 61 {
          self.next()
          return self.make_symbol(TK_GE, startline, -1)
        }
        if self.current == 62 {
          self.next()
          return self.make_symbol(TK_SHR, startline, -1)
        }
        return self.make_symbol(TK_GT, startline, -1)
      }
      47 => {
        let startline = self.line
        self.next()
        if self.current == 47 {
          self.next()
          return self.make_symbol(TK_DSLASH, startline, -1)
        }
        return self.make_symbol(TK_SLASH, startline, -1)
      }
      126 => {
        let startline = self.line
        self.next()
        if self.current == 61 {
          self.next()
          return self.make_symbol(TK_NE, startline, -1)
        }
        return self.make_symbol(TK_TILDE, startline, -1)
      }
      58 => {
        let startline = self.line
        self.next()
        if self.current == 58 {
          self.next()
          return self.make_symbol(TK_DCOLON, startline, -1)
        }
        return self.make_symbol(TK_COLON, startline, -1)
      }
      34 | 39 => {
        let startline = self.line
        let del = self.current
        let written = self.pos
        let content = self.read_quoted_string(del)
        return {
          kind: TK_STRING,
          text: self.intern(content),
          raw: self.slice(written, self.pos - written),
          int_value: 0L,
          float_value: 0.0,
          line: startline,
        }
      }
      46 => {
        let startline = self.line
        self.next()
        if self.current == 46 {
          self.next()
          if self.current == 46 {
            self.next()
            return self.make_symbol(TK_ELLIPSIS, startline, -1)
          }
          return self.make_symbol(TK_CONCAT, startline, -1)
        }
        if @core.is_digit_byte(self.current) {
          // A numeral may start with the dot consumed above (`.5`); read the
          // rest and re-attach the dot so the text reaches the converter intact.
          let rest = self.read_numeral()
          let text = @core.bytes_concat([@core.bytes_of("."), rest])
          return self.finish_numeral(text, startline)
        }
        return self.make_symbol(TK_DOT, startline, -1)
      }
      _ => {
        let startline = self.line
        if @core.is_digit_byte(self.current) {
          let text = self.read_numeral()
          return self.finish_numeral(text, startline)
        }
        if self.current == 95 || @core.is_alpha_byte(self.current) {
          let text = self.read_name()
          let kind = keyword_kind(text)
          return {
            kind,
            text: @core.LStr::of_bytes(text),
            raw: text,
            int_value: 0L,
            float_value: 0.0,
            line: startline,
          }
        }
        return self.single_char_token(startline)
      }
    }
  } nobreak {
    {
      kind: TK_EOF,
      text: @core.LStr::empty(),
      raw: @core.bytes_of(""),
      int_value: 0L,
      float_value: 0.0,
      line: self.line,
    }
  }
}

///|
pub fn Lexer::single_char_token(
  self : Lexer,
  startline : Int,
) -> Token raise @core.LuaRaised {
  let c = self.current
  // An unknown byte becomes a token of its own, which the parser rejects and
  // the message reports as '<\ddd>'.
  if self.symbol_of(c) < 0 {
    self.next()
    return {
      kind: -1,
      text: @core.LStr::empty(),
      raw: @core.bytes_one(if c >= 0 { c } else { 63 }),
      int_value: 0L,
      float_value: 0.0,
      line: startline,
    }
  }
  let kind = self.symbol_of(c)
  self.next()
  self.make_symbol(kind, startline, -1)
}

///|
/// The token a single byte stands for, or -1 when it is not an operator.
pub fn Lexer::symbol_of(_self : Lexer, c : Int) -> Int {
  match c {
    43 => TK_PLUS
    42 => TK_STAR
    37 => TK_PERCENT
    94 => TK_CARET
    35 => TK_HASH
    38 => TK_AMP
    124 => TK_PIPE
    40 => TK_LPAREN
    41 => TK_RPAREN
    123 => TK_LBRACE
    125 => TK_RBRACE
    93 => TK_RBRACKET
    59 => TK_SEMI
    44 => TK_COMMA
    _ => -1
  }
}

///|
/// The spelling of every token kind, as bytes and as an interned string.  A
/// symbol is scanned far more often than it is printed, so the two are built
/// once here instead of once per token.
fn build_symbol_spelling() -> Array[(Bytes, @core.LStr)] {
  let out : Array[(Bytes, @core.LStr)] = Array::make(
    TK_ELLIPSIS + 1,
    (@core.bytes_of(""), @core.LStr::empty()),
  )
  for kind in 0..<=TK_ELLIPSIS {
    let b = @core.bytes_of(token_name(kind))
    out[kind] = (b, @core.LStr::of_bytes(b))
  }
  out
}

///|
let symbol_spelling : Array[(Bytes, @core.LStr)] = build_symbol_spelling()

///|
pub fn Lexer::make_symbol(
  _self : Lexer,
  kind : Int,
  startline : Int,
  extra : Int,
) -> Token {
  let spelling = symbol_spelling[kind]
  {
    kind,
    text: spelling.1,
    raw: if extra >= 0 {
      @core.bytes_concat([spelling.0, @core.bytes_one(extra)])
    } else {
      spelling.0
    },
    int_value: 0L,
    float_value: 0.0,
    line: startline,
  }
}

///|
/// Converts the scanned numeral text, classifying it as an integer or a float.
pub fn Lexer::finish_numeral(
  self : Lexer,
  text : Bytes,
  startline : Int,
) -> Token raise @core.LuaRaised {
  match @core.lua_str2num(text) {
    Some(@core.NInt(i)) =>
      {
        kind: TK_INT,
        text: @core.LStr::empty(),
        raw: text,
        int_value: i,
        float_value: 0.0,
        line: startline,
      }
    Some(@core.NFloat(d)) =>
      {
        kind: TK_FLOAT,
        text: @core.LStr::empty(),
        raw: text,
        int_value: 0L,
        float_value: d,
        line: startline,
      }
    None => {
      self.line = startline
      self.error_near("malformed number", text)
    }
  }
}

///|
/// How the reference implementation shows a token in a syntax error: a
/// printable character or the token's own text quoted as it stands, and any
/// other byte as `<\ddd>`.
pub fn render_token_text(b : Bytes) -> String {
  if b.length() == 1 {
    let c = @core.ubyte_at(b, 0)
    if c < 32 || c >= 127 {
      return "<\\" + c.to_string() + ">"
    }
  }
  @core.text_of(b)
}
