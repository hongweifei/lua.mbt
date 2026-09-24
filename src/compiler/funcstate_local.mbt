// Locals, attributes and lexical scopes of the compiler state.

///|----------------------------------------------------------------
/// Locals and upvalues

///|----------------------------------------------------------------

///|
/// Declares a local variable, allocating its register.
pub fn FuncState::register_local(
  self : FuncState,
  name : @core.LStr,
) -> Unit raise @core.LuaRaised {
  self.register_local_attrib(name, ATTRIB_NONE)
}

///|
pub fn FuncState::register_local_attrib(
  self : FuncState,
  name : @core.LStr,
  attrib : Int,
) -> Unit raise @core.LuaRaised {
  if self.nactive + 1 > @core.MAX_VARS {
    self.errorlimit(@core.MAX_VARS, "local variables")
  }
  let reg = self.nactive
  self.reserve(1)
  self.locvars.push({
    name,
    start_pc: self.code.length(),
    end_pc: self.code.length(),
    attrib,
  })
  // `acts` holds indices into `locvars`.  Locals live at consecutive registers
  // starting from zero, so the position in `acts` is also the register.
  self.acts.push(self.locvars.length() - 1)
  self.nactive = self.nactive + 1
  if attrib == ATTRIB_CLOSE {
    let _ = self.emit_a(@core.OP_TBC, reg)
    if self.bl >= 0 {
      self.blocks[self.bl].inside_tbc = true
    }
    // Leaving the scope of a to-be-closed variable must close it, so the
    // enclosing block needs its closing instruction.
    self.mark_upvalue(reg + 1)
  }
}

///|
/// The attribute of the local variable living at register `reg`.
pub fn FuncState::local_attrib(self : FuncState, reg : Int) -> Int {
  if reg < 0 || reg >= self.acts.length() {
    return ATTRIB_NONE
  }
  self.locvars[self.acts[reg]].attrib
}

///|
/// Looks up a local variable by name in the active scope chain of this
/// function.  Returns its register, or -1.
pub fn FuncState::search_local(self : FuncState, name : @core.LStr) -> Int {
  let mut i = self.acts.length() - 1
  while i >= 0 {
    let idx = self.acts[i]
    if self.locvars[idx].name.equal(name) {
      return i
    }
    i = i - 1
  }
  -1
}

///|
/// Marks that a block must close upvalues on exit because a local in it is
/// captured.
pub fn FuncState::mark_upvalue(self : FuncState, level : Int) -> Unit {
  let mut b = self.bl
  while b >= 0 && self.blocks[b].nactive > level {
    b = self.blocks[b].previous
  }
  if b >= 0 {
    self.blocks[b].upval = true
  }
}

///|
/// Finds or creates an upvalue of this function holding the local or upvalue
/// described by the enclosing function.
pub fn FuncState::new_upvalue(
  self : FuncState,
  name : @core.LStr,
  in_stack : Bool,
  index : Int,
) -> Int raise @core.LuaRaised {
  // Reuse an existing descriptor when possible.
  let mut i = 0
  while i < self.upvals.length() {
    let d = self.upvals[i]
    if d.in_stack == in_stack && d.index == index {
      return i
    }
    i = i + 1
  }
  if self.nups >= @core.MAX_UPVALS {
    self.errorlimit(@core.MAX_UPVALS, "upvalues")
  }
  let attrib = if in_stack {
    // Capture the attribute of the enclosing local.
    match self.prev {
      Some(parent) => parent.local_attrib(index)
      None => ATTRIB_NONE
    }
  } else {
    match self.prev {
      Some(parent) => parent.upval_attrib(index)
      None => ATTRIB_NONE
    }
  }
  self.upvals.push({ name, in_stack, index, attrib, })
  self.nups = self.nups + 1
  self.upvals.length() - 1
}

///|
/// The attribute of an upvalue of this function.
pub fn FuncState::upval_attrib(self : FuncState, idx : Int) -> Int {
  if idx < 0 || idx >= self.upvals.length() {
    return ATTRIB_NONE
  }
  self.upvals[idx].attrib
}

///|
/// Expands to the "not found" kind returned by `resolve_name`.
pub const VVOID : Int = 0

///|
/// A local variable; the second component of the pair is its register.
pub const VLOCAL : Int = 1

///|
/// An upvalue; the second component is its index in this function.
pub const VUPVAL : Int = 2

///|
/// Resolves a name to a local, an upvalue, or nothing at all (meaning it is a
/// global).  `for_assignment` marks locals that get captured, so the enclosing
/// block remembers to close them.
pub fn FuncState::resolve_name(
  self : FuncState,
  name : @core.LStr,
  captured : Bool,
) -> (Int, Int) raise @core.LuaRaised {
  let slot = self.search_local(name)
  if slot >= 0 {
    if captured {
      self.mark_upvalue(slot)
    }
    return (VLOCAL, slot)
  }
  // Try the enclosing function.
  match self.prev {
    Some(parent) => {
      let (pk, pidx) = parent.resolve_name(name, true)
      if pk == VLOCAL {
        let idx = self.new_upvalue(name, true, pidx)
        return (VUPVAL, idx)
      } else if pk == VUPVAL {
        let idx = self.new_upvalue(name, false, pidx)
        return (VUPVAL, idx)
      }
      return (VVOID, 0)
    }
    None =>
      // The outermost function holds its environment in upvalue 0, which the
      // * loader binds to the global table.
      if self.upvals.length() > 0 && self.upvals[0].name.equal(name) {
        (VUPVAL, 0)
      } else {
        (VVOID, 0)
      }
  }
}

///|
/// The register at which the `n`-th active local lives.  Local variables occupy
/// consecutive registers from zero, so the index is the register.
pub fn FuncState::register_of_local(self : FuncState, n : Int) -> Int {
  let _ = self
  n
}

///|----------------------------------------------------------------
/// Scopes

///|----------------------------------------------------------------

///|
pub fn FuncState::enter_block(self : FuncState, is_loop : Bool) -> Unit {
  // A nested block stays inside the scope of an enclosing to-be-closed
  // variable, so a `return f()` in it is still not a tail call.
  let in_tbc = self.bl >= 0 && self.blocks[self.bl].inside_tbc
  let b : BlockState = {
    first_label: self.labels.length(),
    first_goto: self.gotos.length(),
    nactive: self.nactive,
    upval: false,
    is_loop,
    previous: self.bl,
    inside_tbc: in_tbc,
    break_list: NO_JUMP,
  }
  self.blocks.push(b)
  self.bl = self.blocks.length() - 1
}

///|
/// Leaves the current block, closing its upvalues, patching its `break` list
/// and moving unresolved gotos outward.
pub fn FuncState::leave_block(self : FuncState) -> Unit raise @core.LuaRaised {
  let blk = self.blocks[self.bl]
  let level = blk.nactive
  self.remove_locals(level)
  self.free_from(level)
  self.set_freereg(level)
  if blk.upval {
    let close_pc = self.here()
    let _ = self.emit_a(@core.OP_CLOSE, level)
    // A `break` out of a loop that owns something to close lands *on* that
    // instruction, not past it, so leaving the loop early still runs the
    // handlers -- the reference puts the close at the break label itself.
    if blk.is_loop {
      self.patch_list(self.blocks[self.bl].break_list, close_pc)
      self.blocks[self.bl].break_list = NO_JUMP
    }
  } else if blk.is_loop {
    self.patch_here(self.blocks[self.bl].break_list)
    self.blocks[self.bl].break_list = NO_JUMP
  }
  // Labels declared in this block go out of scope with it; a label can be
  // reused once its block has ended.
  self.labels.truncate(blk.first_label)
  let previous = blk.previous
  self.bl = previous
  if previous >= 0 {
    self.move_gotos_out(blk)
  } else if blk.first_goto < self.gotos.length() {
    let g = self.gotos[blk.first_goto]
    self.undefined_goto(g)
  }
}

///|
/// Reports a goto that never found its label.
pub fn[T] FuncState::undefined_goto(
  self : FuncState,
  g : GotoDesc,
) -> T raise @core.LuaRaised {
  self.semantic_error(
    "no visible label '" +
    @core.text_of(g.name.data()) +
    "' for <goto> at line " +
    g.line.to_string(),
  )
}

///|
/// Reports an error that is not tied to a token; the position is the current
/// line of the function.
pub fn[T] FuncState::semantic_error(
  self : FuncState,
  msg : String,
) -> T raise @core.LuaRaised {
  let full = @core.text_of(self.source.data()) +
    ":" +
    self.line.to_string() +
    ": " +
    msg
  raise @core.LuaRaised(@core.VStr(@core.LStr::of_string(full)))
}

///|----------------------------------------------------------------
/// Labels and gotos

///|----------------------------------------------------------------

///|
/// Produces the prototype from everything accumulated so far.
pub fn FuncState::finalize(self : FuncState) -> @core.LProto {
  if self.bl >= 0 {
    self.bl = -1
  }
  let mut last = self.last_line_defined
  if last < self.line_defined {
    last = self.line_defined
  }
  {
    code: self.code,
    lines: self.lines,
    constants: self.constants,
    protos: self.protos,
    upvals: self.upvals,
    numparams: self.numparams,
    is_vararg: self.is_vararg,
    maxstack: self.maxstack + 8,
    source: self.source,
    line_defined: self.line_defined,
    last_line_defined: last,
    locvars: self.locvars,
    name: self.name,
  }
}
