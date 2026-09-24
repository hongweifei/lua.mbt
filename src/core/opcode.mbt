// Instruction set.

///|
/// `MAXREGS` in lcode.c: the register window a function may need, limited by
/// the byte-wide fields of the instruction encoding.
pub const MAX_REGS : Int = 255

///|
/// Maximum number of active local variables.
pub const MAX_VARS : Int = 200

///|
/// Maximum number of upvalues of a single function.
pub const MAX_UPVALS : Int = 255

///|
/// Maximum number of parameters.
pub const MAX_PARAMS : Int = 200

///|
/// Largest value of a Bx operand.
pub const MAX_BX : Int = 65535

///|
/// Base of the RK encoding: operands at or above this value index constants.
pub const RK_OFFSET : Int = 256

///|
/// Largest constant index usable inside an RK operand.
pub const MAX_INDEX_RK : Int = RK_OFFSET - 1

///|
pub fn rk_is_const(rk : Int) -> Bool {
  rk >= RK_OFFSET
}

///|
pub fn rk_index(rk : Int) -> Int {
  if rk >= RK_OFFSET {
    rk - RK_OFFSET
  } else {
    rk
  }
}

///|
/// `R[A] := R[B]`
pub const OP_MOVE : Int = 0

///|
/// `R[A] := K[Bx]`
pub const OP_LOADK : Int = 1

///|
/// `R[A], ..., R[A+B-1] := nil`
pub const OP_LOADNIL : Int = 2

///|
/// `R[A] := (B != 0)`
pub const OP_LOADBOOL : Int = 3

///|
/// `R[A] := U[B]`
pub const OP_GETUPVAL : Int = 4

///|
/// `U[B] := R[A]`
pub const OP_SETUPVAL : Int = 5

///|
/// `R[A] := R[B][RK(C)]`
pub const OP_GETTABLE : Int = 6

///|
/// `R[A][RK(B)] := RK(C)`
pub const OP_SETTABLE : Int = 7

///|
/// `R[A] := U[B][RK(C)]`
pub const OP_GETTABUP : Int = 8

///|
/// `U[A][RK(B)] := RK(C)`
pub const OP_SETTABUP : Int = 9

///|
/// `R[A] := {}`
pub const OP_NEWTABLE : Int = 10

///|
/// `R[A+1] := R[B]; R[A] := R[B][RK(C)]`
pub const OP_SELF : Int = 11

///|
pub const OP_ADD : Int = 12

///|
pub const OP_SUB : Int = 13

///|
pub const OP_MUL : Int = 14

///|
pub const OP_DIV : Int = 15

///|
pub const OP_MOD : Int = 16

///|
pub const OP_POW : Int = 17

///|
pub const OP_IDIV : Int = 18

///|
pub const OP_BAND : Int = 19

///|
pub const OP_BOR : Int = 20

///|
pub const OP_BXOR : Int = 21

///|
pub const OP_SHL : Int = 22

///|
pub const OP_SHR : Int = 23

///|
/// `R[A] := -R[B]`
pub const OP_UNM : Int = 24

///|
/// `R[A] := ~R[B]`
pub const OP_BNOT : Int = 25

///|
/// `R[A] := not R[B]`
pub const OP_NOT : Int = 26

///|
/// `R[A] := #R[B]`
pub const OP_LEN : Int = 27

///|
/// `R[A] := R[A] .. ... .. R[B]`
pub const OP_CONCAT : Int = 28

///|
/// `pc += sBx`
pub const OP_JMP : Int = 29

///|
/// `if (RK(B) == RK(C)) != A then pc++`
pub const OP_EQ : Int = 30

///|
/// `if (RK(B) < RK(C)) != A then pc++`
pub const OP_LT : Int = 31

///|
/// `if (RK(B) <= RK(C)) != A then pc++`
pub const OP_LE : Int = 32

///|
/// `if not (R[A] == C) then pc++`
pub const OP_TEST : Int = 33

///|
/// `if (R[B] == C) then R[A] := R[B] else pc++`
pub const OP_TESTSET : Int = 34

///|
/// `R[A], ..., R[A+C-2] := R[A](R[A+1], ..., R[A+B-1])`
pub const OP_CALL : Int = 35

///|
/// `return R[A](R[A+1], ..., R[A+B-1])`
pub const OP_TAILCALL : Int = 36

///|
/// `return R[A], ..., R[A+B-2]` (`B == 0` returns everything up to the top)
pub const OP_RETURN : Int = 37

///|
/// `R[A] -= R[A+2]; pc += C` (numeric `for` prologue; C lands on the loop test)
pub const OP_FORPREP : Int = 38

///|
/// `R[A] += R[A+2]; if R[A] <= R[A+1] then { R[A+3] := R[A]; pc += C }`
pub const OP_FORLOOP : Int = 39

///|
/// `R[A+3], ..., R[A+2+B] := R[A](R[A+1], R[A+2])`
pub const OP_TFORCALL : Int = 40

///|
/// `if R[A+3] ~= nil then { R[A+2] := R[A+3]; pc += C }`
pub const OP_TFORLOOP : Int = 41

///|
/// `R[A][C*i + j] := R[A+j]`
pub const OP_SETLIST : Int = 42

///|
/// `R[A] := closure(KPROTO[Bx])`
pub const OP_CLOSURE : Int = 43

///|
/// `R[A], ..., R[A+B-2] := vararg`
pub const OP_VARARG : Int = 44

///|
/// Close every upvalue and to-be-closed variable at or above register `A`.
pub const OP_CLOSE : Int = 45

///|
/// Mark `R[A]` as a to-be-closed variable.
pub const OP_TBC : Int = 46

///|
pub const OP_COUNT : Int = 47

///|
pub fn op_name(op : Int) -> String {
  match op {
    0 => "MOVE"
    1 => "LOADK"
    2 => "LOADNIL"
    3 => "LOADBOOL"
    4 => "GETUPVAL"
    5 => "SETUPVAL"
    6 => "GETTABLE"
    7 => "SETTABLE"
    8 => "GETTABUP"
    9 => "SETTABUP"
    10 => "NEWTABLE"
    11 => "SELF"
    12 => "ADD"
    13 => "SUB"
    14 => "MUL"
    15 => "DIV"
    16 => "MOD"
    17 => "POW"
    18 => "IDIV"
    19 => "BAND"
    20 => "BOR"
    21 => "BXOR"
    22 => "SHL"
    23 => "SHR"
    24 => "UNM"
    25 => "BNOT"
    26 => "NOT"
    27 => "LEN"
    28 => "CONCAT"
    29 => "JMP"
    30 => "EQ"
    31 => "LT"
    32 => "LE"
    33 => "TEST"
    34 => "TESTSET"
    35 => "CALL"
    36 => "TAILCALL"
    37 => "RETURN"
    38 => "FORPREP"
    39 => "FORLOOP"
    40 => "TFORCALL"
    41 => "TFORLOOP"
    42 => "SETLIST"
    43 => "CLOSURE"
    44 => "VARARG"
    45 => "CLOSE"
    46 => "TBC"
    _ => "?"
  }
}

///|
/// A single instruction.  Fields are named rather than bit packed so that the
/// compiler and the interpreter read the same way the manuals describe them.
pub(all) struct Instr {
  op : Int
  a : Int
  b : Int
  c : Int
}

///|
pub fn instr(op : Int, a : Int, b : Int, c : Int) -> Instr {
  { op, a, b, c, }
}

///|
/// Builds an instruction whose third operand is unused.
pub fn instr_ab(op : Int, a : Int, b : Int) -> Instr {
  { op, a, b, c: 0, }
}

///|
pub fn instr_a(op : Int, a : Int) -> Instr {
  { op, a, b: 0, c: 0, }
}

///|
pub fn Instr::to_text(self : Instr) -> String {
  op_name(self.op) +
  " " +
  self.a.to_string() +
  " " +
  self.b.to_string() +
  " " +
  self.c.to_string()
}

///|----------------------------------------------------------------
/// Disassembler

///|----------------------------------------------------------------

///|
/// Prints the instructions of a prototype and of every function it contains.
/// Used to inspect what the code generator produced.
pub fn dump_proto(p : LProto) -> Unit {
  println(
    "function " +
    p.name +
    " params=" +
    p.numparams.to_string() +
    " slots=" +
    p.maxstack.to_string(),
  )
  let mut i = 0
  while i < p.code.length() {
    println("  " + i.to_string() + "\t" + p.code[i].to_text())
    i = i + 1
  }
  for sub in p.protos {
    dump_proto(sub)
  }
}

///|
/// The disassembly of a prototype as a string, for embedding in diagnostics.
pub fn disassemble(p : LProto) -> String {
  let buf = StringBuilder()
  buf.write_string("function " + p.name + " params=" + p.numparams.to_string())
  let mut i = 0
  while i < p.code.length() {
    buf.write_string("\n  " + i.to_string() + "\t" + p.code[i].to_text())
    i = i + 1
  }
  for sub in p.protos {
    buf.write_string("\n" + disassemble(sub))
  }
  buf.to_string()
}
