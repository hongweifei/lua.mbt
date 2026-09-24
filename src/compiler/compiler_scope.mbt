// Locals, upvalues, scopes, labels and gotos.

///|
/// Drops the locals declared above `level`.
pub fn FuncState::remove_locals(self : FuncState, level : Int) -> Unit {
  while self.acts.length() > level {
    let idx = self.acts[self.acts.length() - 1]
    self.locvars[idx].end_pc = self.code.length()
    let _ = self.acts.pop()
  }
  self.nactive = level
}

///|
/// Finds a label with the given name in the block currently being left.
/// Labels belong to the whole function, not to the block that declares them,
/// so a `goto` can reach one in an enclosing or earlier block.
pub fn FuncState::find_label(self : FuncState, name : @core.LStr) -> Int {
  let mut i = 0
  while i < self.labels.length() {
    if self.labels[i].name.equal(name) {
      return i
    }
    i = i + 1
  }
  -1
}

///|
/// Resolves gotos of the block being left that now have a visible label.
pub fn FuncState::move_gotos_out(
  self : FuncState,
  blk : BlockState,
) -> Unit raise @core.LuaRaised {
  let parent = blk.previous
  let mut i = blk.first_goto
  while i < self.gotos.length() {
    let g = self.gotos[i]
    if g.nactive > blk.nactive {
      if blk.upval {
        self.set_jump_close(g.jump, blk.nactive)
      }
      self.gotos[i] = {
        name: g.name,
        jump: g.jump,
        line: g.line,
        nactive: blk.nactive,
      }
    }
    let found = self.find_label(g.name)
    if found >= 0 {
      self.close_goto(i, found)
      // close_goto removes the entry, so the same index now holds the next.
    } else {
      i = i + 1
    }
    let _ = parent
  }
}

///|
/// Patches a goto to its label, rejecting jumps into the scope of a local.
pub fn FuncState::close_goto(
  self : FuncState,
  gi : Int,
  li : Int,
) -> Unit raise @core.LuaRaised {
  let g = self.gotos[gi]
  let l = self.labels[li]
  if g.nactive < l.nactive {
    let vname = self.locvars[self.acts[g.nactive]].name
    self.semantic_error(
      "<goto " +
      @core.text_of(g.name.data()) +
      "> at line " +
      g.line.to_string() +
      " jumps into the scope of local '" +
      @core.text_of(vname.data()) +
      "'",
    )
  }
  self.patch_list(g.jump, l.pc)
  let _ = self.gotos.remove(gi)
}

///|

///|
/// `errorlimit`: a blown compile-time limit is reported with the limit itself
/// and the function it belongs to.
pub fn FuncState::errorlimit(
  self : FuncState,
  limit : Int,
  what : String,
) -> Unit raise @core.LuaRaised {
  let place = if self.line_defined == 0 {
    "main function"
  } else {
    "function at line " + self.line_defined.to_string()
  }
  self.semantic_error(
    "too many " + what + " (limit is " + limit.to_string() + ") in " + place,
  )
}

///|
pub fn FuncState::too_many_registers(
  self : FuncState,
) -> Unit raise @core.LuaRaised {
  self.semantic_error("function or expression needs too many registers")
}

///|
/// Defines a label at the current position.  When `last`, the label is the
/// last no-op statement of its block, so locals declared in the block are
/// already out of scope for gotos that arrive here, as createlabel assumes
/// in the reference implementation.
pub fn FuncState::create_label(
  self : FuncState,
  name : @core.LStr,
  line : Int,
  last : Bool,
) -> Unit raise @core.LuaRaised {
  // A label name must be unique among the labels still alive: this block and
  // every enclosing block that has not been left yet.  Labels of sibling
  // blocks are gone by then, so the usual `continue` pattern stays legal.
  let mut i = 0
  while i < self.labels.length() {
    if self.labels[i].name.equal(name) {
      self.semantic_error(
        "label '" +
        @core.text_of(name.data()) +
        "' already defined on line " +
        self.labels[i].line.to_string(),
      )
    }
    i = i + 1
  }
  let saved = self.nactive
  if last {
    self.nactive = self.blocks[self.bl].nactive
  }
  self.labels.push({ name, pc: self.here(), nactive: self.nactive, line, })
  // Resolve gotos in this block that were waiting for this label.
  let mut i = self.blocks[self.bl].first_goto
  while i < self.gotos.length() {
    if self.gotos[i].name.equal(name) {
      self.close_goto(i, self.labels.length() - 1)
    } else {
      i = i + 1
    }
  }
  self.nactive = saved
}

///|
/// Registers a pending `goto`.
pub fn FuncState::create_goto(
  self : FuncState,
  name : @core.LStr,
  line : Int,
  jump : Int,
) -> Unit {
  self.gotos.push({ name, jump, line, nactive: self.nactive, })
}

///|
/// Emits a jump that the innermost loop resolves when it ends.
pub fn FuncState::add_break(self : FuncState) -> Unit raise @core.LuaRaised {
  let mut b = self.bl
  while b >= 0 && !self.blocks[b].is_loop {
    b = self.blocks[b].previous
  }
  if b < 0 {
    self.semantic_error("break outside a loop")
  }
  // The break crosses every block between here and the loop: if any of them
  // captures locals (the numeric for control variable is one), a break that
  // jumps out mid-iteration skips that block's own closing instruction, so
  // close the captured slots here first.
  let mut need = false
  let mut c = self.bl
  while c >= 0 && c != b {
    if self.blocks[c].upval {
      need = true
    }
    c = self.blocks[c].previous
  }
  if need {
    let _ = self.emit_a(@core.OP_CLOSE, self.blocks[b].nactive)
  }
  let pc = self.emit_jump()
  let list = self.blocks[b].break_list
  self.blocks[b].break_list = self.concat_jump_list(list, pc)
}

///|----------------------------------------------------------------
/// Finalisation

///|----------------------------------------------------------------
