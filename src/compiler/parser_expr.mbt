// Expressions.

///|
/// Left and right priority of a binary operator.  Right associativity is
/// expressed by `right < left`.
pub fn binop_priority(op : Int) -> (Int, Int) {
  match op {
    @core.BINOP_OR => (1, 1)
    @core.BINOP_AND => (2, 2)
    @core.BINOP_LT
    | @core.BINOP_GT
    | @core.BINOP_LE
    | @core.BINOP_GE
    | @core.BINOP_NE
    | @core.BINOP_EQ => (3, 3)
    @core.BINOP_BOR => (4, 4)
    @core.BINOP_BXOR => (5, 5)
    @core.BINOP_BAND => (6, 6)
    @core.BINOP_SHL | @core.BINOP_SHR => (7, 7)
    @core.BINOP_CONCAT => (9, 8)
    @core.BINOP_ADD | @core.BINOP_SUB => (10, 10)
    @core.BINOP_MUL | @core.BINOP_MOD | @core.BINOP_DIV | @core.BINOP_IDIV =>
      (11, 11)
    @core.BINOP_POW => (14, 13)
    _ => (0, 0)
  }
}

///|
/// Maps a token to a binary operator, or -1 when it is not one.
pub fn binop_of_token(kind : Int) -> Int {
  match kind {
    TK_PLUS => @core.BINOP_ADD
    TK_MINUS => @core.BINOP_SUB
    TK_STAR => @core.BINOP_MUL
    TK_SLASH => @core.BINOP_DIV
    TK_PERCENT => @core.BINOP_MOD
    TK_CARET => @core.BINOP_POW
    TK_DSLASH => @core.BINOP_IDIV
    TK_AMP => @core.BINOP_BAND
    TK_PIPE => @core.BINOP_BOR
    TK_TILDE => @core.BINOP_BXOR
    TK_SHL => @core.BINOP_SHL
    TK_SHR => @core.BINOP_SHR
    TK_CONCAT => @core.BINOP_CONCAT
    TK_EQ => @core.BINOP_EQ
    TK_LT => @core.BINOP_LT
    TK_LE => @core.BINOP_LE
    TK_NE => @core.BINOP_NE
    TK_GT => @core.BINOP_GT
    TK_GE => @core.BINOP_GE
    TK_AND => @core.BINOP_AND
    TK_OR => @core.BINOP_OR
    _ => -1
  }
}

///|
/// Maps a token to a unary operator, or -1 when it is not one.
pub fn unop_of_token(kind : Int) -> Int {
  match kind {
    TK_MINUS => @core.UNOP_MINUS
    TK_NOT => @core.UNOP_NOT
    TK_HASH => @core.UNOP_LEN
    TK_TILDE => @core.UNOP_BNOT
    _ => -1
  }
}

///|
/// `prefixexp` in the grammar: a name, or a parenthesised expression, or a call
/// on either.
pub fn Parser::primary_expr(self : Parser) -> Expr raise @core.LuaRaised {
  let line = self.line()
  match self.token.kind {
    TK_LPAREN => {
      self.advance()
      let inner = self.expr()
      self.check_match(TK_RPAREN, TK_LPAREN, line)
      EParen(inner, line)
    }
    TK_NAME => {
      let name = self.token.text
      self.advance()
      EName(name, line)
    }
    _ => self.syntax_error_near("unexpected symbol")
  }
}

///|
/// `suffixedexp`: the primary expression followed by any number of index,
/// field, method and call suffixes.
pub fn Parser::suffixed_expr(self : Parser) -> Expr raise @core.LuaRaised {
  self.enter_depth()
  let mut e = self.primary_expr()
  while true {
    let line = self.line()
    match self.token.kind {
      TK_DOT => {
        self.advance()
        let name = self.check_name()
        e = EIndex(e, EString(name, line), line)
      }
      TK_LBRACKET => {
        self.advance()
        let key = self.expr()
        self.check_match(TK_RBRACKET, TK_LBRACKET, line)
        e = EIndex(e, key, line)
      }
      TK_COLON => {
        self.advance()
        let name = self.check_name()
        let args = self.func_args()
        e = EMethod(e, name, args, line)
      }
      TK_LPAREN | TK_STRING | TK_LBRACE => {
        let args = self.func_args()
        e = ECall(e, args, line)
      }
      _ => break
    }
  }
  self.leave_depth()
  e
}

///|
/// The argument list of a call: `(...)`, a table constructor, or a literal
/// string.
pub fn Parser::func_args(self : Parser) -> Array[Expr] raise @core.LuaRaised {
  let line = self.line()
  match self.token.kind {
    TK_LPAREN => {
      self.advance()
      let args = if self.token.kind == TK_RPAREN {
        []
      } else {
        self.expr_list()
      }
      self.check_match(TK_RPAREN, TK_LPAREN, line)
      args
    }
    TK_LBRACE => {
      let t = self.table_constructor()
      [t]
    }
    TK_STRING => {
      let s = self.token.text
      self.advance()
      [EString(s, line)]
    }
    _ => self.syntax_error_near("function arguments expected")
  }
}

///|
/// A table constructor.
pub fn Parser::table_constructor(self : Parser) -> Expr raise @core.LuaRaised {
  let line = self.line()
  self.check_match(TK_LBRACE, TK_LBRACE, line)
  let fields : Array[Field] = []
  while self.token.kind != TK_RBRACE {
    if self.token.kind == TK_LBRACKET {
      let kline = self.line()
      self.advance()
      let key = self.expr()
      self.check_match(TK_RBRACKET, TK_LBRACKET, kline)
      self.expect(TK_ASSIGN)
      let value = self.expr()
      fields.push(FKeyed(key, value))
    } else if self.token.kind == TK_NAME {
      // `name = v` is a keyed field; anything else is positional, which needs
      // one token of lookahead.
      let name = self.token.text
      let nline = self.line()
      self.advance()
      if self.token.kind == TK_ASSIGN {
        self.advance()
        let value = self.expr()
        fields.push(FKeyed(EString(name, nline), value))
      } else {
        let start = EName(name, nline)
        let e = self.continue_suffixed(start)
        let e2 = self.continue_binary(e, 0)
        fields.push(FPositional(e2))
      }
    } else {
      fields.push(FPositional(self.expr()))
    }
    if !self.test_next(TK_COMMA) && !self.test_next(TK_SEMI) {
      break
    }
  }
  self.check_match(TK_RBRACE, TK_LBRACE, line)
  ETable(fields, line)
}

///|
/// Continues a suffixed expression whose first token has already been consumed.
pub fn Parser::continue_suffixed(
  self : Parser,
  start : Expr,
) -> Expr raise @core.LuaRaised {
  let mut e = start
  while true {
    let line = self.line()
    match self.token.kind {
      TK_DOT => {
        self.advance()
        let name = self.check_name()
        e = EIndex(e, EString(name, line), line)
      }
      TK_LBRACKET => {
        self.advance()
        let key = self.expr()
        self.check_match(TK_RBRACKET, TK_LBRACKET, line)
        e = EIndex(e, key, line)
      }
      TK_COLON => {
        self.advance()
        let name = self.check_name()
        let args = self.func_args()
        e = EMethod(e, name, args, line)
      }
      TK_LPAREN | TK_STRING | TK_LBRACE => {
        let args = self.func_args()
        e = ECall(e, args, line)
      }
      _ => break
    }
  }
  e
}

///|
/// Continues a binary expression whose left operand is already parsed.
pub fn Parser::continue_binary(
  self : Parser,
  left : Expr,
  limit : Int,
) -> Expr raise @core.LuaRaised {
  let mut e = left
  while true {
    let op = binop_of_token(self.token.kind)
    if op < 0 {
      break
    }
    let (lp, rp) = binop_priority(op)
    if lp <= limit {
      break
    }
    let line = self.line()
    self.advance()
    let right = self.sub_expr(rp)
    e = EBinary(op, e, right, line)
  }
  e
}

///|
/// The expression parser proper, with the operator priority climbing as in the
/// reference implementation.
pub fn Parser::sub_expr(
  self : Parser,
  limit : Int,
) -> Expr raise @core.LuaRaised {
  self.enter_depth()
  let line = self.line()
  let uop = unop_of_token(self.token.kind)
  let mut left = if uop >= 0 {
    self.advance()
    let operand = self.sub_expr(UNARY_PRIORITY)
    EUnary(uop, operand, line)
  } else {
    let e = self.simple_expr()
    e
  }
  left = self.continue_binary(left, limit)
  self.leave_depth()
  left
}

///|
/// Expressions with no binary operators inside.
pub fn Parser::simple_expr(self : Parser) -> Expr raise @core.LuaRaised {
  let line = self.line()
  match self.token.kind {
    TK_INT => {
      let v = self.token.int_value
      self.advance()
      EInt(v, line)
    }
    TK_FLOAT => {
      let v = self.token.float_value
      self.advance()
      EFloat(v, line)
    }
    TK_STRING => {
      let v = self.token.text
      self.advance()
      EString(v, line)
    }
    TK_NIL => {
      self.advance()
      ENil(line)
    }
    TK_TRUE => {
      self.advance()
      ETrue(line)
    }
    TK_FALSE => {
      self.advance()
      EFalse(line)
    }
    TK_ELLIPSIS => {
      if !self.is_vararg {
        self.syntax_error_near("cannot use '...' outside a vararg function")
      }
      self.advance()
      EVararg(line)
    }
    TK_LBRACE => self.table_constructor()
    TK_FUNCTION => {
      self.advance()
      let body = self.func_body(false, "")
      EFunction(body)
    }
    _ => self.suffixed_expr()
  }
}

///|
pub fn Parser::expr(self : Parser) -> Expr raise @core.LuaRaised {
  self.sub_expr(0)
}

///|
/// A comma separated list of expressions.
pub fn Parser::expr_list(self : Parser) -> Array[Expr] raise @core.LuaRaised {
  let list : Array[Expr] = [self.expr()]
  while self.test_next(TK_COMMA) {
    list.push(self.expr())
  }
  list
}

///|----------------------------------------------------------------
/// Function bodies

///|----------------------------------------------------------------

///|
/// Parses `(parlist) block end`.  `is_method` prepends the implicit `self`
/// parameter, which is exactly how the reference implementation desugars
/// `function a:m()`.
pub fn Parser::func_body(
  self : Parser,
  is_method : Bool,
  name : String,
) -> FuncBody raise @core.LuaRaised {
  let line = self.line()
  let saved_func_line = self.func_line
  self.func_line = self.last_line
  self.expect(TK_LPAREN)
  let params : Array[@core.LStr] = []
  if is_method {
    params.push(@core.LStr::of_string("self"))
  }
  let mut is_vararg = false
  if self.token.kind != TK_RPAREN {
    while true {
      if self.token.kind == TK_ELLIPSIS {
        self.advance()
        is_vararg = true
        break
      }
      params.push(self.check_name())
      if params.length() >= @core.MAX_PARAMS {
        self.syntax_error("too many parameters")
      }
      if !self.test_next(TK_COMMA) {
        break
      }
    }
  }
  self.check_match(TK_RPAREN, TK_LPAREN, line)
  // The body is parsed with the function's own vararg-ness in force, so that a
  // `...` in a nested function body is refused (`check_confirm`).
  let saved_vararg = self.is_vararg
  self.is_vararg = is_vararg
  let body = self.block()
  let endline = self.line()
  self.check_match(TK_END, TK_FUNCTION, line)
  self.func_line = saved_func_line
  self.is_vararg = saved_vararg
  { params, is_vararg, body, line_defined: line, last_line: endline, name, }
}

///|----------------------------------------------------------------
/// Statements

///|----------------------------------------------------------------
