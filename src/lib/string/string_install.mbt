// Installing the string library and its arithmetic methods.

///|
pub fn open_string_library(state : @core.LuaState) -> Unit {
  let t = @core.LTable::new()
  t.set_str("byte", @core.VBuiltin(@core.LBuiltin::make("byte", 3, str_byte)))
  t.set_str("char", @core.VBuiltin(@core.LBuiltin::make("char", -1, str_char)))
  t.set_str(
    "dump",
    @core.VBuiltin(@core.LBuiltin::make("dump", 2, @chunk.str_dump)),
  )
  t.set_str("find", @core.VBuiltin(@core.LBuiltin::make("find", 4, str_find)))
  t.set_str(
    "format",
    @core.VBuiltin(@core.LBuiltin::make("format", -1, str_format)),
  )
  t.set_str(
    "gmatch",
    @core.VBuiltin(@core.LBuiltin::make("gmatch", 3, str_gmatch)),
  )
  t.set_str("gsub", @core.VBuiltin(@core.LBuiltin::make("gsub", 4, str_gsub)))
  t.set_str("len", @core.VBuiltin(@core.LBuiltin::make("len", 1, str_len)))
  t.set_str(
    "lower",
    @core.VBuiltin(@core.LBuiltin::make("lower", 1, str_lower)),
  )
  t.set_str(
    "match",
    @core.VBuiltin(@core.LBuiltin::make("match", 3, str_match)),
  )
  t.set_str("pack", @core.VBuiltin(@core.LBuiltin::make("pack", -1, str_pack)))
  t.set_str(
    "packsize",
    @core.VBuiltin(@core.LBuiltin::make("packsize", 1, str_packsize)),
  )
  t.set_str("rep", @core.VBuiltin(@core.LBuiltin::make("rep", 3, str_rep)))
  t.set_str(
    "reverse",
    @core.VBuiltin(@core.LBuiltin::make("reverse", 1, str_reverse)),
  )
  t.set_str("sub", @core.VBuiltin(@core.LBuiltin::make("sub", 3, str_sub)))
  t.set_str(
    "unpack",
    @core.VBuiltin(@core.LBuiltin::make("unpack", 3, str_unpack)),
  )
  t.set_str(
    "upper",
    @core.VBuiltin(@core.LBuiltin::make("upper", 1, str_upper)),
  )
  state.globals.set_str("string", @core.VTable(t))
  // The string metatable makes indexing a string reach this table, and provides
  // * the arithmetic coercion the language documents.
  let mt = @core.LTable::new()
  mt.set_str("__index", @core.VTable(t))
  mt.set_str(
    "__add",
    @core.VBuiltin(@core.LBuiltin::make("__add", 2, str_arith_add)),
  )
  mt.set_str(
    "__sub",
    @core.VBuiltin(@core.LBuiltin::make("__sub", 2, str_arith_sub)),
  )
  mt.set_str(
    "__mul",
    @core.VBuiltin(@core.LBuiltin::make("__mul", 2, str_arith_mul)),
  )
  mt.set_str(
    "__div",
    @core.VBuiltin(@core.LBuiltin::make("__div", 2, str_arith_div)),
  )
  mt.set_str(
    "__mod",
    @core.VBuiltin(@core.LBuiltin::make("__mod", 2, str_arith_mod)),
  )
  mt.set_str(
    "__pow",
    @core.VBuiltin(@core.LBuiltin::make("__pow", 2, str_arith_pow)),
  )
  mt.set_str(
    "__unm",
    @core.VBuiltin(@core.LBuiltin::make("__unm", 1, str_arith_unm)),
  )
  mt.set_str(
    "__idiv",
    @core.VBuiltin(@core.LBuiltin::make("__idiv", 2, str_arith_idiv)),
  )
  @vm.set_metatable_of(state, @core.VStr(@core.LStr::empty()), Some(mt))
}

///|----------------------------------------------------------------
/// Arithmetic on strings

///|----------------------------------------------------------------

///|
/// The string metatable's arithmetic metamethods convert their operands and
/// repeat the operation, which is what makes `"10" + 1` work.
pub fn string_to_number(
  state : @core.LuaState,
  v : @core.Value,
  fname : String,
) -> @core.Value raise @core.LuaRaised {
  let _ = fname
  match v {
    @core.VInt(_) | @core.VNum(_) => v
    @core.VStr(s) =>
      match @core.lua_str2num(s.data()) {
        Some(@core.NInt(i)) => @core.VInt(i)
        Some(@core.NFloat(d)) => @core.VNum(d)
        None =>
          @core.runtime_error(
            state, "attempt to perform arithmetic on a string value",
          )
      }
    _ => {
      let name = @core.type_error_name(state, v)
      @core.runtime_error(
        state,
        "attempt to perform arithmetic on a " + name + " value",
      )
    }
  }
}

///|
/// As in `arith` from `lstrlib.c`: when both operands are numbers or numeral
/// strings the operation is performed on the coercions; otherwise the second
/// operand's own metamethod is tried, and only then does it fail.
pub fn str_arith_bin(
  state : @core.LuaState,
  args : Array[@core.Value],
  op : Int,
  fname : String,
) -> Array[@core.Value] raise @core.LuaRaised {
  let a = coerce_to_number(args[0])
  let b = coerce_to_number(args[1])
  match (a, b) {
    (Some(x), Some(y)) => [@vm.arith(state, op, x, y)]
    _ => try_operand_mt(state, args, fname)
  }
}

///|
/// `tonum` from `lstrlib.c`: a number passes through; a string that is a
/// full numeral converts; nothing else does.
fn coerce_to_number(v : @core.Value) -> @core.Value? {
  match v {
    @core.VInt(_) | @core.VNum(_) => Some(v)
    @core.VStr(s) =>
      match @core.lua_str2num(s.data()) {
        Some(@core.NInt(i)) => Some(@core.VInt(i))
        Some(@core.NFloat(d)) => Some(@core.VNum(d))
        None => None
      }
    _ => None
  }
}

///|
/// `trymt`: call the second operand's metamethod with the original values, or
/// fail with the reference's message.
fn try_operand_mt(
  state : @core.LuaState,
  args : Array[@core.Value],
  fname : String,
) -> Array[@core.Value] raise @core.LuaRaised {
  let p2 = args[1]
  let tm = if p2 is @core.VStr(_) {
    @core.VNil
  } else {
    match @vm.metafield(state, p2, "__" + fname) {
      v => v
    }
  }
  if !@vm.is_callable(tm) {
    let t1 = @core.type_error_name(state, args[0])
    let t2 = @core.type_error_name(state, p2)
    @core.runtime_error(
      state,
      "attempt to " + fname + " a '" + t1 + "' with a '" + t2 + "'",
    )
  }
  @vm.call_value(state, tm, [args[0], args[1]], 1)
}

///|
pub fn str_arith_add(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_ADD, "add")
}

///|
pub fn str_arith_sub(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_SUB, "sub")
}

///|
pub fn str_arith_mul(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_MUL, "mul")
}

///|
pub fn str_arith_div(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_DIV, "div")
}

///|
pub fn str_arith_mod(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_MOD, "mod")
}

///|
pub fn str_arith_pow(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_POW, "pow")
}

///|
pub fn str_arith_idiv(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  str_arith_bin(state, args, @core.BINOP_IDIV, "idiv")
}

///|
pub fn str_arith_unm(
  state : @core.LuaState,
  upvals : Array[@core.Value],
  args : Array[@core.Value],
) -> Array[@core.Value] raise @core.LuaRaised {
  let _ = upvals
  let a = string_to_number(state, args[0], "unm")
  [@vm.unop(state, @core.UNOP_MINUS, a)]
}
