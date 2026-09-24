// Arithmetic, bitwise, length and concatenation operations.

///|
/// Binary arithmetic, bitwise and power operators.
pub fn arith(
  st : @core.LuaState,
  op : Int,
  x : @core.Value,
  y : @core.Value,
) -> @core.Value raise @core.LuaRaised {
  let both_int = match (x, y) {
    (@core.VInt(_), @core.VInt(_)) => true
    _ => false
  }
  let both_num = x.is_number() && y.is_number()
  if op_is_bitwise(op) {
    if both_int || both_num {
      let a = match @core.value_to_int64(x) {
        Some(v) => v
        None => no_integer_representation(st, x, st.slot_x)
      }
      let b = match @core.value_to_int64(y) {
        Some(v) => v
        None => no_integer_representation(st, y, st.slot_y)
      }
      return @core.VInt(
        match op {
          @core.BINOP_BAND => a & b
          @core.BINOP_BOR => a | b
          @core.BINOP_BXOR => a ^ b
          @core.BINOP_SHL => int_shl(a, b)
          @core.BINOP_SHR => int_shr(a, b)
          _ => a
        },
      )
    }
  } else if both_num {
    if both_int && !op_is_float_only(op) {
      let a = match x {
        @core.VInt(v) => v
        _ => 0L
      }
      let b = match y {
        @core.VInt(v) => v
        _ => 0L
      }
      let r = match op {
        @core.BINOP_ADD => @core.VInt(a + b)
        @core.BINOP_SUB => @core.VInt(a - b)
        @core.BINOP_MUL => @core.VInt(a * b)
        @core.BINOP_IDIV => @core.VInt(int_floor_div(st, a, b))
        @core.BINOP_MOD => @core.VInt(int_mod(st, a, b))
        _ => @core.VInt(a)
      }
      return r
    }
    let a = match @core.value_to_double(x) {
      Some(v) => v
      None => 0.0
    }
    let b = match @core.value_to_double(y) {
      Some(v) => v
      None => 0.0
    }
    return @core.VNum(
      match op {
        @core.BINOP_ADD => a + b
        @core.BINOP_SUB => a - b
        @core.BINOP_MUL => a * b
        @core.BINOP_DIV => a / b
        @core.BINOP_POW => pow_double(a, b)
        @core.BINOP_IDIV => floor_double(a / b)
        @core.BINOP_MOD => @core.float_mod(a, b)
        _ => a
      },
    )
  }
  let verb = if op_is_bitwise(op) {
    "perform bitwise operation on"
  } else {
    "perform arithmetic on"
  }
  binary_metamethod(st, op, x, y, verb)
}

///|
/// Looks up and calls the metamethod for a binary operation, or reports the
/// failure with the given verb.
pub fn binary_metamethod(
  st : @core.LuaState,
  op : Int,
  x : @core.Value,
  y : @core.Value,
  verb : String,
) -> @core.Value raise @core.LuaRaised {
  let name = @core.binop_metamethod(op)
  if name != "?" {
    let h = metafield(st, x, name)
    if !h.is_nil() {
      if is_callable(h) {
        let res = call_metamethod(st, h, [x, y], 1, metamethod_report(name))
        return nth_or_nil(res, 0)
      }
      bad_metamethod_call(st, h, name)
    }
    let h2 = metafield(st, y, name)
    if !h2.is_nil() {
      if is_callable(h2) {
        let res = call_metamethod(st, h2, [x, y], 1, metamethod_report(name))
        return nth_or_nil(res, 0)
      }
      bad_metamethod_call(st, h2, name)
    }
  }
  // Concatenation blames the first operand that cannot become text; the others
  // blame the first operand that is not a number.
  let blame_first = if op == @core.BINOP_CONCAT {
    match coerce_concat(x) {
      None => true
      _ => false
    }
  } else {
    !x.is_number()
  }
  if blame_first {
    op_error(st, verb, x, st.slot_x)
  } else {
    op_error(st, verb, y, st.slot_y)
  }
}

///|
/// Unary minus, bitwise not, logical not and length.
pub fn unop(
  st : @core.LuaState,
  op : Int,
  v : @core.Value,
) -> @core.Value raise @core.LuaRaised {
  match op {
    @core.UNOP_NOT => @core.VBool(!v.is_truthy())
    @core.UNOP_MINUS =>
      match v {
        @core.VInt(i) => @core.VInt(0L - i)
        @core.VNum(d) => @core.VNum(-d)
        _ => unary_call(st, v, "__unm", "perform arithmetic on")
      }
    @core.UNOP_BNOT =>
      match @core.value_to_int64(v) {
        Some(i) => @core.VInt(i.lnot())
        None =>
          if v.is_number() {
            no_integer_representation(st, v, st.slot_x)
          } else {
            unary_call(st, v, "__bnot", "perform bitwise operation on")
          }
      }
    @core.UNOP_LEN => len(st, v)
    _ => @core.VNil
  }
}

///|
/// The `#` operator.
pub fn len(
  st : @core.LuaState,
  v : @core.Value,
) -> @core.Value raise @core.LuaRaised {
  match v {
    @core.VStr(s) => @core.VInt(s.length().to_int64())
    @core.VTable(t) => {
      let h = metafield(st, v, "__len")
      if !h.is_nil() {
        let res = call_metamethod(st, h, [v, v], 1, "len")
        return nth_or_nil(res, 0)
      }
      @core.VInt(t.raw_len())
    }
    _ => unary_call(st, v, "__len", "get length of")
  }
}

///|----------------------------------------------------------------
/// Comparison

///|----------------------------------------------------------------

///|
/// Concatenation of a run of values, right associative as in the language.
pub fn concat_values(
  st : @core.LuaState,
  vals : Array[@core.Value],
  first : Int,
) -> @core.Value raise @core.LuaRaised {
  let n = vals.length()
  if n == 0 {
    return @core.VStr(@core.LStr::empty())
  }
  let mut acc = vals[n - 1]
  let mut i = n - 1
  while i > 0 {
    // The concatenation of the tail sits where its first operand did, as in
    // the reference's in-place loop.
    st.slot_x = first + i - 1
    st.slot_y = first + i
    acc = concat_two(st, vals[i - 1], acc)
    i = i - 1
  }
  acc
}

///|
/// Calls a unary metamethod, or reports the operand when there is nothing
/// usable to call.
fn unary_call(
  st : @core.LuaState,
  v : @core.Value,
  tm_name : String,
  verb : String,
) -> @core.Value raise @core.LuaRaised {
  let h = metafield(st, v, tm_name)
  if h.is_nil() {
    op_error(st, verb, v, st.slot_x)
  } else if is_callable(h) {
    let res = call_metamethod(st, h, [v, v], 1, metamethod_report(tm_name))
    nth_or_nil(res, 0)
  } else {
    bad_metamethod_call(st, h, tm_name)
  }
}

///|
/// Concatenation of two values.  Strings and numbers join directly; anything
/// else goes through `__concat`.
pub fn concat_two(
  st : @core.LuaState,
  x : @core.Value,
  y : @core.Value,
) -> @core.Value raise @core.LuaRaised {
  match (coerce_concat(x), coerce_concat(y)) {
    (Some(a), Some(b)) =>
      // The string itself is charged where every other string is, at its
      // creation.
      @core.VStr(@core.LStr::of_bytes(@core.bytes_concat([a, b])))
    _ => binary_metamethod(st, @core.BINOP_CONCAT, x, y, "concatenate")
  }
}

///|
/// Folds `n` operands ending at `first + n - 1` from the right, with `acc`
/// standing for everything already folded beyond them, and returns the result.
///
/// The fold keeps its position on the frame, and each `__concat` it calls
/// leaves its result in the slot `call_value` chose: a yield inside one is
/// therefore resumable, and `finish_pending` carries the fold on from exactly
/// where it stopped.  `at` is the index of the instruction, which the resume
/// needs to find this same operand range again.
pub fn concat_fold(
  st : @core.LuaState,
  thread : @core.LThread,
  fr : @core.Frame,
  at : Int,
  first : Int,
  n : Int,
  acc : @core.Value,
) -> @core.Value raise @core.LuaRaised {
  let _ = at
  let mut acc = acc
  let mut i = n
  while i > 0 {
    fr.pending_top = i
    // The operands of this fold, for the error that blames one of them.  The
    // second one is a register only on the first pass; a later pass folds into
    // a value that is not in the stack, but such a pass can only fail on the
    // first operand, which always is.
    st.slot_x = first + i - 1
    st.slot_y = first + i
    acc = concat_two(st, thread.stack[first + i - 1], acc)
    i = i - 1
  }
  fr.pending_top = -1
  acc
}

///|
/// The byte form of a value for concatenation, when it has one.
pub fn coerce_concat(v : @core.Value) -> Bytes? {
  match v {
    @core.VStr(s) => Some(s.data())
    @core.VInt(i) => Some(@core.int64_to_bytes(i))
    @core.VNum(d) => Some(@core.double_to_g14(d))
    _ => None
  }
}

///|----------------------------------------------------------------
/// Conversion to text

///|----------------------------------------------------------------

///|
/// Integer division that truncates toward minus infinity, raising on zero.
pub fn int_floor_div(
  state : @core.LuaState,
  a : Int64,
  b : Int64,
) -> Int64 raise @core.LuaRaised {
  if b == 0L {
    @core.vm_error(state, "attempt to divide by zero")
  }
  if b == -1L {
    return 0L - a
  }
  let q = a / b
  if a % b != 0L && (a < 0L) != (b < 0L) {
    q - 1L
  } else {
    q
  }
}

///|
/// The remainder that goes with floored division, raising on zero.
pub fn int_mod(
  state : @core.LuaState,
  a : Int64,
  b : Int64,
) -> Int64 raise @core.LuaRaised {
  if b == 0L {
    @core.vm_error(state, "attempt to perform 'n%0'")
  }
  if b == -1L {
    return 0L
  }
  let r = a % b
  if r != 0L && (r < 0L) != (b < 0L) {
    r + b
  } else {
    r
  }
}

///|
/// Logical shift left; counts outside the range produce zero, and a negative
/// count shifts the other way.
pub fn int_shl(a : Int64, n : Int64) -> Int64 {
  if n <= -64L || n >= 64L {
    return 0L
  }
  if n < 0L {
    return int_shr(a, -n)
  }
  let u = a.reinterpret_as_uint64() << n.to_int()
  u.reinterpret_as_int64()
}

///|
pub fn int_shr(a : Int64, n : Int64) -> Int64 {
  if n <= -64L || n >= 64L {
    return 0L
  }
  if n < 0L {
    return int_shl(a, -n)
  }
  let u = a.reinterpret_as_uint64() >> n.to_int()
  u.reinterpret_as_int64()
}

///|
/// Whether an operation always produces a float.
pub fn op_is_float_only(op : Int) -> Bool {
  match op {
    @core.BINOP_DIV | @core.BINOP_POW => true
    _ => false
  }
}

///|
/// Whether an operation requires integers.
pub fn op_is_bitwise(op : Int) -> Bool {
  match op {
    @core.BINOP_BAND
    | @core.BINOP_BOR
    | @core.BINOP_BXOR
    | @core.BINOP_SHL
    | @core.BINOP_SHR => true
    _ => false
  }
}

///|
/// The power primitive, separated so the arithmetic code reads plainly.
pub fn pow_double(a : Double, b : Double) -> Double {
  @math.pow(a, b)
}

///|
pub fn floor_double(a : Double) -> Double {
  @math.floor(a)
}
