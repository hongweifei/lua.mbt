// Names for values in error messages.
//
// The reference debugger recovers the phrase in
// `attempt to call a nil value (field 'x')` by walking the running function's
// instructions from its start to the faulting one, to see what last wrote the
// register that held the faulty value.  This file ports that walk.

///|
/// A recovered name: the sort of thing the value is, and what it is called.
pub struct ObjName {
  kind : String
  name : String
}

///|
fn const_text(p : LProto, idx : Int) -> String? {
  if idx < 0 || idx >= p.constants.length() {
    None
  } else {
    match p.constants[idx] {
      VStr(s) => Some(text_of(s.data()))
      _ => None
    }
  }
}

///|
/// The declared name of upvalue `i`.
pub fn upvalue_name(p : LProto, i : Int) -> String {
  if i >= 0 && i < p.upvals.length() {
    text_of(p.upvals[i].name.data())
  } else {
    "?"
  }
}

///|
/// `luaF_getlocalname`: the name of the `reg`-th local that is active at `pc`.
pub fn local_name(p : LProto, reg : Int, pc : Int) -> String? {
  let mut want = reg + 1
  let mut i = 0
  while i < p.locvars.length() {
    let lv = p.locvars[i]
    if lv.start_pc > pc {
      return None
    }
    if pc < lv.end_pc {
      want = want - 1
      if want == 0 {
        return Some(text_of(lv.name.data()))
      }
    }
    i = i + 1
  }
  None
}

///|
/// Whether the instruction writes its `a` register.
pub fn writes_a(op : Int) -> Bool {
  match op {
    OP_MOVE
    | OP_LOADK
    | OP_LOADNIL
    | OP_GETUPVAL
    | OP_GETTABUP
    | OP_GETTABLE
    | OP_NEWTABLE
    | OP_SELF
    | OP_ADD
    | OP_SUB
    | OP_MUL
    | OP_MOD
    | OP_POW
    | OP_DIV
    | OP_IDIV
    | OP_BAND
    | OP_BOR
    | OP_BXOR
    | OP_SHL
    | OP_SHR
    | OP_UNM
    | OP_BNOT
    | OP_NOT
    | OP_LEN
    | OP_CONCAT
    | OP_TESTSET
    | OP_CALL
    | OP_TAILCALL
    | OP_FORPREP
    | OP_FORLOOP
    | OP_TFORLOOP
    | OP_CLOSURE
    | OP_VARARG => true
    _ => false
  }
}

///|
/// A register written by code that a jump can skip over has no known setter
/// unless the jump target is already behind the use point.
fn filter_pc(pc : Int, jump_target : Int) -> Int {
  if pc < jump_target {
    -1
  } else {
    pc
  }
}

///|
/// `findsetreg`: the last instruction before `last_pc` that wrote register
/// `reg`, or -1 when it cannot be determined.
pub fn find_set_reg(p : LProto, last_pc : Int, reg : Int) -> Int {
  let mut set_reg = -1
  let mut jump_target = 0
  let mut pc = 0
  while pc < last_pc && pc < p.code.length() {
    let i = p.code[pc]
    // The instructions that follow a CLOSURE describe how it binds its
    // upvalues.  The interpreter reads them as operands and never runs them, so
    // they must not count as writing a register here either: a binding
    // instruction for a stack upvalue otherwise looks like it clobbered the
    // register holding the callee of the very next call.
    if i.op == OP_CLOSURE && i.b >= 0 && i.b < p.protos.length() {
      pc = pc + 1 + p.protos[i.b].upvals.length()
      continue
    }
    let mut change = false
    match i.op {
      OP_LOADNIL => change = i.a <= reg && reg <= i.a + i.b
      OP_TFORCALL => change = reg >= i.a + 2
      OP_CALL | OP_TAILCALL => change = reg >= i.a
      OP_JMP => {
        let dest = pc + 1 + i.c
        if dest <= last_pc && dest > jump_target {
          jump_target = dest
        }
      }
      _ => change = writes_a(i.op) && reg == i.a
    }
    if change {
      set_reg = filter_pc(pc, jump_target)
    }
    pc = pc + 1
  }
  set_reg
}

///|
/// `basicgetobjname`: a local, then the instruction that set the register.
/// The first result is the instruction the caller should keep looking at.
fn basic_obj_name(p : LProto, pc : Int, reg : Int) -> (Int, ObjName?) {
  match local_name(p, reg, pc) {
    Some(n) => (pc, Some({ kind: "local", name: n, }))
    None => {
      let spc = find_set_reg(p, pc, reg)
      if spc < 0 || spc >= p.code.length() {
        (spc, None)
      } else {
        let i = p.code[spc]
        match i.op {
          OP_MOVE =>
            if i.b < i.a {
              basic_obj_name(p, spc, i.b)
            } else {
              (spc, None)
            }
          OP_GETUPVAL =>
            (spc, Some({ kind: "upvalue", name: upvalue_name(p, i.b), }))
          OP_LOADK =>
            (
              spc,
              const_text(p, i.b).map(fn(s) { { kind: "constant", name: s, } }),
            )
          _ => (spc, None)
        }
      }
    }
  }
}

///|
/// The name of the value a register holds, as `rname` computes it: only a
/// constant gives a useful name, anything else is reported as `?`.
fn reg_name(p : LProto, pc : Int, reg : Int) -> String {
  let (_, on) = basic_obj_name(p, pc, reg)
  match on {
    Some(o) => if o.kind == "constant" { o.name } else { "?" }
    None => "?"
  }
}

///|
/// The name of an RK operand.
fn rk_name(p : LProto, pc : Int, rk : Int) -> String {
  if rk_is_const(rk) {
    match const_text(p, rk_index(rk)) {
      Some(s) => s
      None => "?"
    }
  } else {
    reg_name(p, pc, rk)
  }
}

///|
/// Whether the table an access reads from is the environment, which makes the
/// accessed name a global rather than a field.
fn access_kind(
  p : LProto,
  pc : Int,
  table : Int,
  table_is_upvalue : Bool,
) -> String {
  let is_env = if table_is_upvalue {
    upvalue_name(p, table) == "_ENV"
  } else {
    match basic_obj_name(p, pc, table) {
      (_, Some(o)) =>
        (o.kind == "local" || o.kind == "upvalue") && o.name == "_ENV"
      _ => false
    }
  }
  if is_env {
    "global"
  } else {
    "field"
  }
}

///|
/// `getobjname`: what register `reg` of `p` was loaded from at `last_pc`.
pub fn obj_name(p : LProto, last_pc : Int, reg : Int) -> ObjName? {
  let (pc, direct) = basic_obj_name(p, last_pc, reg)
  match direct {
    Some(o) => Some(o)
    None =>
      if pc < 0 || pc >= p.code.length() {
        None
      } else {
        let i = p.code[pc]
        match i.op {
          OP_GETTABUP =>
            Some({
              kind: access_kind(p, pc, i.b, true),
              name: rk_name(p, pc, i.c),
            })
          OP_GETTABLE =>
            Some({
              kind: access_kind(p, pc, i.b, false),
              name: if rk_is_const(i.c) {
                match const_text(p, rk_index(i.c)) {
                  Some(s) => s
                  None => "?"
                }
              } else {
                reg_name(p, pc, i.c)
              },
            })
          OP_SELF => Some({ kind: "method", name: rk_name(p, pc, i.c), })
          _ => None
        }
      }
  }
}

///|
/// Formats a name as the parenthesised part of an error message.
pub fn format_obj(o : ObjName?) -> String {
  match o {
    Some(n) => n.kind + " '" + n.name + "'"
    None => ""
  }
}

///|
/// The running Lua frame's current instruction and register base: the
/// interpreter stores the pc of the instruction after a raisable one, so the
/// instruction that faulted is one before it.
fn running_frame(st : LuaState) -> (LClosure, Int, Int)? {
  let thread = st.current_thread
  let n = thread.frames.length()
  if n == 0 {
    return None
  }
  let fr = thread.frames[n - 1]
  match fr.closure {
    Some(cl) => {
      let pc = fr.pc - 1
      if pc < 0 || pc >= cl.proto.code.length() {
        None
      } else {
        Some((cl, pc, fr.base))
      }
    }
    None => None
  }
}

///|
/// The phrase describing the value in stack slot `slot` of the running frame,
/// empty when no reasonable name exists.
pub fn var_info(st : LuaState, slot : Int) -> String {
  if slot < 0 {
    return ""
  }
  match running_frame(st) {
    Some((cl, pc, base)) => format_obj(obj_name(cl.proto, pc, slot - base))
    None => ""
  }
}

///|
/// The phrase describing the value in upvalue `idx` of the running frame.
pub fn upvalue_info(st : LuaState, idx : Int) -> String {
  match running_frame(st) {
    Some((cl, _, _)) =>
      format_obj(Some({ kind: "upvalue", name: upvalue_name(cl.proto, idx), }))
    None => ""
  }
}

///|
/// Encodes where an operand was read from, so that names are computed only
/// when an error is raised: a non-negative value is a stack slot, `src_none`
/// means unknown, a value from `up_src` an upvalue, and `src_iterator` the
/// implicit call a generic-for makes.
pub let src_none : Int = -1

///|
pub fn up_src(idx : Int) -> Int {
  0 - 2 - idx
}

///|
pub let src_iterator : Int = -300

///|
/// The phrase describing an operand encoded as above.
pub fn operand_info(st : LuaState, src : Int) -> String {
  if src >= 0 {
    var_info(st, src)
  } else if src == src_iterator {
    "for iterator 'for iterator'"
  } else if src == src_none {
    ""
  } else {
    upvalue_info(st, 0 - 2 - src)
  }
}

///|
/// The phrase naming the metamethod an operation tried to call.
pub fn metamethod_info(tm : String) -> String {
  "metamethod '" + tm[2:].to_owned() + "'"
}

///|
/// `funcnamefromcode`: how the calling instruction names the function it
/// called.  Only a plain call has a name worth reporting; a call through a
/// metamethod is named by the operation that raised it.
fn funcname_from_code(p : LProto, pc : Int) -> ObjName? {
  if pc < 0 || pc >= p.code.length() {
    return None
  }
  let i = p.code[pc]
  match i.op {
    OP_CALL | OP_TAILCALL => obj_name(p, pc, i.a)
    OP_TFORCALL => Some({ kind: "for iterator", name: "for iterator", })
    _ => None
  }
}

///|
/// The name the running call has at its call site, as `lua_getinfo` with "n"
/// reports it for a library function: the instruction is taken from the frame
/// below the running one, which is the caller.
pub fn callee_name(st : LuaState) -> ObjName? {
  let thread = st.current_thread
  let n = thread.frames.length()
  if n < 2 {
    return None
  }
  let fr = thread.frames[n - 2]
  if fr.hook_frame {
    // A hook function has no call site of its own to name itself by.
    return Some({ kind: "hook", name: "?", })
  }
  match fr.closure {
    Some(cl) => funcname_from_code(cl.proto, fr.pc - 1)
    None => None
  }
}

///|
/// `findfield`: a dotted name for `obj` among the string keys of `t`, looking
/// into its sub-tables until `level` runs out.
fn find_field(t : LTable, obj : Value, level : Int) -> String? {
  if level == 0 {
    return None
  }
  let mut k = VNil
  for ;; {
    match t.next(k) {
      NextPair(key, v) => {
        match key {
          VStr(s) => {
            let here = text_of(s.data())
            if v.raw_equal(obj) {
              return Some(here)
            }
            match v {
              VTable(sub) =>
                match find_field(sub, obj, level - 1) {
                  Some(path) => return Some(here + "." + path)
                  None => ()
                }
              _ => ()
            }
          }
          _ => ()
        }
        k = key
      }
      _ => return None
    }
  }
}

///|
/// `pushglobalfuncname`: where the running function lives in the globals, which
/// is how a call made through the library tables names itself ("table.sort")
/// when its call site does not.
pub fn global_func_name(st : LuaState, obj : Value) -> String? {
  match find_field(st.globals, obj, 2) {
    Some(path) =>
      if path.has_prefix("_G.") {
        Some(path[3:].to_owned())
      } else {
        Some(path)
      }
    None => None
  }
}

///|
/// The value the running frame was called with, from its own stack slot.
fn callee_value(st : LuaState) -> Value? {
  let thread = st.current_thread
  let n = thread.frames.length()
  if n == 0 {
    return None
  }
  let slot = thread.frames[n - 1].func_slot
  if slot < 0 || slot >= thread.stack.length() {
    None
  } else {
    Some(thread.stack[slot])
  }
}

///|
/// The whole "bad argument" phrase, as `luaL_argerror` builds it: the function
/// is named as its call site names it, then as a path among the fields of
/// `package.loaded`, and `?` when neither can name it -- the reference never
/// reports the name a function was registered under, so a file method reached
/// as a value (`pcall(f.read, f)`) is `?` rather than `read`.  For a method
/// call the `self` argument is not counted, so a bad `self` reads as a failed
/// call instead.
pub fn arg_message(
  st : LuaState,
  n : Int,
  fname : String,
  msg : String,
) -> String {
  let _ = fname
  let derived = match callee_name(st) {
    Some(o) => Some(o)
    None =>
      match callee_value(st) {
        Some(v) =>
          match global_func_name(st, v) {
            Some(path) => Some({ kind: "global", name: path, })
            None => None
          }
        None => None
      }
  }
  let bad = "bad argument #" + n.to_string() + " to '"
  let tail = "' (" + msg + ")"
  match derived {
    Some(o) =>
      if o.kind == "method" {
        let j = n - 1
        if j == 0 {
          "calling '" + o.name + "' on bad self (" + msg + ")"
        } else {
          "bad argument #" + j.to_string() + " to '" + o.name + tail
        }
      } else {
        bad + o.name + tail
      }
    None => bad + "?" + tail
  }
}
