// Code generation for expressions.

///|
pub fn is_constant_expr(e : Expr) -> Bool {
  match e {
    ENil(_)
    | ETrue(_)
    | EFalse(_)
    | EInt(_, _)
    | EFloat(_, _)
    | EString(_, _) => true
    _ => false
  }
}

///|
pub fn constant_of(e : Expr) -> @core.Value {
  match e {
    ENil(_) => @core.VNil
    ETrue(_) => @core.VBool(true)
    EFalse(_) => @core.VBool(false)
    EInt(v, _) => @core.VInt(v)
    EFloat(v, _) => @core.VNum(v)
    EString(s, _) => @core.VStr(s)
    _ => @core.VNil
  }
}

///|----------------------------------------------------------------
/// Entry points

///|----------------------------------------------------------------

///|
/// Compiles `e` as a single value and returns the register holding it.  The
/// caller owns that register until it resets `freereg`.
pub fn compile_expr(fs : FuncState, e : Expr) -> Int raise @core.LuaRaised {
  let reg = fs.freereg
  fs.reserve(1)
  compile_expr_into(fs, e, reg)
  reg
}

///|
/// Compiles `e` as a single value into the already reserved register `reg`.
pub fn compile_expr_into(
  fs : FuncState,
  e : Expr,
  reg : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line_of(e)
  let saved = fs.freereg
  fs.set_freereg(reg + 1)
  match e {
    ENil(_) => {
      let _ = fs.emit_ab(@core.OP_LOADNIL, reg, 1)
    }
    ETrue(_) => {
      let _ = fs.emit_abc(@core.OP_LOADBOOL, reg, 1, 0)
    }
    EFalse(_) => {
      let _ = fs.emit_abc(@core.OP_LOADBOOL, reg, 0, 0)
    }
    EInt(v, _) => fs.load_const(reg, @core.VInt(v))
    EFloat(v, _) => fs.load_const(reg, @core.VNum(v))
    EString(s, _) => fs.load_const(reg, @core.VStr(s))
    EVararg(_) => {
      let _ = fs.emit_ab(@core.OP_VARARG, reg, 2)
    }
    EFunction(body) => compile_closure(fs, body, reg)
    EName(name, line) => {
      fs.line = line
      compile_name_into(fs, name, reg)
    }
    EIndex(obj, key, _) => compile_index_into(fs, obj, key, reg)
    ECall(_, _, _) | EMethod(_, _, _, _) => {
      // The callee goes in `reg` itself, as the reference does: a call leaves
      // its results over the register that held the function, so an expression
      // like `(a+1) + f()` costs one register and the frame's used window ends
      // where the callee sits.
      fs.set_freereg(reg)
      let base = compile_call(fs, e, 1)
      if base != reg {
        let _ = fs.emit_abc(@core.OP_MOVE, reg, base, 0)
      }
    }
    EBinary(op, l, r, line) => {
      fs.line = line
      compile_binary_into(fs, op, l, r, reg, line)
    }
    EUnary(op, operand, line) => compile_unary_into(fs, op, operand, reg, line)
    ETable(fields, _) => compile_table_into(fs, fields, reg)
    EParen(inner, _) => compile_expr_into(fs, inner, reg)
  }
  // Whatever is emitted next belongs to the line this expression ended on.
  fs.line = end_line_of(e)
  fs.set_freereg(saved)
}

///|
/// Loads a name into a register: a local is copied, an upvalue fetched, and
/// anything else read from the environment table.
pub fn compile_name_into(
  fs : FuncState,
  name : @core.LStr,
  reg : Int,
) -> Unit raise @core.LuaRaised {
  let (kind, idx) = fs.resolve_name(name, false)
  if kind == VLOCAL {
    if idx != reg {
      let _ = fs.emit_abc(@core.OP_MOVE, reg, idx, 0)
    }
  } else if kind == VUPVAL {
    let _ = fs.emit_ab(@core.OP_GETUPVAL, reg, idx)
  } else {
    emit_env_get(fs, name, reg)
  }
}

///|
/// The register an index expression reads its table from.  A local already
/// lives in one, and the reference uses it as it is instead of copying it to a
/// fresh register, so `t[i]` costs one instruction and one register.
pub fn compile_base_reg(
  fs : FuncState,
  obj : Expr,
) -> Int raise @core.LuaRaised {
  match obj {
    EName(name, _) =>
      match fs.resolve_name(name, false) {
        (VLOCAL, idx) => idx
        _ => compile_expr(fs, obj)
      }
    _ => compile_expr(fs, obj)
  }
}

///|
/// Reads `env[name]` into `reg`.  The environment is normally the upvalue the
/// loader bound to the globals, so the table-in-upvalue form applies; a block
/// that declares its own `local _ENV` needs the plain indexed form instead.
pub fn emit_env_get(
  fs : FuncState,
  name : @core.LStr,
  reg : Int,
) -> Unit raise @core.LuaRaised {
  let (kind, env) = resolve_env(fs)
  let krk = @core.RK_OFFSET + fs.add_string(name)
  if kind == VLOCAL {
    let _ = fs.emit_abc(@core.OP_GETTABLE, reg, env, krk)
  } else {
    let _ = fs.emit_abc(@core.OP_GETTABUP, reg, env, krk)
  }
}

///|
/// Writes `env[name] = src`, with the same choice of form as the read.
pub fn emit_env_set(
  fs : FuncState,
  name : @core.LStr,
  src : Int,
) -> Unit raise @core.LuaRaised {
  let (kind, env) = resolve_env(fs)
  let krk = @core.RK_OFFSET + fs.add_string(name)
  if kind == VLOCAL {
    let _ = fs.emit_abc(@core.OP_SETTABLE, env, krk, src)
  } else {
    let _ = fs.emit_abc(@core.OP_SETTABUP, env, krk, src)
  }
}

///|
/// How `_ENV` is reached in this function, created as an upvalue on first use.
pub fn resolve_env(fs : FuncState) -> (Int, Int) raise @core.LuaRaised {
  let (kind, idx) = fs.resolve_name(@core.LStr::of_string("_ENV"), false)
  if kind == VLOCAL || kind == VUPVAL {
    (kind, idx)
  } else {
    fs.semantic_error("no environment table")
  }
}

///|
/// Compiles `obj[key]` into `reg`.
pub fn compile_index_into(
  fs : FuncState,
  obj : Expr,
  key : Expr,
  reg : Int,
) -> Unit raise @core.LuaRaised {
  let saved = fs.freereg
  let treg = compile_base_reg(fs, obj)
  let krk = compile_rk(fs, key)
  let _ = fs.emit_abc(@core.OP_GETTABLE, reg, treg, krk)
  fs.set_freereg(saved)
}

///|
/// Compiles a table constructor.
pub fn compile_table_into(
  fs : FuncState,
  fields : Array[Field],
  reg : Int,
) -> Unit raise @core.LuaRaised {
  let _ = fs.emit_abc(@core.OP_NEWTABLE, reg, 0, 0)
  let saved = fs.freereg
  // Total number of array items placed so far, across all batches.
  let mut narray = 0
  // Items in the batch that has not been flushed yet.
  let mut batch = 0
  let total = fields.length()
  let mut i = 0
  while i < total {
    let f = fields[i]
    match f {
      FKeyed(k, v) => {
        if batch > 0 {
          let _ = fs.emit_abc(@core.OP_SETLIST, reg, batch, narray - batch)
          batch = 0
        }
        fs.set_freereg(reg + 1)
        let krk = compile_rk(fs, k)
        fs.set_freereg(reg + 2)
        let vrk = compile_rk(fs, v)
        let _ = fs.emit_abc(@core.OP_SETTABLE, reg, krk, vrk)
        fs.set_freereg(reg + 1)
      }
      FPositional(e) => {
        if batch == 50 {
          let _ = fs.emit_abc(@core.OP_SETLIST, reg, batch, narray - batch)
          batch = 0
        }
        let slot = reg + 1 + batch
        if i == total - 1 && is_multi(e) {
          // The multi expression's results expand starting exactly at `slot`
          // (the free register after the pending values), so the pending
          // values and the expanded results form one contiguous run starting
          // at `reg + 1`; `b = 0` tells the VM to read up to `top` and append
          // after the `narray - batch` items previous batches stored.
          fs.set_freereg(slot)
          let _ = compile_multi(fs, e, -1)
          let _ = fs.emit_abc(@core.OP_SETLIST, reg, 0, narray - batch)
          fs.set_freereg(saved)
          return
        }
        fs.set_freereg(slot + 1)
        compile_expr_into(fs, e, slot)
        batch = batch + 1
        narray = narray + 1
      }
    }
    i = i + 1
  }
  if batch > 0 {
    let _ = fs.emit_abc(@core.OP_SETLIST, reg, batch, narray - batch)
  }
  fs.set_freereg(saved)
}

///|
/// Compiles an operand that may become a constant (the RK encoding) or a
/// register.  Registers are allocated above `freereg`; the caller restores it.
pub fn compile_rk(fs : FuncState, e : Expr) -> Int raise @core.LuaRaised {
  if is_constant_expr(e) {
    let k = fs.add_constant(constant_of(e))
    if k <= @core.MAX_INDEX_RK {
      return @core.RK_OFFSET + k
    }
  }
  compile_expr(fs, e)
}

///|----------------------------------------------------------------
/// Binary and unary operators

///|----------------------------------------------------------------

///|
pub fn arith_opcode(op : Int) -> Int {
  match op {
    @core.BINOP_ADD => @core.OP_ADD
    @core.BINOP_SUB => @core.OP_SUB
    @core.BINOP_MUL => @core.OP_MUL
    @core.BINOP_DIV => @core.OP_DIV
    @core.BINOP_MOD => @core.OP_MOD
    @core.BINOP_POW => @core.OP_POW
    @core.BINOP_IDIV => @core.OP_IDIV
    @core.BINOP_BAND => @core.OP_BAND
    @core.BINOP_BOR => @core.OP_BOR
    @core.BINOP_BXOR => @core.OP_BXOR
    @core.BINOP_SHL => @core.OP_SHL
    @core.BINOP_SHR => @core.OP_SHR
    _ => @core.OP_MOVE
  }
}

///|
pub fn is_arith(op : Int) -> Bool {
  op >= @core.BINOP_ADD && op <= @core.BINOP_SHR
}

///|
pub fn compile_binary_into(
  fs : FuncState,
  op : Int,
  l : Expr,
  r : Expr,
  reg : Int,
  line : Int,
) -> Unit raise @core.LuaRaised {
  match op {
    @core.BINOP_AND | @core.BINOP_OR => {
      compile_expr_into(fs, l, reg)
      let c = if op == @core.BINOP_AND { 0 } else { 1 }
      let _ = fs.emit_abc(@core.OP_TEST, reg, 0, c)
      let exit = fs.emit_jump()
      compile_expr_into(fs, r, reg)
      fs.patch_here(exit)
    }
    @core.BINOP_CONCAT => {
      // Right associative concatenation folds into a single instruction: the
      // operands must occupy consecutive registers ending at `B`.
      let parts : Array[Expr] = []
      gather_concat(l, parts)
      gather_concat(r, parts)
      let n = parts.length()
      let mut i = 0
      while i < n {
        fs.set_freereg(reg + i + 1)
        compile_expr_into(fs, parts[i], reg + i)
        i = i + 1
      }
      let _ = fs.emit_ab(@core.OP_CONCAT, reg, reg + n - 1)
    }
    _ =>
      if is_arith(op) {
        // A left-associative chain of the same operator is folded a step at a
        // time, keeping the running result in one register.  Recursing instead
        // would leave every step holding a register of its own, so a long
        // expression would run out of registers while the reference
        // implementation still has two free.
        let steps : Array[(Expr, Int)] = [(r, line)]
        let mut cur = l
        let mut more = true
        while more {
          match cur {
            EBinary(o, inner, arg, aline) =>
              if o == op {
                steps.push((arg, aline))
                cur = inner
              } else {
                more = false
              }
            _ => more = false
          }
        }
        let saved = fs.freereg
        compile_expr_into(fs, cur, reg)
        // The leftmost operand is fetched for the first operator of the chain.
        restamp_fetch(fs, steps[steps.length() - 1].1)
        let mut i = steps.length() - 1
        while i >= 0 {
          let (arg, aline) = steps[i]
          fs.set_freereg(reg + 1)
          let rrk = compile_rk(fs, arg)
          // The operation belongs to the line of its operator.
          fs.line = aline
          let _ = fs.emit_abc(arith_opcode(op), reg, reg, rrk)
          i = i - 1
        }
        fs.set_freereg(saved)
      } else {
        let saved = fs.freereg
        let lrk = compile_rk(fs, l)
        restamp_fetch(fs, line)
        let rrk = compile_rk(fs, r)
        fs.line = line
        // A comparison produces a boolean: load true, jump over a false load
        // when the comparison holds, otherwise fall through to it.
        let cmp_pair = match op {
          @core.BINOP_EQ => (@core.OP_EQ, false)
          @core.BINOP_NE => (@core.OP_EQ, false)
          @core.BINOP_LT => (@core.OP_LT, false)
          @core.BINOP_LE => (@core.OP_LE, false)
          @core.BINOP_GT => (@core.OP_LT, true)
          @core.BINOP_GE => (@core.OP_LE, true)
          _ => (@core.OP_EQ, false)
        }
        let cmp = cmp_pair.0
        let swap = cmp_pair.1
        // `A == 1` means "take the jump when the comparison holds".
        let flag = if op == @core.BINOP_NE { 0 } else { 1 }
        let _ = fs.emit_abc(@core.OP_LOADBOOL, reg, 1, 0)
        if swap {
          let _ = fs.emit_abc(cmp, flag, rrk, lrk)
        } else {
          let _ = fs.emit_abc(cmp, flag, lrk, rrk)
        }
        let skip = fs.emit_jump()
        let _ = fs.emit_abc(@core.OP_LOADBOOL, reg, 0, 0)
        fs.patch_here(skip)
        fs.set_freereg(saved)
      }
  }
}

///|
/// Collects a right leaning chain of `..` into a flat list.
pub fn gather_concat(e : Expr, out : Array[Expr]) -> Unit {
  match e {
    EBinary(@core.BINOP_CONCAT, l, r, _) => {
      gather_concat(l, out)
      gather_concat(r, out)
    }
    _ => out.push(e)
  }
}

///|
/// The reference reads a global or an indexed operand without emitting it, and
/// discharges it only when an operator consumes it; the fetch therefore carries
/// the line of that operator rather than the line the operand was written on.
fn restamp_fetch(fs : FuncState, line : Int) -> Unit {
  let n = fs.code.length()
  if n > 0 {
    match fs.code[n - 1].op {
      @core.OP_GETUPVAL | @core.OP_GETTABLE | @core.OP_GETTABUP =>
        fs.fixline(line)
      _ => ()
    }
  }
}

///|
/// Compiles a unary operator.
pub fn compile_unary_into(
  fs : FuncState,
  op : Int,
  operand : Expr,
  reg : Int,
  line : Int,
) -> Unit raise @core.LuaRaised {
  let saved = fs.freereg
  let rrk = compile_rk(fs, operand)
  fs.line = line
  let opcode = match op {
    @core.UNOP_MINUS => @core.OP_UNM
    @core.UNOP_NOT => @core.OP_NOT
    @core.UNOP_LEN => @core.OP_LEN
    @core.UNOP_BNOT => @core.OP_BNOT
    _ => @core.OP_MOVE
  }
  let _ = fs.emit_abc(opcode, reg, rrk, 0)
  fs.set_freereg(saved)
}

///|----------------------------------------------------------------
/// Calls

///|----------------------------------------------------------------

///|
/// A resolved assignment target.
pub(all) struct TargetPlan {
  kind : Int
  /// A local register, an upvalue index, or the register holding the table.
  slot : Int
  /// For an indexed target: the RK operand of the key.
  key_rk : Int
  name : @core.LStr
}
