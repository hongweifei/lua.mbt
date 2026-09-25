// The compiler state of one function: code, jumps, patching.

///|
pub(all) struct LabelDesc {
  name : @core.LStr
  pc : Int
  nactive : Int
  line : Int
}

///|
/// A `goto` whose label has not been seen yet.
pub(all) struct GotoDesc {
  name : @core.LStr
  jump : Int
  line : Int
  nactive : Int
}

///|
/// An open scope.
pub(all) struct BlockState {
  first_label : Int
  first_goto : Int
  nactive : Int
  mut upval : Bool
  is_loop : Bool
  previous : Int
  mut inside_tbc : Bool
  mut break_list : Int
}

///|
pub const NO_JUMP : Int = -1

///|
pub const NO_REG : Int = -1

///|
/// A function being compiled.
pub(all) struct FuncState {
  prev : FuncState?
  code : Array[@core.Instr]
  lines : Array[Int]
  constants : Array[@core.Value]
  /// The constant pool's index, by kind.  Strings, integers and floats are
  /// what a program actually repeats, and keying them through a boxed `Key`
  /// costs a collection per lookup in the middle of code generation, so each
  /// of those kinds gets a table with a key of its own; anything else goes
  /// through `kcache`.
  kcache : Map[@core.Key, Int]
  kcache_str : Map[@core.LStr, Int]
  kcache_int : Map[Int64, Int]
  kcache_num : Map[UInt64, Int]
  protos : Array[@core.LProto]
  upvals : Array[@core.UpvalDesc]
  locvars : Array[@core.LocVar]
  acts : Array[Int]
  labels : Array[LabelDesc]
  gotos : Array[GotoDesc]
  blocks : Array[BlockState]
  mut bl : Int
  mut nactive : Int
  mut freereg : Int
  mut maxstack : Int
  mut nups : Int
  mut line : Int
  source : @core.LStr
  name : String
  line_defined : Int
  mut last_line_defined : Int
  is_vararg : Bool
  numparams : Int
  /// Nesting depth, guarding the host stack while compiling deeply nested
  /// expressions.
  depth : Int
}

///|
pub fn FuncState::new(
  prev : FuncState?,
  source : @core.LStr,
  name : String,
  line_defined : Int,
  numparams : Int,
  is_vararg : Bool,
) -> FuncState {
  let fs : FuncState = {
    prev,
    code: [],
    lines: [],
    constants: [],
    kcache: Map([]),
    kcache_str: Map([]),
    kcache_int: Map([]),
    kcache_num: Map([]),
    protos: [],
    upvals: [],
    locvars: [],
    acts: [],
    labels: [],
    gotos: [],
    blocks: [],
    bl: -1,
    nactive: 0,
    freereg: 0,
    maxstack: 2,
    nups: 0,
    line: line_defined,
    source,
    name,
    line_defined,
    last_line_defined: line_defined,
    is_vararg,
    numparams,
    depth: 0,
  }
  fs.enter_block(false)
  // Parameters occupy the first registers.
  fs
}

///|----------------------------------------------------------------
/// Instruction emission

///|----------------------------------------------------------------

///|
pub fn FuncState::emit(self : FuncState, i : @core.Instr) -> Int {
  self.code.push(i)
  self.lines.push(self.line)
  self.code.length() - 1
}

///|
pub fn FuncState::emit_abc(
  self : FuncState,
  op : Int,
  a : Int,
  b : Int,
  c : Int,
) -> Int {
  self.emit(@core.instr(op, a, b, c))
}

///|
pub fn FuncState::emit_a(self : FuncState, op : Int, a : Int) -> Int {
  self.emit(@core.instr(op, a, 0, 0))
}

///|
pub fn FuncState::emit_ab(self : FuncState, op : Int, a : Int, b : Int) -> Int {
  self.emit(@core.instr(op, a, b, 0))
}

///|
/// Change the line recorded for the instruction just emitted, which is what
/// `luaK_fixline` does for code whose place in the source is not where it was
/// read.
pub fn FuncState::fixline(self : FuncState, line : Int) -> Unit {
  let n = self.lines.length()
  if n > 0 {
    self.lines[n - 1] = line
  }
}

///|
pub fn FuncState::replace(self : FuncState, pc : Int, i : @core.Instr) -> Unit {
  self.code[pc] = i
}

///|
pub fn FuncState::code_at(self : FuncState, pc : Int) -> @core.Instr {
  self.code[pc]
}

///|----------------------------------------------------------------
/// Register allocation

///|----------------------------------------------------------------

///|
/// Emits an unconditional jump and returns its position.
pub fn FuncState::emit_jump(self : FuncState) -> Int {
  let pc = self.emit(@core.instr(@core.OP_JMP, 0, 0, NO_JUMP))
  pc
}

///|
/// The absolute position a jump points at, or `NO_JUMP` at the end of a list.
pub fn FuncState::jump_target(self : FuncState, pc : Int) -> Int {
  let offset = self.code[pc].c
  if offset == NO_JUMP {
    NO_JUMP
  } else {
    pc + 1 + offset
  }
}

///|
/// Redirects a jump.
pub fn FuncState::fix_jump(self : FuncState, pc : Int, target : Int) -> Unit {
  let i = self.code[pc]
  self.code[pc] = @core.instr(i.op, i.a, i.b, target - (pc + 1))
}

///|
/// Writes a raw pc offset into a branch instruction.
pub fn FuncState::set_offset(self : FuncState, pc : Int, offset : Int) -> Unit {
  let i = self.code[pc]
  self.code[pc] = @core.instr(i.op, i.a, i.b, offset)
}

///|
/// Sets the close level of a jump, used when a `goto` leaves a scope that has
/// upvalues to close.
pub fn FuncState::set_jump_close(
  self : FuncState,
  pc : Int,
  level : Int,
) -> Unit {
  let i = self.code[pc]
  if i.a == 0 || i.a > level + 1 {
    self.code[pc] = @core.instr(i.op, level + 1, i.b, i.c)
  }
}

///|
/// Appends one patch list to another.
pub fn FuncState::concat_jump_list(self : FuncState, l1 : Int, l2 : Int) -> Int {
  if l1 == NO_JUMP {
    return l2
  }
  let mut list = l1
  while true {
    let next = self.jump_target(list)
    if next == NO_JUMP {
      // The last jump of the first list now points directly at the head of the
      // second list.
      self.fix_jump(list, l2)
      return l1
    }
    list = next
  }
  l1
}

///|
/// Resolves every jump in a list to point at `target`.
pub fn FuncState::patch_list(
  self : FuncState,
  list : Int,
  target : Int,
) -> Unit {
  let mut l = list
  while l != NO_JUMP {
    let next = self.jump_target(l)
    self.fix_jump(l, target)
    l = next
  }
}

///|
/// Resolves a list to point just past the last emitted instruction.
pub fn FuncState::patch_here(self : FuncState, list : Int) -> Unit {
  self.patch_list(list, self.code.length())
}

///|
pub fn FuncState::here(self : FuncState) -> Int {
  self.code.length()
}
