// Code generation for statements.

///|
/// Compiles a block in its own scope.  `end_follows` says whether the block
/// is closed by `end` / `else` / the end of the function (as opposed to
/// `until`, which can read locals declared in the body).
pub fn compile_block(
  fs : FuncState,
  blk : Block,
  end_follows : Bool,
) -> Unit raise @core.LuaRaised {
  fs.enter_block(false)
  compile_stat_list(fs, blk, end_follows)
  fs.leave_block()
}

///|
/// Compiles the statements of a block.  When `end_follows`, a run of labels at
/// the end of the list counts as the last no-op statement of the block: a goto
/// to them may jump over locals declared earlier in the block, because the
/// locals are out of scope again by the time the jump lands.
///
/// The block's exit line is left in `fs.line`, because that is where the
/// reference puts the jumps emitted as the block closes.
pub fn compile_stat_list(
  fs : FuncState,
  blk : Block,
  end_follows : Bool,
) -> Unit raise @core.LuaRaised {
  let stats = blk.stats
  let total = stats.length()
  let mut ntail = 0
  if end_follows {
    while ntail < total {
      match stats[total - 1 - ntail] {
        SLabel(_, _) => ntail = ntail + 1
        _ => break
      }
    }
  }
  let tail_start = total - ntail
  let mut i = 0
  while i < total {
    let s = stats[i]
    if i >= tail_start {
      match s {
        SLabel(name, line) => {
          fs.line = line
          fs.create_label(name, line, true)
        }
        _ => compile_stat(fs, s)
      }
    } else {
      compile_stat(fs, s)
    }
    i = i + 1
  }
  fs.line = blk.exit_line
}

///|----------------------------------------------------------------
/// Expressions

///|----------------------------------------------------------------

///|
/// Evaluates the table and key of every indexed target before the right hand
/// side runs.  That is what makes `a, a.b = 1, 2` write the field of the old
/// `a`, matching the reference implementation.
pub fn plan_targets(
  fs : FuncState,
  targets : Array[Expr],
) -> Array[TargetPlan] raise @core.LuaRaised {
  let plans : Array[TargetPlan] = []
  for t in targets {
    match t {
      EName(name, line) => {
        fs.line = line
        let (kind, idx) = fs.resolve_name(name, true)
        if kind == VLOCAL && fs.local_attrib(idx) != ATTRIB_NONE {
          fs.semantic_error(
            "attempt to assign to const variable '" +
            @core.text_of(name.data()) +
            "'",
          )
        }
        if kind == VUPVAL && fs.upval_attrib(idx) != ATTRIB_NONE {
          fs.semantic_error(
            "attempt to assign to const variable '" +
            @core.text_of(name.data()) +
            "'",
          )
        }
        let k = if kind == VLOCAL {
          VLOCAL
        } else if kind == VUPVAL {
          VUPVAL
        } else {
          VVOID
        }
        plans.push({ kind: k, slot: idx, key_rk: 0, name, })
      }
      EIndex(obj, key, line) => {
        fs.line = line
        // The temporaries are deliberately not released: they have to survive
        // until the stores run, so `freereg` keeps climbing.
        let treg = compile_base_reg(fs, obj)
        let krk = compile_rk(fs, key)
        plans.push({
          kind: 3,
          slot: treg,
          key_rk: krk,
          name: @core.LStr::empty(),
        })
      }
      _ => fs.semantic_error("cannot assign to this expression")
    }
  }
  resolve_target_conflicts(fs, plans)
  plans
}

///|
/// Resolves what the assignment's own targets do to each other.  An indexed
/// target reads its table and its key when it is *stored*, and the stores run
/// from the last target to the first, so a later target that assigns to a local
/// would change what an earlier one writes into -- `i, a[i], a = 1, 2, 3` would
/// index a number.  The reference copies such a local to a temporary and makes
/// the earlier target read that instead (`check_conflict`), and the copy is
/// emitted here, before the right hand side is evaluated.
fn resolve_target_conflicts(
  fs : FuncState,
  plans : Array[TargetPlan],
) -> Unit raise @core.LuaRaised {
  let mut i = 0
  while i < plans.length() {
    let p = plans[i]
    if p.kind == VLOCAL {
      // One copy per conflicting target, as `check_conflict` makes.
      let mut extra = -1
      let mut j = 0
      while j < i {
        let q = plans[j]
        let key_is_slot = q.kind == 3 &&
          q.key_rk < @core.RK_OFFSET &&
          q.key_rk == p.slot
        if q.kind == 3 && (q.slot == p.slot || key_is_slot) {
          if extra < 0 {
            extra = fs.freereg
            fs.reserve(1)
            let _ = fs.emit_abc(@core.OP_MOVE, extra, p.slot, 0)
          }
          plans[j] = {
            kind: q.kind,
            slot: if q.slot == p.slot {
              extra
            } else {
              q.slot
            },
            key_rk: if key_is_slot {
              extra
            } else {
              q.key_rk
            },
            name: q.name,
          }
        }
        j = j + 1
      }
    }
    i = i + 1
  }
}

///|
/// Compiles `targets = values`.
pub fn compile_assignment(
  fs : FuncState,
  targets : Array[Expr],
  values : Array[Expr],
  line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  let nat = targets.length()
  let plans = plan_targets(fs, targets)
  let vbase = fs.freereg
  let _ = compile_value_list(fs, values, vbase, nat)
  // Store from the last target to the first, like the reference implementation.
  let mut i = nat - 1
  while i >= 0 {
    let p = plans[i]
    let src = vbase + i
    if p.kind == VLOCAL {
      if p.slot != src {
        let _ = fs.emit_abc(@core.OP_MOVE, p.slot, src, 0)
      }
    } else if p.kind == VUPVAL {
      let _ = fs.emit_ab(@core.OP_SETUPVAL, src, p.slot)
    } else if p.kind == VVOID {
      emit_env_set(fs, p.name, src)
    } else {
      let _ = fs.emit_abc(@core.OP_SETTABLE, p.slot, p.key_rk, src)
    }
    i = i - 1
  }
  fs.free_all()
}

///|
/// Compiles one statement.
pub fn compile_stat(fs : FuncState, s : Stat) -> Unit raise @core.LuaRaised {
  match s {
    SLocal(decls, values, line) => {
      fs.line = line
      let base = fs.nactive
      fs.set_freereg(base)
      // The initializer is compiled before the new names exist: a variable is
      // visible only in the statements that follow its declaration, so
      // `local x = x` reads the outer `x` and the call below can use the
      // registers the locals are about to take.
      let _ = compile_value_list(fs, values, base, decls.length())
      // The values are already sitting in the registers the locals will use.
      fs.set_freereg(base)
      for d in decls {
        fs.line = d.line
        fs.register_local_attrib(d.name, d.attrib)
      }
      fs.free_all()
    }
    SAssign(targets, values, line) =>
      compile_assignment(fs, targets, values, line)
    SCall(e) => {
      // `compile_call` reserves the callee's slot itself, and leaving the
      // expression's registers behind would keep a stale value inside the
      // frame's live window: the collector would read it as reachable and the
      // debugger as a `(temporary)`.
      let _ = compile_call(fs, e, 0)
      fs.free_all()
    }
    SDo(body) => compile_block(fs, body, true)
    SWhile(cond, body, line) => compile_while(fs, cond, body, line)
    SRepeat(body, cond, line) => compile_repeat(fs, body, cond, line)
    SIf(clauses, else_block, line) => compile_if(fs, clauses, else_block, line)
    SNumericFor(name, e1, e2, e3, body, line, do_line) =>
      compile_numeric_for(fs, name, e1, e2, e3, body, line, do_line)
    SGenericFor(names, exprs, body, line, do_line, expr_line) =>
      compile_generic_for(fs, names, exprs, body, line, do_line, expr_line)
    SFunction(target, body, line) => {
      fs.line = line
      let reg = fs.freereg
      fs.reserve(1)
      compile_closure(fs, body, reg)
      store_single(fs, target, reg, body.last_line)
      fs.set_freereg(reg)
      fs.free_all()
    }
    SLocalFunction(name, body, line) => {
      fs.line = line
      let reg = fs.nactive
      fs.register_local(name)
      fs.set_freereg(reg + 1)
      compile_closure(fs, body, reg)
      fs.free_all()
    }
    SReturn(exprs, line) => {
      fs.line = line
      let base = fs.nactive
      let in_tbc = fs.bl >= 0 && fs.blocks[fs.bl].inside_tbc
      let single_call = exprs.length() == 1 && is_call(exprs[0]) && !in_tbc
      if exprs.length() == 0 {
        let _ = fs.emit_ab(@core.OP_RETURN, base, 1)
      } else if single_call {
        // `return f(x)` is a tail call: the callee takes the first free slot,
        // the call asks for every result, and its opcode becomes TAILCALL.
        // The RETURN the reference leaves behind is unreachable but keeps the
        // instruction stream shaped the same way.
        fs.set_freereg(base)
        let r = compile_multi(fs, exprs[0], -1)
        let pc = fs.here() - 1
        let c = fs.code_at(pc)
        if r == base && c.op == @core.OP_CALL {
          fs.replace(pc, @core.instr(@core.OP_TAILCALL, c.a, c.b, c.c))
        }
        let _ = fs.emit_ab(@core.OP_RETURN, base, 0)
      } else {
        let n = compile_value_list(fs, exprs, base, -1)
        let b = if n < 0 { 0 } else { n + 1 }
        let _ = fs.emit_ab(@core.OP_RETURN, base, b)
      }
      fs.free_all()
    }
    SBreak(line) => {
      fs.line = line
      fs.add_break()
    }
    SGoto(name, line) => {
      fs.line = line
      let li = fs.find_label(name)
      if li >= 0 {
        // Backward jump to a label of this block: resolved right here, as
        // gotostat does in the reference implementation.  A jump that leaves
        // the scope of locals declared after the label closes them first.
        let l = fs.labels[li]
        if fs.nactive > l.nactive {
          let _ = fs.emit_a(@core.OP_CLOSE, l.nactive)
        }
        let jump = fs.emit_jump()
        fs.patch_list(jump, l.pc)
      } else {
        // Forward jump: pending until the label is declared.
        let jump = fs.emit_jump()
        fs.create_goto(name, line, jump)
      }
    }
    SLabel(name, line) => {
      fs.line = line
      fs.create_label(name, line, false)
    }
  }
}

///|
/// Stores a single value into an assignment target.
pub fn store_single(
  fs : FuncState,
  target : Expr,
  src : Int,
  line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  match target {
    EName(name, _) => {
      let (kind, idx) = fs.resolve_name(name, true)
      if kind == VLOCAL && fs.local_attrib(idx) != ATTRIB_NONE {
        fs.semantic_error(
          "attempt to assign to const variable '" +
          @core.text_of(name.data()) +
          "'",
        )
      }
      if kind == VLOCAL {
        if idx != src {
          let _ = fs.emit_abc(@core.OP_MOVE, idx, src, 0)
        }
      } else if kind == VUPVAL {
        let _ = fs.emit_ab(@core.OP_SETUPVAL, src, idx)
      } else {
        emit_env_set(fs, name, src)
      }
    }
    EIndex(obj, key, _) => {
      let saved = fs.freereg
      fs.set_freereg(src + 1)
      let treg = compile_base_reg(fs, obj)
      let krk = compile_rk(fs, key)
      let _ = fs.emit_abc(@core.OP_SETTABLE, treg, krk, src)
      fs.set_freereg(saved)
    }
    _ => fs.semantic_error("cannot assign to this expression")
  }
}

///|
/// Whether a condition is a literal that cannot be false.  The reference emits
/// no test and no jump for one, so neither does this compiler: `while true do`
/// is only its body and the jump back.
fn always_true(e : Expr) -> Bool {
  match e {
    ETrue(_) | EInt(_, _) | EFloat(_, _) | EString(_, _) => true
    EParen(inner, _) => always_true(inner)
    _ => false
  }
}

///|
pub fn compile_while(
  fs : FuncState,
  cond : Expr,
  body : Block,
  line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  fs.enter_block(true)
  let top = fs.here()
  let mut exit = NO_JUMP
  if !always_true(cond) {
    let saved = fs.freereg
    let creg = compile_expr(fs, cond)
    fs.set_freereg(saved)
    let _ = fs.emit_abc(@core.OP_TEST, creg, 0, 0)
    exit = fs.emit_jump()
  }
  compile_block(fs, body, true)
  let back = fs.emit_jump()
  fs.patch_list(back, top)
  fs.patch_here(exit)
  fs.leave_block()
}

///|
/// `repeat ... until cond`: the condition can see the variables declared in the
/// body, so the body scope is closed only after the condition has been read.
pub fn compile_repeat(
  fs : FuncState,
  body : Block,
  cond : Expr,
  line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  fs.enter_block(true)
  let top = fs.here()
  fs.enter_block(false)
  compile_stat_list(fs, body, false)
  let saved = fs.freereg
  let creg = compile_expr(fs, cond)
  fs.set_freereg(saved)
  fs.leave_block()
  let _ = fs.emit_abc(@core.OP_TEST, creg, 0, 0)
  let again = fs.emit_jump()
  let exit = fs.emit_jump()
  fs.patch_here(again)
  let back = fs.emit_jump()
  fs.patch_list(back, top)
  fs.patch_here(exit)
  fs.leave_block()
}

///|
pub fn compile_if(
  fs : FuncState,
  clauses : Array[(Expr, Block, Int)],
  else_block : Block?,
  line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  let mut end_list = NO_JUMP
  let n = clauses.length()
  let mut i = 0
  while i < n {
    let (cond, body, then_line) = clauses[i]
    let mut next = NO_JUMP
    if !always_true(cond) {
      let saved = fs.freereg
      let creg = compile_expr(fs, cond)
      fs.set_freereg(saved)
      // The test that skips the body belongs to the `then`, not to the
      // condition that precedes it.
      fs.line = then_line
      let _ = fs.emit_abc(@core.OP_TEST, creg, 0, 0)
      next = fs.emit_jump()
    }
    compile_block(fs, body, true)
    let is_last = i == n - 1
    let has_else = match else_block {
      Some(_) => true
      None => false
    }
    if !(is_last && !has_else) {
      let j = fs.emit_jump()
      end_list = fs.concat_jump_list(end_list, j)
    }
    fs.patch_here(next)
    i = i + 1
  }
  match else_block {
    Some(b) => compile_block(fs, b, true)
    None => ()
  }
  fs.patch_here(end_list)
}

///|
pub fn compile_numeric_for(
  fs : FuncState,
  name : @core.LStr,
  e1 : Expr,
  e2 : Expr,
  e3 : Expr?,
  body : Block,
  line : Int,
  do_line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  fs.enter_block(true)
  let base = fs.nactive
  fs.set_freereg(base)
  // Three control registers, then the visible variable.
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.set_freereg(base)
  fs.reserve(1)
  compile_expr_into(fs, e1, base)
  fs.set_freereg(base + 2)
  compile_expr_into(fs, e2, base + 1)
  fs.set_freereg(base + 3)
  match e3 {
    Some(e) => compile_expr_into(fs, e, base + 2)
    None => fs.load_const(base + 2, @core.VInt(1L))
  }
  // The setup belongs to the `do`, the test to the `for`.
  fs.line = do_line
  let prep = fs.here()
  let _ = fs.emit_abc(@core.OP_FORPREP, base, 0, 0)
  let body_start = fs.here()
  fs.enter_block(false)
  fs.register_local(name)
  compile_stat_list(fs, body, true)
  fs.leave_block()
  // The test that runs the next round is attributed to the `for`, however far
  // into the body it sits.
  fs.line = line
  let loop_pc = fs.here()
  let _ = fs.emit_abc(@core.OP_FORLOOP, base, 0, 0)
  fs.set_offset(prep, loop_pc - (prep + 1))
  fs.set_offset(loop_pc, body_start - (loop_pc + 1))
  fs.leave_block()
}

///|
pub fn compile_generic_for(
  fs : FuncState,
  names : Array[@core.LStr],
  exprs : Array[Expr],
  body : Block,
  line : Int,
  do_line : Int,
  expr_line : Int,
) -> Unit raise @core.LuaRaised {
  fs.line = line
  fs.enter_block(true)
  let base = fs.nactive
  fs.set_freereg(base)
  // The generator, the state, the control variable, and one more slot for a
  // value the loop has to close when it ends.
  let _ = compile_value_list(fs, exprs, base, 4)
  fs.set_freereg(base)
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.register_local(@core.LStr::of_string("(for state)"))
  fs.register_local_attrib(@core.LStr::of_string("(for state)"), ATTRIB_CLOSE)
  fs.set_freereg(base + 4)
  fs.line = do_line
  let prep = fs.emit_jump()
  let body_start = fs.here()
  fs.enter_block(false)
  for n in names {
    fs.register_local(n)
  }
  compile_stat_list(fs, body, true)
  fs.leave_block()
  fs.patch_here(prep)
  // Both the implicit call and the loop test belong to the line the iterator
  // expressions start on, wherever in the source they end up.
  fs.line = expr_line
  let _ = fs.emit_ab(@core.OP_TFORCALL, base, names.length())
  let loop_pc = fs.here()
  let _ = fs.emit_abc(@core.OP_TFORLOOP, base, 0, body_start - (loop_pc + 1))
  fs.leave_block()
}
