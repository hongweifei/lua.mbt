// Installing the mathematical library.

///|
pub fn open_math_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("abs", @core.VBuiltin(@core.LBuiltin::make("abs", 1, math_abs)))
  t.set_str("ceil", @core.VBuiltin(@core.LBuiltin::make("ceil", 1, math_ceil)))
  t.set_str(
    "floor",
    @core.VBuiltin(@core.LBuiltin::make("floor", 1, math_floor)),
  )
  t.set_str("fmod", @core.VBuiltin(@core.LBuiltin::make("fmod", 2, math_fmod)))
  t.set_str("modf", @core.VBuiltin(@core.LBuiltin::make("modf", 1, math_modf)))
  t.set_str("sqrt", @core.VBuiltin(@core.LBuiltin::make("sqrt", 1, math_sqrt)))
  t.set_str("sin", @core.VBuiltin(@core.LBuiltin::make("sin", 1, math_sin)))
  t.set_str("cos", @core.VBuiltin(@core.LBuiltin::make("cos", 1, math_cos)))
  t.set_str("tan", @core.VBuiltin(@core.LBuiltin::make("tan", 1, math_tan)))
  t.set_str("asin", @core.VBuiltin(@core.LBuiltin::make("asin", 1, math_asin)))
  t.set_str("acos", @core.VBuiltin(@core.LBuiltin::make("acos", 1, math_acos)))
  t.set_str("atan", @core.VBuiltin(@core.LBuiltin::make("atan", 2, math_atan)))
  t.set_str("sinh", @core.VBuiltin(@core.LBuiltin::make("sinh", 1, math_sinh)))
  t.set_str("cosh", @core.VBuiltin(@core.LBuiltin::make("cosh", 1, math_cosh)))
  t.set_str("tanh", @core.VBuiltin(@core.LBuiltin::make("tanh", 1, math_tanh)))
  t.set_str("exp", @core.VBuiltin(@core.LBuiltin::make("exp", 1, math_exp)))
  t.set_str("log", @core.VBuiltin(@core.LBuiltin::make("log", 2, math_log)))
  t.set_str("pow", @core.VBuiltin(@core.LBuiltin::make("pow", 2, math_pow_fn)))
  t.set_str("deg", @core.VBuiltin(@core.LBuiltin::make("deg", 1, math_deg)))
  t.set_str("rad", @core.VBuiltin(@core.LBuiltin::make("rad", 1, math_rad)))
  t.set_str("max", @core.VBuiltin(@core.LBuiltin::make("max", -1, math_max)))
  t.set_str("min", @core.VBuiltin(@core.LBuiltin::make("min", -1, math_min)))
  t.set_str(
    "tointeger",
    @core.VBuiltin(@core.LBuiltin::make("tointeger", 1, math_tointeger)),
  )
  t.set_str("type", @core.VBuiltin(@core.LBuiltin::make("type", 1, math_type)))
  t.set_str("ult", @core.VBuiltin(@core.LBuiltin::make("ult", 2, math_ult)))
  t.set_str(
    "random",
    @core.VBuiltin(@core.LBuiltin::make("random", 2, math_random)),
  )
  t.set_str(
    "randomseed",
    @core.VBuiltin(@core.LBuiltin::make("randomseed", 2, math_randomseed)),
  )
  t.set_str("pi", @core.VNum(3.141592653589793))
  t.set_str("huge", @core.VNum(1.0 / 0.0))
  t.set_str("maxinteger", @core.VInt(9223372036854775807L))
  t.set_str("mininteger", @core.VInt(-9223372036854775807L - 1L))
  state.globals.set_str("math", @core.VTable(t))
}
