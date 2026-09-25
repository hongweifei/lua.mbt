// debug.getinfo, including the symbolic name inference the reference
// implementation performs (getobjname / findsetreg / funcnamefromcode).

///|
pub fn chunk_id(source : String) -> String {
  @core.chunk_id_of(@core.bytes_of(source))
}

///|
/// Whether the instruction writes a value into its A register (the `iA`
/// opmode bit of the reference opcode table).
fn is_amode(op : Int) -> Bool {
  match op {
    // SETTABUP/SETTABLE/SETUPVAL, comparisons, jumps, returns, loop control
    // and the other instructions that use A without writing it are excluded.
    @core.OP_MOVE
    | @core.OP_LOADK
    | @core.OP_LOADNIL
    | @core.OP_LOADBOOL
    | @core.OP_GETUPVAL
    | @core.OP_GETTABLE
    | @core.OP_GETTABUP
    | @core.OP_NEWTABLE
    | @core.OP_SELF
    | @core.OP_ADD
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
    | @core.OP_UNM
    | @core.OP_BNOT
    | @core.OP_NOT
    | @core.OP_LEN
    | @core.OP_CONCAT
    | @core.OP_TESTSET
    | @core.OP_CALL
    | @core.OP_CLOSURE
    | @core.OP_VARARG
    | @core.OP_TBC => true
    _ => false
  }
}

///|
/// `filterpc`: an instruction inside a conditional jump cannot be trusted to
/// be the one that set a register.
fn filter_pc(pc : Int, jump_target : Int) -> Int {
  if pc < jump_target {
    -1
  } else {
    pc
  }
}

///|
/// `findsetreg`: the last instruction before `lastpc` that sets `reg`.
fn find_set_reg(proto : @core.LProto, lastpc : Int, reg : Int) -> Int {
  let mut set_reg = -1
  let mut jump_target = 0
  let mut pc = 0
  while pc < lastpc {
    let inst = proto.code[pc]
    let a = inst.a
    let change = match inst.op {
      @core.OP_LOADNIL => a <= reg && reg <= a + inst.b
      @core.OP_TFORCALL => reg >= a + 2
      @core.OP_CALL | @core.OP_TAILCALL => reg >= a
      @core.OP_JMP => {
        let dest = pc + 1 + inst.c
        if dest <= lastpc && dest > jump_target {
          jump_target = dest
        }
        false
      }
      _ => is_amode(inst.op) && reg == a
    }
    if change {
      set_reg = filter_pc(pc, jump_target)
    }
    pc = pc + 1
  }
  set_reg
}

///|
/// The name of an upvalue of a prototype, or "?" for stripped chunks.
fn upval_name(proto : @core.LProto, uv : Int) -> String {
  if uv >= 0 && uv < proto.upvals.length() {
    let s = proto.upvals[uv].name
    if s.length() == 0 {
      "?"
    } else {
      @core.text_of(s.data())
    }
  } else {
    "?"
  }
}

///|
/// The string constant of a K index, or `None`.
fn kname(proto : @core.LProto, k : Int) -> String? {
  if k >= 0 && k < proto.constants.length() {
    match proto.constants[k] {
      @core.VStr(s) => Some(@core.text_of(s.data()))
      _ => None
    }
  } else {
    None
  }
}

///|
/// `basicgetobjname`: local, upvalue or constant origin of a register.
fn basic_get_obj_name(
  proto : @core.LProto,
  lastpc0 : Int,
  reg : Int,
) -> (String, String)? {
  let mut lastpc = lastpc0
  // A local with that register?  The n-th active variable lives in the
  // (n-1)-th register, exactly as the reference implementation assumes.
  match get_local_name(proto, reg + 1, lastpc) {
    Some(name) => return Some(("local", name))
    None => ()
  }
  lastpc = find_set_reg(proto, lastpc, reg)
  if lastpc != -1 {
    let inst = proto.code[lastpc]
    match inst.op {
      @core.OP_MOVE =>
        if inst.b < inst.a {
          return basic_get_obj_name(proto, lastpc, inst.b)
        }
      @core.OP_GETUPVAL => return Some(("upvalue", upval_name(proto, inst.b)))
      @core.OP_LOADK =>
        match kname(proto, inst.b) {
          Some(name) => return Some(("constant", name))
          None => ()
        }
      _ => ()
    }
  }
  None
}

///|
/// `getobjname`: where the value in `reg` came from, for a call at `lastpc`.
fn get_obj_name(
  proto : @core.LProto,
  lastpc0 : Int,
  reg : Int,
) -> (String, String)? {
  let mut lastpc = lastpc0
  match basic_get_obj_name(proto, lastpc, reg) {
    Some(r) => return Some(r)
    None => ()
  }
  // `findsetreg` located the instruction that set `reg`; the switch below
  // inspects that instruction, not the call site.
  lastpc = find_set_reg(proto, lastpc, reg)
  if lastpc == -1 {
    return None
  }
  let inst = proto.code[lastpc]
  match inst.op {
    @core.OP_GETTABUP => {
      let key = match kname(proto, inst.c - @core.RK_OFFSET) {
        Some(k) => k
        None => "?"
      }
      // Reading from the _ENV upvalue is a global access.
      if upval_name(proto, inst.b) == "_ENV" {
        Some(("global", key))
      } else {
        Some(("field", key))
      }
    }
    @core.OP_GETTABLE => {
      // `isEnv`: a table named _ENV makes the access global, any other
      // table is a plain field access.
      let key = if inst.c >= @core.RK_OFFSET {
        match kname(proto, inst.c - @core.RK_OFFSET) {
          Some(k) => k
          None => "?"
        }
      } else {
        match basic_get_obj_name(proto, lastpc, inst.c) {
          Some(("constant", name)) => name
          _ => "?"
        }
      }
      let is_env = match basic_get_obj_name(proto, lastpc, inst.b) {
        Some(("local", name)) => name == "_ENV"
        Some(("upvalue", name)) => name == "_ENV"
        _ => false
      }
      Some((if is_env { "global" } else { "field" }, key))
    }
    @core.OP_SELF =>
      match kname(proto, inst.c - @core.RK_OFFSET) {
        Some(key) => Some(("method", key))
        None => None
      }
    _ => None
  }
}

///|
/// `funcnamefromcode`: how the call at `pc` of `proto` names its target.
fn func_name_from_code(
  proto : @core.LProto,
  pc : Int,
  reg : Int,
) -> (String, String)? {
  let inst = proto.code[pc]
  match inst.op {
    @core.OP_CALL | @core.OP_TAILCALL => get_obj_name(proto, pc, reg)
    @core.OP_TFORCALL => Some(("for iterator", "for iterator"))
    _ => None
  }
}

///|
/// The name the frame's function was called with: `(namewhat, name)` or
/// `None` when no reasonable name exists (then namewhat is the empty string).
pub fn func_name_of(thread : @core.LThread, fr_idx : Int) -> (String, String)? {
  let fr = thread.frames[fr_idx]
  if fr.tailcalls > 0 {
    // A tail call took over its frame, so the call site that named the function
    // it replaced is gone; the reference reports no name at all.
    return None
  }
  if fr.hook_frame {
    return Some(("hook", "?"))
  }
  if fr.mm_name != "" {
    return Some(("metamethod", fr.mm_name))
  }
  // The name comes from the call site in the caller frame: the frame that
  // called this one sits below it on the stack, and its saved pc points
  // right after the CALL instruction that created this frame.
  if fr_idx == 0 {
    return None
  }
  let caller_idx = fr_idx - 1
  let caller = thread.frames[caller_idx]
  match caller.closure {
    Some(cl) => {
      let pc = caller.pc - 1
      if pc >= 0 && pc < cl.proto.code.length() {
        // The call instruction's A register holds the callee slot; the last
        // instruction of a generic `for` step names its iterator the same way.
        let inst = cl.proto.code[pc]
        if inst.op == @core.OP_CALL ||
          inst.op == @core.OP_TAILCALL ||
          inst.op == @core.OP_TFORCALL {
          let reg = fr.func_slot - caller.base
          return func_name_from_code(cl.proto, pc, reg)
        }
      }
      None
    }
    None => None
  }
}

///|
/// Parses a what-option string into a bitmask of the requested fields,
/// rejecting unknown options the way `auxgetinfo` does: the whole string is
/// reported, not the offending character.
fn what_mask_of(
  st : @core.LuaState,
  s : @core.LStr,
  fname : String,
  arg : Int,
) -> Int raise @core.LuaRaised {
  let mut mask = 0
  let data = s.data()
  let mut i = 0
  while i < data.length() {
    match @core.ubyte_at(data, i) {
      83 => mask = mask | 1 // 'S'
      108 => mask = mask | 2 // 'l'
      110 => mask = mask | 4 // 'n'
      117 => mask = mask | 8 // 'u'
      102 => mask = mask | 16 // 'f'
      76 => mask = mask | 32 // 'L'
      116 => mask = mask | 64 // 't'
      114 => mask = mask | 128 // 'r'
      _ => @core.arg_error(st, arg, fname, "invalid option")
    }
    i = i + 1
  }
  mask
}

///|
/// Builds the result table of `debug.getinfo`.
fn info_table(
  fr : @core.Frame?,
  f : @core.Value,
  what : Int,
  namewhat : String,
  name : @core.Value,
) -> @core.LTable {
  let t = @core.LTable::new()
  let proto : @core.LProto? = match f {
    @core.VFunc(cl) => Some(cl.proto)
    _ => None
  }
  // 'S'
  if (what & 1) != 0 {
    match proto {
      Some(p) => {
        // A chunk with no source -- one that was dumped stripped -- reports
        // `=?`, which the short form shortens to `?`, exactly as the reference
        // does for a NULL source.
        let src = if @core.has_source(p.source) {
          @core.text_of(p.source.data())
        } else {
          "=?"
        }
        t.set_str("source", @core.VStr(@core.LStr::of_string(src)))
        t.set_str("short_src", @core.VStr(@core.LStr::of_string(chunk_id(src))))
        t.set_str("linedefined", @core.VInt(p.line_defined.to_int64()))
        t.set_str("lastlinedefined", @core.VInt(p.last_line_defined.to_int64()))
        t.set_str(
          "what",
          @core.VStr(
            @core.LStr::of_string(
              if p.line_defined == 0 {
                "main"
              } else {
                "Lua"
              },
            ),
          ),
        )
      }
      None => {
        t.set_str("source", @core.VStr(@core.LStr::of_string("=[C]")))
        t.set_str("short_src", @core.VStr(@core.LStr::of_string("[C]")))
        t.set_str("linedefined", @core.VInt(-1L))
        t.set_str("lastlinedefined", @core.VInt(-1L))
        t.set_str("what", @core.VStr(@core.LStr::of_string("C")))
      }
    }
  }
  // 'l'
  if (what & 2) != 0 {
    let line = match fr {
      Some(fr) =>
        match fr.closure {
          Some(cl) => @core.line_at(cl.proto, fr.pc - 1)
          None => -1
        }
      None => -1
    }
    t.set_str("currentline", @core.VInt(line.to_int64()))
  }
  // 't'
  if (what & 64) != 0 {
    let tail = match fr {
      Some(fr) => fr.tailcalls > 0
      None => false
    }
    t.set_str("istailcall", @core.VBool(tail))
  }
  // 'u'
  if (what & 8) != 0 {
    match f {
      @core.VFunc(cl) => {
        t.set_str("nups", @core.VInt(cl.upvals.length().to_int64()))
        t.set_str("nparams", @core.VInt(cl.proto.numparams.to_int64()))
        t.set_str("isvararg", @core.VBool(cl.proto.is_vararg))
      }
      @core.VBuiltin(b) => {
        t.set_str("nups", @core.VInt(b.upvals.length().to_int64()))
        t.set_str("nparams", @core.VInt(0L))
        t.set_str("isvararg", @core.VBool(true))
      }
      _ => {
        t.set_str("nups", @core.VInt(0L))
        t.set_str("nparams", @core.VInt(0L))
        t.set_str("isvararg", @core.VBool(true))
      }
    }
  }
  // 'n'
  if (what & 4) != 0 {
    t.set_str("namewhat", @core.VStr(@core.LStr::of_string(namewhat)))
    t.set_str("name", name)
  }
  // 'f'
  if (what & 16) != 0 {
    t.set_str("func", f)
  }
  // 'r'
  if (what & 128) != 0 {
    let (ftransfer, ntransfer) = match fr {
      Some(f) => (f.ftransfer, f.ntransfer)
      None => (0, 0)
    }
    t.set_str("ftransfer", @core.VInt(ftransfer.to_int64()))
    t.set_str("ntransfer", @core.VInt(ntransfer.to_int64()))
  }
  // 'L': active lines, only for Lua functions.
  if (what & 32) != 0 {
    match proto {
      Some(p) => {
        let lines = @core.LTable::new()
        let mut i = 0
        while i < p.lines.length() {
          let line = p.lines[i]
          if line > 0 {
            lines.set_int(line.to_int64(), @core.VBool(true))
          }
          i = i + 1
        }
        t.set_str("activelines", @core.VTable(lines))
      }
      None => ()
    }
  }
  t
}

///|
pub fn db_getinfo(
  st : @core.LuaState,
  _upvals : Array[@core.Value],
  args : ArrayView[@core.Value],
) -> @core.BuiltinResult raise @core.LuaRaised {
  let (thread, arg) = get_thread(st, args)
  let f_arg = arg_or_nil(args, arg)
  let what_arg = arg_or_nil(args, arg + 1)
  let what : Int = match what_arg {
    @core.VNil => 1 | 2 | 4 | 8 | 16 | 64 | 128
    _ => {
      // `luaL_optstring` accepts a number as well, and an unknown option is
      // reported as `invalid option`; a leading `>` has its own message because
      // the reference rejects that one before it parses anything.
      let s = @core.check_str(st, args, arg + 1, "getinfo")
      if s.data().length() > 0 && @core.ubyte_at(s.data(), 0) == 62 {
        @core.arg_error(st, arg + 1, "getinfo", "invalid option '>'")
      }
      what_mask_of(st, s, "getinfo", arg + 1)
    }
  }
  if is_function_arg(f_arg) {
    // Function form: no current line, no namewhat.
    @core.One(@core.VTable(info_table(None, f_arg, what, "", @core.VNil)))
  } else {
    let level = @core.check_int(st, args, arg, "getinfo").to_int()
    let len = thread.frames.length()
    let idx = len - 1 - level
    if idx < 0 || idx >= len {
      return @core.One(@core.VNil)
    }
    let fr = thread.frames[idx]
    let f = match fr.closure {
      Some(cl) => @core.VFunc(cl)
      None =>
        match fr.builtin {
          Some(b) => @core.VBuiltin(b)
          None => @core.VNil
        }
    }
    let (namewhat, name) = match func_name_of(thread, idx) {
      Some((w, n)) => (w, @core.VStr(@core.LStr::of_string(n)))
      None => ("", @core.VNil)
    }
    @core.One(@core.VTable(info_table(Some(fr), f, what, namewhat, name)))
  }
}
