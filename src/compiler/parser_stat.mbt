// Statements.

///|
/// Whether the current token terminates a block.
pub fn Parser::block_follow(self : Parser, with_until : Bool) -> Bool {
  match self.token.kind {
    TK_ELSE | TK_ELSEIF | TK_END | TK_EOF => true
    TK_UNTIL => with_until
    _ => false
  }
}

///|
/// A block: statements up to a terminator.  `return` ends the block, so
/// anything after it is a syntax error.
pub fn Parser::block(self : Parser) -> Block raise @core.LuaRaised {
  self.enter_depth()
  let stats : Array[Stat] = []
  while !self.block_follow(true) {
    if self.token.kind == TK_RETURN {
      stats.push(self.return_stat())
      break
    }
    let s = self.statement()
    match s {
      Some(st) => stats.push(st)
      None => ()
    }
  }
  self.leave_depth()
  { stats, exit_line: self.last_line, }
}

///|
/// Parses one statement.  A lone `;` produces nothing.
pub fn Parser::statement(self : Parser) -> Stat? raise @core.LuaRaised {
  let line = self.line()
  match self.token.kind {
    TK_SEMI => {
      self.advance()
      None
    }
    TK_IF => Some(self.if_stat(line))
    TK_WHILE => Some(self.while_stat(line))
    TK_DO => {
      self.advance()
      let body = self.block()
      self.check_match(TK_END, TK_DO, line)
      Some(SDo(body))
    }
    TK_FOR => Some(self.for_stat(line))
    TK_REPEAT => Some(self.repeat_stat(line))
    TK_FUNCTION => Some(self.function_stat(line))
    TK_LOCAL => Some(self.local_stat(line))
    TK_DCOLON => {
      self.advance()
      let name = self.check_name()
      self.check_match(TK_DCOLON, TK_DCOLON, line)
      Some(SLabel(name, line))
    }
    TK_RETURN => Some(self.return_stat())
    TK_BREAK => {
      self.advance()
      if self.loop_depth == 0 {
        self.syntax_error("break outside a loop at line " + line.to_string())
      }
      Some(SBreak(line))
    }
    TK_GOTO => {
      self.advance()
      let name = self.check_name()
      Some(SGoto(name, line))
    }
    _ => Some(self.expr_stat(line))
  }
}

///|
/// `if ... then ... end` with any number of `elseif` clauses and an optional
/// `else`.
pub fn Parser::if_stat(self : Parser, line : Int) -> Stat raise @core.LuaRaised {
  let clauses : Array[(Expr, Block, Int)] = []
  self.expect(TK_IF)
  let cond = self.expr()
  self.expect(TK_THEN)
  let then_line = self.last_line
  clauses.push((cond, self.block(), then_line))
  while self.token.kind == TK_ELSEIF {
    self.advance()
    let c = self.expr()
    self.expect(TK_THEN)
    let tline = self.last_line
    clauses.push((c, self.block(), tline))
  }
  let else_block = if self.test_next(TK_ELSE) {
    Some(self.block())
  } else {
    None
  }
  self.check_match(TK_END, TK_IF, line)
  SIf(clauses, else_block, line)
}

///|
pub fn Parser::while_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  self.expect(TK_WHILE)
  let cond = self.expr()
  self.expect(TK_DO)
  self.loop_depth = self.loop_depth + 1
  let body = self.block()
  self.loop_depth = self.loop_depth - 1
  self.check_match(TK_END, TK_WHILE, line)
  SWhile(cond, body, line)
}

///|
pub fn Parser::repeat_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  self.expect(TK_REPEAT)
  self.loop_depth = self.loop_depth + 1
  let body = self.block()
  self.loop_depth = self.loop_depth - 1
  self.check_match(TK_UNTIL, TK_REPEAT, line)
  // The condition can see the locals of the body, so it is compiled before the
  // block's scope is closed.
  let cond = self.expr()
  SRepeat(body, cond, line)
}

///|
/// `for` in both of its forms.
pub fn Parser::for_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  self.expect(TK_FOR)
  let first = self.check_name()
  if self.test_next(TK_ASSIGN) {
    let start = self.expr()
    self.expect(TK_COMMA)
    let stop = self.expr()
    let step = if self.test_next(TK_COMMA) { Some(self.expr()) } else { None }
    let do_line = self.line()
    self.expect(TK_DO)
    self.loop_depth = self.loop_depth + 1
    let body = self.block()
    self.loop_depth = self.loop_depth - 1
    self.check_match(TK_END, TK_FOR, line)
    SNumericFor(first, start, stop, step, body, line, do_line)
  } else {
    let names : Array[@core.LStr] = [first]
    while self.test_next(TK_COMMA) {
      names.push(self.check_name())
    }
    self.expect(TK_IN)
    // The implicit call of the iterator is attributed to where its expressions
    // start, not to the `for`.
    let expr_line = self.line()
    let exprs = self.expr_list()
    let do_line = self.line()
    self.expect(TK_DO)
    self.loop_depth = self.loop_depth + 1
    let body = self.block()
    self.loop_depth = self.loop_depth - 1
    self.check_match(TK_END, TK_FOR, line)
    SGenericFor(names, exprs, body, line, do_line, expr_line)
  }
}

///|
/// `function name{.name}[:name] body`
pub fn Parser::function_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  self.expect(TK_FUNCTION)
  // The name is a sequence of fields on the first name.
  let base = self.check_name()
  let mut target = EName(base, line)
  let mut display = @core.text_of(base.data())
  let mut is_method = false
  while self.token.kind == TK_DOT {
    self.advance()
    let name = self.check_name()
    target = EIndex(target, EString(name, line), line)
    display = display + "." + @core.text_of(name.data())
  }
  if self.token.kind == TK_COLON {
    self.advance()
    let name = self.check_name()
    target = EIndex(target, EString(name, line), line)
    display = display + ":" + @core.text_of(name.data())
    is_method = true
  }
  let label = if is_method {
    "method '" + display + "'"
  } else {
    "function '" + display + "'"
  }
  let body = self.func_body(is_method, label)
  SFunction(target, body, line)
}

///|
/// `local function f` or `local a, b <attrib> = ...`
pub fn Parser::local_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  self.expect(TK_LOCAL)
  if self.test_next(TK_FUNCTION) {
    let name = self.check_name()
    let body = self.func_body(
      false,
      "function '" + @core.text_of(name.data()) + "'",
    )
    return SLocalFunction(name, body, line)
  }
  let decls : Array[LocalDecl] = []
  while true {
    let name = self.check_name()
    let nline = self.line()
    let mut attrib = ATTRIB_NONE
    if self.test_next(TK_LT) {
      let attr = self.check_name()
      self.expect(TK_GT)
      let a = @core.text_of(attr.data())
      if a == "const" {
        attrib = ATTRIB_CONST
      } else if a == "close" {
        attrib = ATTRIB_CLOSE
      } else {
        self.syntax_error("unknown attribute '" + a + "'")
      }
    }
    decls.push({ name, attrib, line: nline, })
    // `new_localvar` refuses the declaration list here, before the parser can
    // trip over some later syntax error.
    if decls.length() > @core.MAX_VARS {
      self.limit_error("local variables", @core.MAX_VARS)
    }
    if !self.test_next(TK_COMMA) {
      break
    }
  }
  let exprs = if self.test_next(TK_ASSIGN) { self.expr_list() } else { [] }
  SLocal(decls, exprs, line)
}

///|
pub fn Parser::return_stat(self : Parser) -> Stat raise @core.LuaRaised {
  let line = self.line()
  self.expect(TK_RETURN)
  let exprs = if self.block_follow(true) || self.token.kind == TK_SEMI {
    []
  } else {
    self.expr_list()
  }
  let _ = self.test_next(TK_SEMI)
  SReturn(exprs, line)
}

///|
/// Either an assignment or a call statement.
pub fn Parser::expr_stat(
  self : Parser,
  line : Int,
) -> Stat raise @core.LuaRaised {
  let first = self.suffixed_expr()
  if self.token.kind == TK_ASSIGN || self.token.kind == TK_COMMA {
    let targets : Array[Expr] = [first]
    while self.test_next(TK_COMMA) {
      targets.push(self.suffixed_expr())
      if targets.length() > @core.MAX_VARS {
        self.syntax_error("too many variables")
      }
    }
    self.expect(TK_ASSIGN)
    let values = self.expr_list()
    SAssign(targets, values, line)
  } else {
    // Only a call may be used as a statement.
    match first {
      ECall(_, _, _) | EMethod(_, _, _, _) => SCall(first)
      _ => self.syntax_error("syntax error near " + self.token_text())
    }
  }
}

///|----------------------------------------------------------------
/// Entry point

///|----------------------------------------------------------------
