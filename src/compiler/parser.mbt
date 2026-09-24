// Token helpers and the entry point of the parser.

///|
pub const UNARY_PRIORITY : Int = 12

///|
/// Maximum nesting of blocks and expressions, guarding the host stack against
/// pathological input.
/// Nesting bound for the parser.  The reference allows 200 levels; a
/// parenthesized expression costs two here, so the bound is set so that both
/// a hundred nested parentheses (accepted) and five hundred (rejected) fall on
/// the right side.
pub const MAX_SYNTAX_DEPTH : Int = 400

///|
/// The parser state.
pub(all) struct Parser {
  lex : Lexer
  mut token : Token
  /// The line of the token before the current one, used when reporting
  /// unclosed constructs.
  mut last_line : Int
  mut depth : Int
  /// Nesting of enclosing loops, so that `break` can be rejected outside one.
  mut loop_depth : Int
  /// Line of the innermost function being parsed, or 0 in the main chunk. The
  /// reference implementation quotes it when a compile-time limit is blown.
  mut func_line : Int
  /// Whether the innermost function being parsed takes `...`.  The main chunk
  /// does, a `function` body only when its parameter list ends with one, and a
  /// `...` anywhere else is a syntax error.
  mut is_vararg : Bool
}

///|
pub fn Parser::new(src : Bytes, chunk : String) -> Parser raise @core.LuaRaised {
  Parser::of_lexer(Lexer::new(src, chunk))
}

///|
/// A parser whose chunk arrives from a reader as the lexer asks for it.
pub fn Parser::from_feed(
  feed : SourceFeed,
  chunk : String,
) -> Parser raise @core.LuaRaised {
  Parser::of_lexer(Lexer::from_feed(feed, chunk))
}

///|
fn Parser::of_lexer(lex : Lexer) -> Parser raise @core.LuaRaised {
  let first = lex.next_token()
  {
    lex,
    token: first,
    last_line: 1,
    depth: 0,
    loop_depth: 0,
    func_line: 0,
    is_vararg: true,
  }
}

///|----------------------------------------------------------------
/// Token helpers

///|----------------------------------------------------------------

///|
/// The line to report for the token under the cursor.
pub fn Parser::line(self : Parser) -> Int {
  self.token.line
}

///|
pub fn Parser::advance(self : Parser) -> Unit raise @core.LuaRaised {
  self.last_line = self.token.line
  self.token = self.lex.next_token()
}

///|
/// The source text of the current token as it should appear in messages.

///|
/// `errorlimit`: a blown compile-time limit names the limit and the function it
/// belongs to.
pub fn Parser::limit_error(
  self : Parser,
  what : String,
  limit : Int,
) -> Unit raise @core.LuaRaised {
  let place = if self.func_line == 0 {
    "main function"
  } else {
    "function at line " + self.func_line.to_string()
  }
  self.syntax_error(
    "too many " + what + " (limit is " + limit.to_string() + ") in " + place,
  )
}

///|
pub fn Parser::token_text(self : Parser) -> String {
  if self.token.kind == TK_EOF {
    return "<eof>"
  }
  "'" + render_token_text(self.token.raw) + "'"
}

///|
pub fn[T] Parser::syntax_error(
  self : Parser,
  msg : String,
) -> T raise @core.LuaRaised {
  let full = self.lex.chunk_name() + ":" + self.line().to_string() + ": " + msg
  raise @core.LuaRaised(@core.VStr(@core.LStr::of_string(full)))
}

///|
pub fn[T] Parser::syntax_error_near(
  self : Parser,
  msg : String,
) -> T raise @core.LuaRaised {
  self.syntax_error(msg + " near " + self.token_text())
}

///|
/// The token as the reference implementation names it in `... expected`
/// messages: `luaX_token2str`, where names, strings and numerals are angle
/// placeholders and `<eof>` is spelled without quotes.
pub fn token2str(kind : Int) -> String {
  match kind {
    TK_EOF => "<eof>"
    TK_NAME => "<name>"
    TK_INT => "<integer>"
    TK_FLOAT => "<number>"
    TK_STRING => "<string>"
    _ => "'" + token_name(kind) + "'"
  }
}

///|
pub fn[T] Parser::error_expected(
  self : Parser,
  kind : Int,
) -> T raise @core.LuaRaised {
  self.syntax_error_near(token2str(kind) + " expected")
}

///|
pub fn Parser::expect(self : Parser, kind : Int) -> Unit raise @core.LuaRaised {
  if self.token.kind != kind {
    self.error_expected(kind)
  }
  self.advance()
}

///|
pub fn Parser::test_next(
  self : Parser,
  kind : Int,
) -> Bool raise @core.LuaRaised {
  if self.token.kind == kind {
    self.advance()
    true
  } else {
    false
  }
}

///|
/// Consumes `what`, or reports an error naming the construct it closes and the
/// line where that construct started.
pub fn Parser::check_match(
  self : Parser,
  what : Int,
  who : Int,
  where_line : Int,
) -> Unit raise @core.LuaRaised {
  if !self.test_next(what) {
    if where_line == self.line() {
      self.error_expected(what)
    } else {
      self.syntax_error_near(
        token2str(what) +
        " expected (to close " +
        token2str(who) +
        " at line " +
        where_line.to_string() +
        ")",
      )
    }
  }
}

///|
/// Reads a name, which is required in this position.
pub fn Parser::check_name(self : Parser) -> @core.LStr raise @core.LuaRaised {
  if self.token.kind != TK_NAME {
    self.error_expected(TK_NAME)
  }
  let name = self.token.text
  self.advance()
  name
}

///|
pub fn Parser::enter_depth(self : Parser) -> Unit raise @core.LuaRaised {
  self.depth = self.depth + 1
  if self.depth > MAX_SYNTAX_DEPTH {
    self.syntax_error("chunk has too many syntax levels")
  }
}

///|
pub fn Parser::leave_depth(self : Parser) -> Unit {
  self.depth = self.depth - 1
}

///|----------------------------------------------------------------
/// Expressions

///|----------------------------------------------------------------

///|
/// Parses a chunk and returns its body.
pub fn parse_chunk(
  src : Bytes,
  chunk : String,
) -> FuncBody raise @core.LuaRaised {
  Parser::new(src, chunk).finish_chunk()
}

///|
/// The same, for a chunk that arrives from a reader.
pub fn parse_chunk_fed(
  feed : SourceFeed,
  chunk : String,
) -> FuncBody raise @core.LuaRaised {
  Parser::from_feed(feed, chunk).finish_chunk()
}

///|
/// Reads the block out to the end of the chunk and wraps it as the main one.
fn Parser::finish_chunk(self : Parser) -> FuncBody raise @core.LuaRaised {
  let p = self
  let body = p.block()
  if p.token.kind != TK_EOF {
    p.syntax_error_near("<eof> expected")
  }
  let chunk_body : FuncBody = {
    params: [],
    is_vararg: true,
    body,
    line_defined: 0,
    last_line: p.last_line,
    name: "main chunk",
  }
  chunk_body
}
