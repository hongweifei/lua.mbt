///|----------------------------------------------------------------
/// The `luac -l` listing.
///
/// The layout follows the reference's `luac.c` (`PrintHeader`, `PrintCode`,
/// `PrintDebug`), including how a printed constant is escaped.  Two parts of
/// that listing cannot be the same here, and neither difference is cosmetic:
///
/// - the instructions are this interpreter's own set: 47 of them, each kept as
///   named `a`/`b`/`c` fields rather than the reference's packed `RK`/`sBx`/`k`
///   operands.  So the opcode names and the operand numbers are ours, and the
///   comment on each line says what our fields mean;
/// - the reference prints the address of every `Proto` (`%p`) and uses it to tie
///   a `CLOSURE` to the function it builds.  There is no such address to print
///   from MoonBit, so a `CLOSURE` names the function instead, and the tables a
///   full listing adds say whose they are in their own heading.
///
/// A name that the host did not encode in UTF-8 reads here through the same
/// lossy conversion every MoonBit string does; an *error message* about that
/// name keeps its bytes.  Nothing else in the listing can carry a byte a
/// terminal would not take: a constant is escaped to ASCII before it is
/// printed, and an identifier is either ASCII or valid UTF-8.

///|
/// Plural like `luac.c`'s `SS(x)`.
fn ss(n : Int) -> String {
  if n == 1 {
    ""
  } else {
    "s"
  }
}

///|
/// Left-justified to `width`, which is the `%-9s` the opcode column uses.
fn pad_left(s : String, width : Int) -> String {
  let n = s.length()
  if n >= width {
    s
  } else {
    s + " ".repeat(width - n)
  }
}

///|
/// `c` in three digits, zero filled: the `\%03d` of the reference's escaping.
fn three_digits(c : Int) -> String {
  let text = c.to_string()
  "0".repeat(3 - text.length()) + text
}

///|
/// A constant string the way `PrintString` writes it: the eight escapes C
/// spells, a printable byte as itself, anything else as `\%03d`.
fn quote_constant(sb : StringBuilder, b : Bytes) -> Unit {
  sb.write_string("\"")
  let n = b.length()
  let mut i = 0
  while i < n {
    let c = @core.ubyte_at(b, i)
    match c {
      34 => sb.write_string("\\\"")
      92 => sb.write_string("\\\\")
      7 => sb.write_string("\\a")
      8 => sb.write_string("\\b")
      12 => sb.write_string("\\f")
      10 => sb.write_string("\\n")
      13 => sb.write_string("\\r")
      9 => sb.write_string("\\t")
      11 => sb.write_string("\\v")
      _ =>
        if c >= 32 && c <= 126 {
          // Printable ASCII, which is one byte and stands as itself.
          sb.write_string(@core.text_of(@core.bytes_slice(b, i, 1)))
        } else {
          sb.write_string("\\" + three_digits(c))
        }
    }
    i = i + 1
  }
  sb.write_string("\"")
}

///|
/// `PrintType`: the one-letter tag in front of a constant's value.
fn constant_tag(v : @core.Value) -> String {
  match v {
    @core.VNil => "N"
    @core.VBool(_) => "B"
    @core.VNum(_) => "F"
    @core.VInt(_) => "I"
    @core.VStr(_) => "S"
    _ => "?"
  }
}

///|
/// `PrintConstant`.  A float keeps the language's own spelling (`%.14g`, with
/// `.0` when it would otherwise read as an integer), which is what makes this
/// line agree with `print` and `tostring`.
fn print_constant(sb : StringBuilder, v : @core.Value) -> Unit {
  match v {
    @core.VNil => sb.write_string("nil")
    @core.VBool(b) => sb.write_string(if b { "true" } else { "false" })
    @core.VInt(i) => sb.write_string(@core.text_of(@core.int64_to_bytes(i)))
    @core.VNum(d) => sb.write_string(@core.text_of(@core.double_to_g14(d)))
    @core.VStr(s) => quote_constant(sb, s.data())
    _ => sb.write_string("?")
  }
}

///|
/// The source of a prototype as the header names it.  The reference strips one
/// leading `@` or `=`, calls a chunk read from a binary string `(bstring)` and
/// anything else `(string)`; a prototype with no source at all -- one dumped
/// stripped -- reads `?`, which is what its error messages call it too.
fn source_label(p : @core.LProto) -> String {
  let d = p.source.data()
  if @core.is_no_source(d) {
    "?"
  } else if d.length() == 0 {
    "(string)"
  } else {
    match @core.ubyte_at(d, 0) {
      // '@' names a file, '=' a literal name: the prefix is not part of either.
      64 | 61 => @core.text_of(@core.bytes_slice(d, 1, d.length() - 1))
      27 => "(bstring)"
      _ => "(string)"
    }
  }
}

///|
/// `PrintHeader`: one prototype, counted out.
fn print_header(sb : StringBuilder, p : @core.LProto) -> Unit {
  let kind = if p.line_defined == 0 { "main" } else { "function" }
  let instructions = p.code.length()
  let upvalues = p.upvals.length()
  let locals = p.locvars.length()
  let constants = p.constants.length()
  let functions = p.protos.length()
  sb.write_string(
    "\n" +
    kind +
    " <" +
    source_label(p) +
    ":" +
    p.line_defined.to_string() +
    "," +
    p.last_line_defined.to_string() +
    "> (" +
    instructions.to_string() +
    " instruction" +
    ss(instructions) +
    ")\n",
  )
  sb.write_string(
    p.numparams.to_string() +
    (if p.is_vararg { "+" } else { "" }) +
    " param" +
    ss(p.numparams) +
    ", " +
    p.maxstack.to_string() +
    " slot" +
    ss(p.maxstack) +
    ", " +
    upvalues.to_string() +
    " upvalue" +
    ss(upvalues) +
    ", " +
    locals.to_string() +
    " local" +
    ss(locals) +
    ", " +
    constants.to_string() +
    " constant" +
    ss(constants) +
    ", " +
    functions.to_string() +
    " function" +
    ss(functions) +
    "\n",
  )
}

///|
/// How a function is named where an address would have gone.
fn function_label(p : @core.LProto) -> String {
  (if p.line_defined == 0 { "main" } else { "function" }) +
  " <" +
  source_label(p) +
  ":" +
  p.line_defined.to_string() +
  "," +
  p.last_line_defined.to_string() +
  ">"
}

///|
/// The comment a `CLOSURE` carries.  The reference prints the address of the
/// prototype it builds; this names it, which is the same information for a
/// reader who has only this listing.
fn closure_comment(p : @core.LProto, index : Int) -> String {
  if index >= 0 && index < p.protos.length() {
    " " + function_label(p.protos[index])
  } else {
    " ?"
  }
}

///|
/// The name an upvalue slot carries, or `-` when the prototype has no such slot.
fn upvalue_name(p : @core.LProto, i : Int) -> String {
  if i >= 0 && i < p.upvals.length() {
    @core.text_of(p.upvals[i].name.data())
  } else {
    "-"
  }
}

///|
/// The tab and semicolon that separate an instruction from its comment.
const COMMENT : String = "\t; "

///|
/// An RK operand: which constant it indexes, or nothing when it is a plain
/// register (the register number is already printed).
fn rk_note(p : @core.LProto, v : Int) -> String {
  if @core.rk_is_const(v) {
    let k = @core.rk_index(v)
    let text = if k >= 0 && k < p.constants.length() {
      show_constant(p.constants[k])
    } else {
      "?"
    }
    " K" + k.to_string() + " " + text
  } else {
    ""
  }
}

///|
/// A constant rendered as text, for the places a comment is built by
/// concatenation rather than printed straight into the listing.
fn show_constant(v : @core.Value) -> String {
  let sb = StringBuilder()
  print_constant(sb, v)
  sb.to_string()
}

///|
/// A jump's destination in the same 1-based numbering the instruction column
/// uses: the instruction after this one, moved by the offset the field holds.
fn jump_target(pc : Int, offset : Int) -> String {
  (pc + 2 + offset).to_string()
}

///|
/// One instruction: where it is, the line it belongs to, its name, the fields
/// it uses, and the comment that makes them readable.
fn print_instruction(sb : StringBuilder, p : @core.LProto, pc : Int) -> Unit {
  let i = p.code[pc]
  let line = @core.line_at(p, pc)
  sb.write_string(
    "\t" +
    (pc + 1).to_string() +
    "\t" +
    (if line > 0 { "[" + line.to_string() + "]" } else { "[-]" }) +
    "\t" +
    pad_left(@core.op_name(i.op), 9) +
    "\t",
  )
  let a = i.a.to_string()
  let b = i.b.to_string()
  let c = i.c.to_string()
  match i.op {
    // These read two registers.
    @core.OP_MOVE
    | @core.OP_UNM
    | @core.OP_BNOT
    | @core.OP_NOT
    | @core.OP_LEN
    | @core.OP_CONCAT => sb.write_string(a + " " + b)
    @core.OP_LOADK =>
      sb.write_string(
        a +
        " " +
        b +
        COMMENT +
        "k" +
        b +
        " " +
        (if i.b >= 0 && i.b < p.constants.length() {
          show_constant(p.constants[i.b])
        } else {
          "?"
        }),
      )
    @core.OP_LOADNIL =>
      sb.write_string(a + " " + b + COMMENT + (i.b + 1).to_string() + " out")
    @core.OP_GETUPVAL | @core.OP_SETUPVAL =>
      sb.write_string(a + " " + b + COMMENT + upvalue_name(p, i.b))
    // These are the instructions whose operands can name a constant.
    @core.OP_GETTABLE | @core.OP_SELF =>
      sb.write_string(a + " " + b + " " + c + rk_note(p, i.c))
    @core.OP_SETTABLE =>
      sb.write_string(a + " " + b + " " + c + rk_note(p, i.b) + rk_note(p, i.c))
    @core.OP_GETTABUP =>
      sb.write_string(
        a + " " + b + " " + c + COMMENT + upvalue_name(p, i.b) + rk_note(p, i.c),
      )
    @core.OP_SETTABUP =>
      sb.write_string(
        a +
        " " +
        b +
        " " +
        c +
        COMMENT +
        upvalue_name(p, i.a) +
        rk_note(p, i.b) +
        rk_note(p, i.c),
      )
    // The rest of the three-operand instructions read plain registers.
    @core.OP_ADD
    | @core.OP_SUB
    | @core.OP_MUL
    | @core.OP_DIV
    | @core.OP_MOD
    | @core.OP_POW
    | @core.OP_IDIV
    | @core.OP_BAND
    | @core.OP_BOR
    | @core.OP_BXOR
    | @core.OP_SHL
    | @core.OP_SHR
    | @core.OP_NEWTABLE
    | @core.OP_SETLIST
    | @core.OP_LOADBOOL
    | @core.OP_TESTSET => sb.write_string(a + " " + b + " " + c)
    @core.OP_JMP =>
      sb.write_string(
        a +
        " " +
        c +
        COMMENT +
        "to " +
        jump_target(pc, i.c) +
        (if i.a != 0 { ", level " + a } else { "" }),
      )
    @core.OP_TEST => sb.write_string(a + " " + c)
    @core.OP_CALL =>
      sb.write_string(
        a +
        " " +
        b +
        " " +
        c +
        COMMENT +
        (if i.b == 0 { "all in" } else { (i.b - 1).to_string() + " in" }) +
        " " +
        (if i.c == 0 { "all out" } else { (i.c - 1).to_string() + " out" }),
      )
    @core.OP_TAILCALL =>
      sb.write_string(
        a + " " + b + " " + c + COMMENT + (i.b - 1).to_string() + " in",
      )
    @core.OP_RETURN =>
      sb.write_string(
        a +
        " " +
        b +
        COMMENT +
        (if i.b == 0 { "all out" } else { (i.b - 1).to_string() + " out" }),
      )
    @core.OP_FORPREP =>
      sb.write_string(a + " " + c + COMMENT + "exit to " + jump_target(pc, i.c))
    @core.OP_FORLOOP | @core.OP_TFORLOOP =>
      sb.write_string(a + " " + c + COMMENT + "to " + jump_target(pc, i.c))
    @core.OP_TFORCALL => sb.write_string(a + " " + c)
    @core.OP_CLOSURE =>
      sb.write_string(a + " " + b + COMMENT + closure_comment(p, i.b))
    @core.OP_VARARG =>
      sb.write_string(
        a +
        " " +
        c +
        COMMENT +
        (if i.c == 0 { "all out" } else { (i.c - 1).to_string() + " out" }),
      )
    @core.OP_CLOSE | @core.OP_TBC => sb.write_string(a)
    _ => sb.write_string(a + " " + b + " " + c)
  }
  sb.write_string("\n")
}

///|
/// `PrintDebug`: the three tables a second `-l` asks for.
fn print_debug(sb : StringBuilder, p : @core.LProto) -> Unit {
  sb.write_string("constants (" + p.constants.length().to_string() + "):\n")
  let mut i = 0
  for c in p.constants {
    sb.write_string("\t" + i.to_string() + "\t" + constant_tag(c) + "\t")
    print_constant(sb, c)
    sb.write_string("\n")
    i = i + 1
  }
  sb.write_string("locals (" + p.locvars.length().to_string() + "):\n")
  let mut j = 0
  for v in p.locvars {
    // The two columns are the inclusive range of instructions the name is in
    // scope for, which is why the reference prints `startpc + 1` and `endpc + 1`.
    sb.write_string(
      "\t" +
      j.to_string() +
      "\t" +
      @core.text_of(v.name.data()) +
      "\t" +
      (v.start_pc + 1).to_string() +
      "\t" +
      (v.end_pc + 1).to_string() +
      "\n",
    )
    j = j + 1
  }
  sb.write_string("upvalues (" + p.upvals.length().to_string() + "):\n")
  let mut k = 0
  for u in p.upvals {
    // The third column is `instack`: whether the value lives in a register of
    // the enclosing function rather than in one of its upvalues.
    sb.write_string(
      "\t" +
      k.to_string() +
      "\t" +
      @core.text_of(u.name.data()) +
      "\t" +
      (if u.in_stack { "1" } else { "0" }) +
      "\t" +
      u.index.to_string() +
      "\n",
    )
    k = k + 1
  }
}

///|
/// `luaU_print`: the listing of a prototype and of every function it holds, the
/// outer one first and then each nested one in the order a `CLOSURE` refers to
/// them.
pub fn listing_bytes(p : @core.LProto, full : Bool) -> Bytes {
  let sb = StringBuilder()
  walk(sb, p, full)
  @core.bytes_of(sb.to_string())
}

///|
/// One prototype's lines, then its functions' in order.
fn walk(sb : StringBuilder, p : @core.LProto, full : Bool) -> Unit {
  print_header(sb, p)
  let mut pc = 0
  while pc < p.code.length() {
    print_instruction(sb, p, pc)
    pc = pc + 1
  }
  if full {
    print_debug(sb, p)
  }
  for inner in p.protos {
    walk(sb, inner, full)
  }
}
