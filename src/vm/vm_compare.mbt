// Equality and order comparisons.

///|
/// Whether two values are equal, consulting `__eq` for two tables or two
/// userdata.
pub fn equals(
  st : @core.LuaState,
  x : @core.Value,
  y : @core.Value,
) -> Bool raise @core.LuaRaised {
  if x.raw_equal(y) {
    return true
  }
  let both_same = match (x, y) {
    (@core.VTable(_), @core.VTable(_)) => true
    (@core.VUserData(_), @core.VUserData(_)) => true
    _ => false
  }
  if !both_same {
    return false
  }
  let h = metafield(st, x, "__eq")
  if !h.is_nil() {
    if is_callable(h) {
      let res = call_metamethod(st, h, [x, y], 1, "eq")
      return nth_or_nil(res, 0).is_truthy()
    }
    bad_metamethod_call(st, h, "__eq")
  }
  let h2 = metafield(st, y, "__eq")
  if !h2.is_nil() {
    if is_callable(h2) {
      let res = call_metamethod(st, h2, [x, y], 1, "eq")
      return nth_or_nil(res, 0).is_truthy()
    }
    bad_metamethod_call(st, h2, "__eq")
  }
  false
}

///|
/// `<` and `<=`.
pub fn less_than(
  st : @core.LuaState,
  x : @core.Value,
  y : @core.Value,
) -> Bool raise @core.LuaRaised {
  order(st, x, y, @core.BINOP_LT)
}

///|
pub fn less_equal(
  st : @core.LuaState,
  x : @core.Value,
  y : @core.Value,
) -> Bool raise @core.LuaRaised {
  order(st, x, y, @core.BINOP_LE)
}

///|
pub fn order(
  st : @core.LuaState,
  x : @core.Value,
  y : @core.Value,
  op : Int,
) -> Bool raise @core.LuaRaised {
  // Two numbers compare as numbers, and an integer against a float compares
  // exactly: converting the integer to a float would make neighbours collapse
  // into the same value.  The cases are written out rather than guarded by
  // `is_number` and then coerced, because this runs once per comparison
  // instruction.
  match (x, y) {
    (@core.VInt(i), @core.VInt(j)) =>
      return if op == @core.BINOP_LT { i < j } else { i <= j }
    (@core.VInt(i), @core.VNum(f)) =>
      return if op == @core.BINOP_LT {
        @core.int_lt_float(i, f)
      } else {
        @core.int_le_float(i, f)
      }
    (@core.VNum(f), @core.VInt(i)) =>
      return if op == @core.BINOP_LT {
        @core.float_lt_int(f, i)
      } else {
        @core.float_le_int(f, i)
      }
    (@core.VNum(f), @core.VNum(g)) =>
      return if op == @core.BINOP_LT { f < g } else { f <= g }
    _ => ()
  }
  match (x, y) {
    (@core.VStr(a), @core.VStr(b)) => {
      // Order follows the C locale's collation sequence, as `strcmp` does,
      // not raw byte comparison.
      let c = @core.lstrcmp(a.data(), b.data())
      if op == @core.BINOP_LT {
        return c < 0
      }
      return c <= 0
    }
    _ => ()
  }
  let name = if op == @core.BINOP_LT { "__lt" } else { "__le" }
  let h = metafield(st, x, name)
  if !h.is_nil() {
    if is_callable(h) {
      let res = call_metamethod(st, h, [x, y], 1, metamethod_report(name))
      return nth_or_nil(res, 0).is_truthy()
    }
    bad_metamethod_call(st, h, name)
  }
  let h2 = metafield(st, y, name)
  if !h2.is_nil() {
    if is_callable(h2) {
      let res = call_metamethod(st, h2, [x, y], 1, metamethod_report(name))
      return nth_or_nil(res, 0).is_truthy()
    }
    bad_metamethod_call(st, h2, name)
  }
  let xt = @core.type_error_name(st, x)
  let yt = @core.type_error_name(st, y)
  if xt == yt {
    @core.vm_error(st, "attempt to compare two " + xt + " values")
  } else {
    @core.vm_error(st, "attempt to compare " + xt + " with " + yt)
  }
}

///|----------------------------------------------------------------
/// Concatenation

///|----------------------------------------------------------------
