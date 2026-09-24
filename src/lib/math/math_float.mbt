// The functions of the mathematical library.

///|
pub fn math_abs(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_present(state, args, 1, "abs", "number")
  match v {
    @core.VInt(i) => [@core.VInt(if i < 0L { 0L - i } else { i })]
    @core.VNum(d) => [@core.VNum(d.abs())]
    _ => [@core.VNum(@core.check_number(state, args, 1, "abs").abs())]
  }
}

///|
/// Wraps a float valued function.
pub fn math_float1(
  state : @core.LuaState,
  args : Array[@core.Value],
  fname : String,
  f : (Double) -> Double,
) -> Array[@core.Value] raise @core.LuaRaised {
  let x = @core.check_number(state, args, 1, fname)
  [@core.VNum(f(x))]
}

///|
pub fn math_floor(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  match @core.check_present(state, args, 1, "floor", "number") {
    @core.VInt(i) => [@core.VInt(i)]
    _ => {
      let d = @core.check_number(state, args, 1, "floor")
      [@core.num_int(@cmath.floor(d))]
    }
  }
}

///|
pub fn math_ceil(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  match @core.check_present(state, args, 1, "ceil", "number") {
    @core.VInt(i) => [@core.VInt(i)]
    _ => {
      let d = @core.check_number(state, args, 1, "ceil")
      [@core.num_int(@cmath.ceil(d))]
    }
  }
}

///|
/// `math.fmod` follows the C library, so the result has the sign of the
/// dividend, unlike the `%` operator.
pub fn math_fmod(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() >= 1 && args.length() >= 2 {
    match (args[0], args[1]) {
      (@core.VInt(a), @core.VInt(b)) =>
        if b == 0L {
          @core.arg_error(state, 2, "fmod", "zero")
        } else if b == -1L {
          return [@core.VInt(0L)]
        } else {
          return [@core.VInt(a % b)]
        }
      _ => ()
    }
  }
  let a = @core.check_number(state, args, 1, "fmod")
  let b = @core.check_number(state, args, 2, "fmod")
  [@core.VNum(a.mod(b))]
}

///|
/// `math.modf` splits a number into its integral and fractional parts, keeping
/// the sign of the fractional part and reproducing the behaviour at infinities.
pub fn math_modf(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_present(state, args, 1, "modf", "number")
  match v {
    @core.VInt(i) => [@core.VInt(i), @core.VNum(0.0)]
    _ => {
      let d = @core.check_number(state, args, 1, "modf")
      if d.is_inf() {
        return [@core.VNum(d), @core.VNum(0.0)]
      }
      let ipart = @cmath.trunc(d)
      [@core.num_int(ipart), @core.VNum(d - ipart)]
    }
  }
}

///|
pub fn math_log(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let x = @core.check_number(state, args, 1, "log")
  if args.length() < 2 || args[1].is_nil() {
    return [@core.VNum(@cmath.ln(x))]
  }
  let base = @core.check_number(state, args, 2, "log")
  if base == 10.0 {
    [@core.VNum(@cmath.log10(x))]
  } else if base == 2.0 {
    [@core.VNum(@cmath.log2(x))]
  } else {
    [@core.VNum(@cmath.ln(x) / @cmath.ln(base))]
  }
}

///|
pub fn math_atan(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let y = @core.check_number(state, args, 1, "atan")
  if args.length() >= 2 && !args[1].is_nil() {
    let x = @core.check_number(state, args, 2, "atan")
    [@core.VNum(@cmath.atan2(y, x))]
  } else {
    [@core.VNum(@cmath.atan(y))]
  }
}

///|
pub fn math_max(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 {
    @core.arg_error(state, 1, "max", "value expected")
  }
  // Only the *presence* of an argument is checked: the reference takes the
  // first value as it is and compares the rest with `<`, so `math.max({})`
  // answers the table and `math.max(1, {})` fails in the comparison.
  let mut best = @core.check_any(state, args, 1, "max")
  let mut i = 2
  while i <= args.length() {
    let v = @core.check_any(state, args, i, "max")
    if @vm.less_than(state, best, v) {
      best = v
    }
    i = i + 1
  }
  [best]
}

///|
pub fn math_min(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  if args.length() == 0 {
    @core.arg_error(state, 1, "min", "value expected")
  }
  // Only the *presence* of an argument is checked: the reference takes the
  // first value as it is and compares the rest with `<`, so `math.min({})`
  // answers the table and `math.min(1, {})` fails in the comparison.
  let mut best = @core.check_any(state, args, 1, "min")
  let mut i = 2
  while i <= args.length() {
    let v = @core.check_any(state, args, i, "min")
    if @vm.less_than(state, v, best) {
      best = v
    }
    i = i + 1
  }
  [best]
}

///|
pub fn math_tointeger(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let v = @core.check_any(state, args, 1, "tointeger")
  // A numeral spelled in a string converts the same way a number does.
  let num : @core.Value = match v {
    @core.VInt(i) => @core.VInt(i)
    @core.VNum(d) => @core.VNum(d)
    @core.VStr(s) =>
      match @core.lua_str2num(s.data()) {
        Some(@core.NInt(i)) => @core.VInt(i)
        Some(@core.NFloat(d)) => @core.VNum(d)
        None => @core.VNil
      }
    _ => @core.VNil
  }
  match num {
    @core.VInt(i) => [@core.VInt(i)]
    @core.VNum(d) =>
      if @core.float_is_int64(d) {
        [@core.VInt(@core.float_to_int64(d))]
      } else {
        [@core.VNil]
      }
    _ => [@core.VNil]
  }
}

///|
pub fn math_type(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  match @core.check_any(state, args, 1, "type") {
    @core.VInt(_) => [@core.VStr(@core.LStr::of_string("integer"))]
    @core.VNum(_) => [@core.VStr(@core.LStr::of_string("float"))]
    _ => [@core.VNil]
  }
}

///|
/// Unsigned comparison of two integers.
pub fn math_ult(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let a = @core.check_int(state, args, 1, "ult")
  let b = @core.check_int(state, args, 2, "ult")
  [@core.VBool(a.reinterpret_as_uint64() < b.reinterpret_as_uint64())]
}

///|----------------------------------------------------------------
/// Random numbers

///|----------------------------------------------------------------

///|
pub fn math_sqrt(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "sqrt", fn(d) { d.sqrt() })
}

///|
pub fn math_sin(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "sin", fn(d) { @cmath.sin(d) })
}

///|
pub fn math_cos(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "cos", fn(d) { @cmath.cos(d) })
}

///|
pub fn math_tan(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "tan", fn(d) { @cmath.tan(d) })
}

///|
pub fn math_asin(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "asin", fn(d) { @cmath.asin(d) })
}

///|
pub fn math_acos(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "acos", fn(d) { @cmath.acos(d) })
}

///|
pub fn math_sinh(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "sinh", fn(d) { @cmath.sinh(d) })
}

///|
pub fn math_cosh(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "cosh", fn(d) { @cmath.cosh(d) })
}

///|
pub fn math_tanh(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "tanh", fn(d) { @cmath.tanh(d) })
}

///|
pub fn math_exp(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "exp", fn(d) { @cmath.exp(d) })
}

///|
pub fn math_deg(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "deg", fn(d) { d * (180.0 / 3.141592653589793) })
}

///|
pub fn math_rad(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  math_float1(state, args, "rad", fn(d) { d * (3.141592653589793 / 180.0) })
}

///|
pub fn math_pow_fn(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let a = @core.check_number(state, args, 1, "pow")
  let b = @core.check_number(state, args, 2, "pow")
  [@core.VNum(@cmath.pow(a, b))]
}
