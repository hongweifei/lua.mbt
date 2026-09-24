// Helpers used by the interpreter loop and by diagnostics.

///|
/// Whether an instruction can report a runtime error, and therefore has to keep
/// the frame's instruction pointer current so that the message names the right
/// line.
pub fn may_raise(op : Int) -> Bool {
  match op {
    @core.OP_MOVE
    | @core.OP_LOADK
    | @core.OP_LOADNIL
    | @core.OP_LOADBOOL
    | @core.OP_GETUPVAL
    | @core.OP_SETUPVAL
    | @core.OP_JMP
    | @core.OP_TEST
    | @core.OP_TESTSET
    | @core.OP_TFORLOOP
    | @core.OP_VARARG => false
    _ => true
  }
}

///|
/// Whether the instruction `op` can be *finished* after a metamethod call it
/// started was interrupted by a yield.  The call's result is already on the
/// stack, so the instruction only has to take it -- or, for a comparison, take
/// its answer and decide the jump.  This is the reference's `luaV_finishOp`.
///
/// `OP_CLOSE` and `OP_RETURN` are deliberately absent: they produce no value,
/// so they are *run again* instead (their `pc` is rewound), which is what
/// closes the next pending to-be-closed variable.
pub fn can_finish_after_yield(op : Int) -> Bool {
  match op {
    // Nothing to take: the metamethod's result is thrown away.
    @core.OP_SETTABLE | @core.OP_SETTABUP => true
    @core.OP_GETTABUP
    | @core.OP_GETTABLE
    | @core.OP_SELF
    | @core.OP_UNM
    | @core.OP_BNOT
    | @core.OP_LEN
    | @core.OP_CONCAT
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
    | @core.OP_EQ
    | @core.OP_LT
    | @core.OP_LE => true
    _ => false
  }
}

///|
pub fn rk_value(
  proto : @core.LProto,
  thread : @core.LThread,
  base : Int,
  rk : Int,
) -> @core.Value {
  if rk >= @core.RK_OFFSET {
    proto.constants[rk - @core.RK_OFFSET]
  } else {
    thread.stack[base + rk]
  }
}

///|
pub fn opcode_to_binop(op : Int) -> Int {
  match op {
    @core.OP_ADD => @core.BINOP_ADD
    @core.OP_SUB => @core.BINOP_SUB
    @core.OP_MUL => @core.BINOP_MUL
    @core.OP_DIV => @core.BINOP_DIV
    @core.OP_MOD => @core.BINOP_MOD
    @core.OP_POW => @core.BINOP_POW
    @core.OP_IDIV => @core.BINOP_IDIV
    @core.OP_BAND => @core.BINOP_BAND
    @core.OP_BOR => @core.BINOP_BOR
    @core.OP_BXOR => @core.BINOP_BXOR
    @core.OP_SHL => @core.BINOP_SHL
    @core.OP_SHR => @core.BINOP_SHR
    _ => @core.BINOP_ADD
  }
}

///|
pub fn opcode_to_unop(op : Int) -> Int {
  match op {
    @core.OP_UNM => @core.UNOP_MINUS
    @core.OP_BNOT => @core.UNOP_BNOT
    @core.OP_NOT => @core.UNOP_NOT
    @core.OP_LEN => @core.UNOP_LEN
    _ => @core.UNOP_NOT
  }
}

///|
pub fn is_zero_step(v : @core.Value) -> Bool {
  match v {
    @core.VInt(i) => i == 0L
    @core.VNum(d) => d == 0.0
    _ => false
  }
}

///|
/// The limit of an integer `for`, as `forlimit` computes it: a numeric string
/// counts as a number and a float is rounded in the direction the loop travels.
/// A float beyond the range of integers stands for the nearest end of that
/// range.  The second result says the loop has nothing to run, either because
/// such a float is on the wrong side of the initial value or because the initial
/// value is already past the limit.
fn for_limit(
  st : @core.LuaState,
  v : @core.Value,
  init : Int64,
  step : Int64,
) -> (Int64, Bool) raise @core.LuaRaised {
  let up = step < 0L
  let as_int = match v {
    @core.VInt(i) => Some(i)
    @core.VNum(d) =>
      if up {
        @core.float_ceil_to_int64(d)
      } else {
        @core.float_floor_to_int64(d)
      }
    @core.VStr(s) =>
      match @core.lua_str2num(s.data()) {
        Some(@core.NInt(i)) => Some(i)
        Some(@core.NFloat(d)) =>
          if up {
            @core.float_ceil_to_int64(d)
          } else {
            @core.float_floor_to_int64(d)
          }
        None => None
      }
    _ => None
  }
  match as_int {
    Some(l) => (l, if up { init < l } else { init > l })
    None => {
      let d = match @core.value_to_double_or_string(v) {
        Some(d) => d
        None => for_error(st, "limit", v)
      }
      if d > 0.0 {
        if up {
          (0L, true)
        } else {
          (0x7FFFFFFFFFFFFFFFL, false)
        }
      } else if up {
        (-0x8000000000000000L, false)
      } else {
        (0L, true)
      }
    }
  }
}

///|
/// Converts the control values of a numeric `for`, as `forprep` does, and lays
/// the slots out the way the reference does:
///
/// ```text
/// a     internal index (the initial value)
/// a+1   loop counter, for an integer loop, or the limit, for a float one
/// a+2   step
/// a+3   the control variable the body reads
/// ```
///
/// An integer loop counts its iterations instead of comparing the index with the
/// limit, because the last addition of the step would otherwise wrap around and
/// the loop would start again from the other end.  False means the loop does not
/// run at all.
pub fn prepare_for(
  st : @core.LuaState,
  thread : @core.LThread,
  a : Int,
) -> Bool raise @core.LuaRaised {
  let init = thread.stack[a]
  let limit = thread.stack[a + 1]
  let step = thread.stack[a + 2]
  match (init, step) {
    // The integer loop needs an actual integer for both the initial value and
    // the step; anything else, including a numeric string, makes it a float one.
    (@core.VInt(i0), @core.VInt(s)) => {
      if s == 0L {
        @core.vm_error(st, "'for' step is zero")
      }
      thread.stack[a + 3] = @core.VInt(i0)
      let (l, skip) = for_limit(st, limit, i0, s)
      if skip {
        return false
      }
      // The number of iterations left after the first one, which the body gets
      // before any test runs.  It is counted in unsigned arithmetic so that the
      // distance between the two ends cannot overflow.
      let left = if s > 0L {
        let mut c = l.reinterpret_as_uint64() - i0.reinterpret_as_uint64()
        if s != 1L {
          c = c / s.reinterpret_as_uint64()
        }
        c
      } else {
        // 's + 1' keeps the negation away from the smallest integer.
        let d = (-(s + 1L)).reinterpret_as_uint64() + 1UL
        (i0.reinterpret_as_uint64() - l.reinterpret_as_uint64()) / d
      }
      // The counter takes the place of the limit, which is not needed any more.
      thread.stack[a + 1] = @core.VInt(left.reinterpret_as_int64())
      true
    }
    _ => {
      // The order is the one the reference reports errors in.
      let l = match @core.value_to_double_or_string(limit) {
        Some(v) => v
        None => for_error(st, "limit", limit)
      }
      let s = match @core.value_to_double_or_string(step) {
        Some(v) => v
        None => for_error(st, "step", step)
      }
      let i0 = match @core.value_to_double_or_string(init) {
        Some(v) => v
        None => for_error(st, "initial value", init)
      }
      if s == 0.0 {
        @core.vm_error(st, "'for' step is zero")
      }
      // The body runs before the first test, so the index starts at the value
      // the body is to see.
      thread.stack[a] = @core.VNum(i0)
      thread.stack[a + 1] = @core.VNum(l)
      thread.stack[a + 2] = @core.VNum(s)
      thread.stack[a + 3] = @core.VNum(i0)
      if s > 0.0 {
        !(l < i0)
      } else {
        !(i0 < l)
      }
    }
  }
}

///|----------------------------------------------------------------
/// Diagnostics for operands

///|
/// The stack slot an RK operand reads, or -1 for a constant.
pub fn rk_slot(rk : Int, base : Int) -> Int {
  if @core.rk_is_const(rk) {
    -1
  } else {
    base + rk
  }
}

///|----------------------------------------------------------------
