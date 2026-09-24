// Code generation for calls and multiple value expressions.

///|
/// True for expressions that can yield more than one value.
pub fn is_multi(e : Expr) -> Bool {
  match e {
    ECall(_, _, _) | EMethod(_, _, _, _) | EVararg(_) => true
    _ => false
  }
}

///|
/// Whether an expression is a call, which is what lets `return f(x)` become a
/// tail call.  A parenthesised call is not one: it yields exactly one value.
pub fn is_call(e : Expr) -> Bool {
  match e {
    ECall(_, _, _) | EMethod(_, _, _, _) => true
    _ => false
  }
}

///|
/// Compiles an expression that may produce several values.  `want` is the
/// number of results requested, or -1 for all of them.  The results start at the
/// returned register.
pub fn compile_multi(
  fs : FuncState,
  e : Expr,
  want : Int,
) -> Int raise @core.LuaRaised {
  match e {
    EVararg(line) => {
      fs.line = line
      let reg = fs.freereg
      fs.reserve(1)
      let _ = fs.emit_ab(
        @core.OP_VARARG,
        reg,
        if want < 0 {
          0
        } else {
          want + 1
        },
      )
      if want < 0 {
        fs.set_freereg(reg + 1)
      }
      reg
    }
    _ => compile_call(fs, e, want)
  }
}

///|
/// Compiles a function or method call, requesting `want` results.
pub fn compile_call(
  fs : FuncState,
  e : Expr,
  want : Int,
) -> Int raise @core.LuaRaised {
  let base = fs.freereg
  fs.reserve(1)
  fs.line = line_of(e)
  let mut extra = 1
  match e {
    ECall(f, _args, _) => {
      compile_expr_into(fs, f, base)
      extra = 1
    }
    EMethod(obj, name, _args, _) => {
      let saved = fs.freereg
      let objreg = compile_expr(fs, obj)
      let k = fs.add_string(name)
      let _ = fs.emit_abc(@core.OP_SELF, base, objreg, @core.RK_OFFSET + k)
      fs.set_freereg(saved)
      fs.set_freereg(base + 1)
      extra = 2
    }
    _ => extra = 1
  }
  fs.set_freereg(base + extra)
  let nfixed = compile_args(fs, e, base + extra)
  let b = if nfixed < 0 { 0 } else { nfixed + extra }
  let c = if want < 0 { 0 } else { want + 1 }
  // As in 'luaK_fixline' after the call is emitted: the arguments belong to
  // their own lines, the call itself to the callee's.
  fs.line = line_of(e)
  let _ = fs.emit_abc(@core.OP_CALL, base, b, c)
  if want < 0 {
    fs.set_freereg(base + 1)
  } else {
    fs.set_freereg(base + want)
  }
  base
}

///|
/// Compiles the arguments of a call into consecutive registers starting at
/// `base`.  Returns the number of fixed arguments, or -1 when the last argument
/// is an open call so that the count is only known at run time.
pub fn compile_args(
  fs : FuncState,
  call : Expr,
  base : Int,
) -> Int raise @core.LuaRaised {
  let args = match call {
    ECall(_, a, _) => a
    EMethod(_, _, a, _) => a
    _ => []
  }
  let n = args.length()
  if n == 0 {
    fs.set_freereg(base)
    return 0
  }
  // Each argument takes a register, so the whole window has to fit first; the
  // reference implementation refuses this while placing the arguments.
  fs.check_regs(base + n)
  let mut i = 0
  while i < n - 1 {
    fs.set_freereg(base + i + 1)
    compile_expr_into(fs, args[i], base + i)
    i = i + 1
  }
  let last = args[n - 1]
  if is_multi(last) {
    fs.set_freereg(base + n - 1)
    let r = compile_multi(fs, last, -1)
    if r != base + n - 1 {
      let _ = fs.emit_abc(@core.OP_MOVE, base + n - 1, r, 0)
      fs.set_freereg(base + n)
    }
    return -1
  }
  fs.set_freereg(base + n)
  compile_expr_into(fs, last, base + n - 1)
  fs.set_freereg(base + n)
  n
}

///|----------------------------------------------------------------
/// Assignments and local declarations

///|----------------------------------------------------------------

///|
/// Places `exprs` into consecutive registers starting at `base`, adjusted to
/// `want` values.  Returns the number of values placed, or -1 when the last
/// expression is an open call.
pub fn compile_value_list(
  fs : FuncState,
  exprs : Array[Expr],
  base : Int,
  want : Int,
) -> Int raise @core.LuaRaised {
  let n = exprs.length()
  if n == 0 {
    if want > 0 {
      fs.load_nil(base, want)
      fs.set_freereg(base + want)
    }
    return 0
  }
  let kept = if want >= 0 && want < n { want } else { n }
  if kept == 0 {
    // Nothing is kept: the expressions still run for their side effects.
    let mut j = 0
    while j < n {
      fs.set_freereg(base)
      let _ = compile_expr(fs, exprs[j])
      j = j + 1
    }
    fs.set_freereg(base)
    return 0
  }
  let mut i = 0
  while i < kept - 1 {
    fs.set_freereg(base + i + 1)
    compile_expr_into(fs, exprs[i], base + i)
    i = i + 1
  }
  // Expressions past the ones that are kept still have to be evaluated.
  let mut j = kept
  while j < n {
    fs.set_freereg(base + kept)
    let _ = compile_expr(fs, exprs[j])
    j = j + 1
  }
  fs.set_freereg(base + kept)
  let last = exprs[kept - 1]
  let remaining = if want < 0 { -1 } else { want - (kept - 1) }
  if is_multi(last) && remaining != 1 {
    fs.set_freereg(base + kept - 1)
    let r = compile_multi(fs, last, remaining)
    if r != base + kept - 1 {
      let _ = fs.emit_abc(@core.OP_MOVE, base + kept - 1, r, 0)
    }
    // The call itself already produced exactly `remaining` values, padding with
    // nil where it had fewer, so nothing else needs to be filled in.
    if remaining < 0 {
      fs.set_freereg(base + kept)
      return -1
    }
    fs.set_freereg(base + kept - 1 + remaining)
    return want
  }
  compile_expr_into(fs, last, base + kept - 1)
  fs.set_freereg(base + kept)
  if remaining > 1 {
    fs.load_nil(base + kept, remaining - 1)
    fs.set_freereg(base + kept + remaining - 1)
  }
  if want < 0 {
    kept
  } else {
    want
  }
}

///|----------------------------------------------------------------
/// Statements

///|----------------------------------------------------------------
